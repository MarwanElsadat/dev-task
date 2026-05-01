/**
 * @AuraEnabled-facing controller for the callNotesLogger LWC. Acts as the
 * boundary between the UI and the pure-Apex service layer:
 *   - Translates plain Maps (from JS) into typed CallNotesService.CallNoteRequest
 *   - Catches both CallNotesException and unexpected exceptions and rethrows
 *     them as AuraHandledException so the LWC can surface a meaningful toast
 *
 * AuraHandledException quirk: `new AuraHandledException(msg)` doesn't actually
 * carry `msg` to the client — you have to call setMessage() after construction.
 */
public with sharing class CallNotesHandler {

    private static final Integer DEFAULT_RECENT_LIMIT = 5;
    private static final Integer MAX_RECENT_LIMIT = 50;

    /**
     * Persist a single call note logged from the LWC.
     */
    @AuraEnabled
    public static Task logCallNote(Map<String, Object> payload) {
        try {
            CallNotesService.CallNoteRequest req = toRequest(payload);
            return CallNotesService.createCallNote(req);
        } catch (CallNotesException ce) {
            throw makeAuraException(ce.getMessage());
        } catch (Exception e) {
            throw makeAuraException('Unexpected error while saving call note: ' + e.getMessage());
        }
    }

    /**
     * Update an existing call note (inline edit). Only mutable fields are
     * touched — Subject is rebuilt from the new outcome to keep the activity
     * timeline in sync.
     */
    @AuraEnabled
    public static Task updateCallNote(Id taskId, String notes, String outcome, Date callDate) {
        try {
            if (taskId == null) {
                throw new CallNotesException('Task Id is required.');
            }
            if (String.isBlank(notes)) {
                throw new CallNotesException('Notes are required.');
            }
            if (notes.length() > 1000) {
                throw new CallNotesException('Notes cannot exceed 1000 characters.');
            }
            if (!CallNotesService.ALLOWED_OUTCOMES.contains(outcome)) {
                throw new CallNotesException('Invalid outcome.');
            }
            if (callDate == null) {
                throw new CallNotesException('Call date is required.');
            }
            Task t = new Task(
                Id = taskId,
                Description = notes,
                Call_Outcome__c = outcome,
                Subject = 'Call: ' + outcome,
                ActivityDate = callDate
            );
            Database.SaveResult sr = Database.update(t, false, AccessLevel.USER_MODE);
            if (!sr.isSuccess()) {
                List<String> errors = new List<String>();
                for (Database.Error err : sr.getErrors()) {
                    errors.add(err.getMessage());
                }
                throw new CallNotesException('Could not update call note: ' + String.join(errors, '; '));
            }
            return t;
        } catch (CallNotesException ce) {
            throw makeAuraException(ce.getMessage());
        } catch (Exception e) {
            throw makeAuraException('Unexpected error while updating call note: ' + e.getMessage());
        }
    }

    /**
     * Delete a call note (inline delete). USER_MODE blocks this if the user
     * doesn't have delete on Task.
     */
    @AuraEnabled
    public static void deleteCallNote(Id taskId) {
        try {
            if (taskId == null) {
                throw new CallNotesException('Task Id is required.');
            }
            Database.DeleteResult dr = Database.delete(taskId, false, AccessLevel.USER_MODE);
            if (!dr.isSuccess()) {
                List<String> errors = new List<String>();
                for (Database.Error err : dr.getErrors()) {
                    errors.add(err.getMessage());
                }
                throw new CallNotesException('Could not delete call note: ' + String.join(errors, '; '));
            }
        } catch (CallNotesException ce) {
            throw makeAuraException(ce.getMessage());
        } catch (Exception e) {
            throw makeAuraException('Unexpected error while deleting call note: ' + e.getMessage());
        }
    }

    /**
     * Recent call notes for an Opportunity, newest first. Cacheable so the
     * platform can serve repeat reads from the wire cache; we use refreshApex
     * from the LWC after a save/edit/delete to invalidate it.
     */
    @AuraEnabled(cacheable=true)
    public static List<Task> getRecentCallNotes(Id opportunityId, Integer limitSize) {
        if (opportunityId == null) {
            throw makeAuraException('Opportunity Id is required.');
        }
        if (opportunityId.getSobjectType() != Opportunity.SObjectType) {
            throw makeAuraException('Related record must be an Opportunity.');
        }
        Integer effectiveLimit = (limitSize == null || limitSize <= 0)
            ? DEFAULT_RECENT_LIMIT
            : Math.min(limitSize, MAX_RECENT_LIMIT);

        try {
            return [
                SELECT Id, Subject, Description, ActivityDate, Status,
                       Call_Outcome__c, WhoId, Who.Name, WhatId, OwnerId, Owner.Name,
                       LastModifiedDate
                FROM Task
                WHERE WhatId = :opportunityId
                  AND Type = 'Call'
                  AND Call_Notes_Source__c = 'Call Notes Logger'
                WITH USER_MODE
                ORDER BY ActivityDate DESC, CreatedDate DESC
                LIMIT :effectiveLimit
            ];
        } catch (Exception e) {
            throw makeAuraException('Could not load recent call notes: ' + e.getMessage());
        }
    }

    // -------------------------------------------------------------------- //
    // Helpers                                                               //
    // -------------------------------------------------------------------- //

    private static CallNotesService.CallNoteRequest toRequest(Map<String, Object> payload) {
        if (payload == null) {
            throw new CallNotesException('Payload is missing.');
        }
        CallNotesService.CallNoteRequest req = new CallNotesService.CallNoteRequest();
        req.opportunityId = (Id) payload.get('opportunityId');
        req.contactId     = (Id) payload.get('contactId');
        req.outcome       = (String) payload.get('outcome');
        req.notes         = (String) payload.get('notes');
        Object rawDate    = payload.get('callDate');
        if (rawDate instanceof Date) {
            req.callDate = (Date) rawDate;
        } else if (rawDate instanceof String && !String.isBlank((String) rawDate)) {
            req.callDate = Date.valueOf((String) rawDate);
        } else if (rawDate == null) {
            req.callDate = Date.today();
        }
        return req;
    }

    private static AuraHandledException makeAuraException(String message) {
        AuraHandledException ahe = new AuraHandledException(message);
        // Required so getMessage() on the LWC side returns `message`,
        // not the default 'Script-thrown exception'.
        ahe.setMessage(message);
        return ahe;
    }
}
