/**
 * Service layer for the Call Notes feature. Pure business logic — no @AuraEnabled
 * methods live here. The handler (CallNotesHandler) is the only entry point from
 * the LWC; this class can also be reused from triggers, queueables, batches.
 *
 * Design notes:
 *   - Bulkified from day one: every public method accepts a List<CallNoteRequest>.
 *   - Validation happens server-side regardless of any client-side checks.
 *     CallNotesException carries a human-readable message back to the handler.
 *   - DML runs in USER_MODE so FLS/CRUD is enforced for the running user without
 *     hand-rolled isCreateable() checks.
 *   - No SOQL or DML inside loops.
 */
public with sharing class CallNotesService {

    public static final Integer NOTES_MAX_LENGTH = 1000;
    public static final Set<String> ALLOWED_OUTCOMES = new Set<String>{
        'Positive', 'Neutral', 'Negative', 'No Answer'
    };
    private static final String CALL_TYPE = 'Call';
    private static final String COMPLETED_STATUS = 'Completed';
    private static final String SOURCE_LWC = 'Call Notes Logger';

    /**
     * Insert one or more call notes as Task records.
     * @param requests one or more validated CallNoteRequest payloads
     * @return the inserted Tasks (with Ids populated)
     * @throws CallNotesException on validation failure or DML error
     */
    public static List<Task> createCallNotes(List<CallNoteRequest> requests) {
        if (requests == null || requests.isEmpty()) {
            throw new CallNotesException('At least one call note is required.');
        }

        List<Task> toInsert = new List<Task>();
        for (Integer i = 0; i < requests.size(); i++) {
            CallNoteRequest req = requests[i];
            validate(req, i);
            toInsert.add(toTask(req));
        }

        try {
            // USER_MODE enforces FLS/CRUD for the running user.
            Database.SaveResult[] results = Database.insert(
                toInsert, false, AccessLevel.USER_MODE
            );
            List<String> errorMessages = new List<String>();
            for (Database.SaveResult sr : results) {
                if (!sr.isSuccess()) {
                    for (Database.Error err : sr.getErrors()) {
                        errorMessages.add(err.getStatusCode() + ': ' + err.getMessage());
                    }
                }
            }
            if (!errorMessages.isEmpty()) {
                throw new CallNotesException(
                    'Could not save call note(s): ' + String.join(errorMessages, '; ')
                );
            }
        } catch (DmlException dmlEx) {
            throw new CallNotesException(
                'Database error while saving call note(s): ' + dmlEx.getMessage()
            );
        }
        return toInsert;
    }

    /**
     * Convenience overload for the common single-note case.
     */
    public static Task createCallNote(CallNoteRequest request) {
        return createCallNotes(new List<CallNoteRequest>{ request })[0];
    }

    // -------------------------------------------------------------------- //
    // Validation                                                            //
    // -------------------------------------------------------------------- //

    private static void validate(CallNoteRequest req, Integer index) {
        String prefix = 'Call note #' + (index + 1) + ': ';
        if (req == null) {
            throw new CallNotesException(prefix + 'request payload is missing.');
        }
        if (req.opportunityId == null) {
            throw new CallNotesException(prefix + 'Opportunity is required.');
        }
        if (req.opportunityId.getSobjectType() != Opportunity.SObjectType) {
            throw new CallNotesException(prefix + 'Related record must be an Opportunity.');
        }
        if (String.isBlank(req.notes)) {
            throw new CallNotesException(prefix + 'Notes are required.');
        }
        if (req.notes.length() > NOTES_MAX_LENGTH) {
            throw new CallNotesException(
                prefix + 'Notes cannot exceed ' + NOTES_MAX_LENGTH + ' characters.'
            );
        }
        if (String.isBlank(req.outcome) || !ALLOWED_OUTCOMES.contains(req.outcome)) {
            throw new CallNotesException(
                prefix + 'Outcome must be one of: ' + String.join(new List<String>(ALLOWED_OUTCOMES), ', ') + '.'
            );
        }
        if (req.callDate == null) {
            throw new CallNotesException(prefix + 'Call date is required.');
        }
        if (req.contactId != null && req.contactId.getSobjectType() != Contact.SObjectType) {
            throw new CallNotesException(prefix + 'Contact reference is invalid.');
        }
    }

    // -------------------------------------------------------------------- //
    // Mapping                                                               //
    // -------------------------------------------------------------------- //

    private static Task toTask(CallNoteRequest req) {
        return new Task(
            Subject = 'Call: ' + req.outcome,
            Type = CALL_TYPE,
            Status = COMPLETED_STATUS,
            ActivityDate = req.callDate,
            Description = req.notes,
            WhatId = req.opportunityId,
            WhoId = req.contactId,
            Call_Outcome__c = req.outcome,
            Call_Notes_Source__c = SOURCE_LWC
        );
    }

    // -------------------------------------------------------------------- //
    // Public DTO — used as the contract between LWC handler and service     //
    // -------------------------------------------------------------------- //

    public class CallNoteRequest {
        @AuraEnabled public Id opportunityId { get; set; }
        @AuraEnabled public Id contactId { get; set; }
        @AuraEnabled public Date callDate { get; set; }
        @AuraEnabled public String outcome { get; set; }
        @AuraEnabled public String notes { get; set; }
    }
}
