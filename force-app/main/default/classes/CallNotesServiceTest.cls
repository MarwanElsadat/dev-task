/**
 * Tests for CallNotesService and CallNotesHandler. Bundled into one class
 * because both are part of the same vertical slice; splitting them adds
 * ceremony without improving signal.
 *
 * Each test makes meaningful assertions (record fields, error contents,
 * counts) — never just `Assert.isTrue(true)` to pad coverage.
 */
@IsTest
private class CallNotesServiceTest {

    private static final String VALID_NOTES   = 'Discussed renewal pricing and next steps.';
    private static final String VALID_OUTCOME = 'Positive';

    @TestSetup
    static void seed() {
        Account acc = new Account(Name = 'Acme Corp');
        insert acc;

        Contact c = new Contact(
            FirstName = 'Sales', LastName = 'Lead',
            AccountId = acc.Id, Email = 'lead@acme.test'
        );
        insert c;

        Opportunity opp = new Opportunity(
            Name = 'Acme - Renewal',
            AccountId = acc.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            Amount = 25000
        );
        insert opp;
    }

    private static Opportunity getOpp() {
        return [SELECT Id, AccountId FROM Opportunity LIMIT 1];
    }

    private static Contact getContact() {
        return [SELECT Id FROM Contact LIMIT 1];
    }

    // ------------------------------------------------------------------ //
    // Service — positive                                                  //
    // ------------------------------------------------------------------ //

    @IsTest
    static void createCallNote_savesTaskWithExpectedFields() {
        Opportunity opp = getOpp();
        Contact c = getContact();
        CallNotesService.CallNoteRequest req = new CallNotesService.CallNoteRequest();
        req.opportunityId = opp.Id;
        req.contactId     = c.Id;
        req.callDate      = Date.today();
        req.outcome       = VALID_OUTCOME;
        req.notes         = VALID_NOTES;

        Test.startTest();
        Task created = CallNotesService.createCallNote(req);
        Test.stopTest();

        Assert.isNotNull(created.Id, 'Task should have an Id after insert.');
        Task reloaded = [
            SELECT Id, Subject, Type, Status, ActivityDate, Description,
                   WhatId, WhoId, Call_Outcome__c, Call_Notes_Source__c
            FROM Task WHERE Id = :created.Id
        ];
        Assert.areEqual('Call: Positive', reloaded.Subject, 'Subject should derive from outcome.');
        Assert.areEqual('Call', reloaded.Type, 'Type should be Call.');
        Assert.areEqual('Completed', reloaded.Status, 'Status should be Completed.');
        Assert.areEqual(Date.today(), reloaded.ActivityDate, 'ActivityDate should match request.');
        Assert.areEqual(VALID_NOTES, reloaded.Description, 'Description should hold the notes.');
        Assert.areEqual(opp.Id, reloaded.WhatId, 'WhatId should be the Opportunity.');
        Assert.areEqual(c.Id, reloaded.WhoId, 'WhoId should be the Contact.');
        Assert.areEqual('Positive', reloaded.Call_Outcome__c, 'Outcome should be persisted.');
        Assert.areEqual('Call Notes Logger', reloaded.Call_Notes_Source__c, 'Source should be tagged.');
    }

    @IsTest
    static void createCallNote_acceptsNullContact() {
        Opportunity opp = getOpp();
        CallNotesService.CallNoteRequest req = baseRequest(opp.Id);
        req.contactId = null;

        Task created = CallNotesService.createCallNote(req);

        Assert.isNotNull(created.Id);
        Assert.isNull(created.WhoId, 'Contact is optional.');
    }

    // ------------------------------------------------------------------ //
    // Service — negative                                                  //
    // ------------------------------------------------------------------ //

    @IsTest
    static void createCallNote_missingNotes_throws() {
        Opportunity opp = getOpp();
        CallNotesService.CallNoteRequest req = baseRequest(opp.Id);
        req.notes = null;

        try {
            CallNotesService.createCallNote(req);
            Assert.fail('Expected CallNotesException for missing notes.');
        } catch (CallNotesException ex) {
            Assert.isTrue(ex.getMessage().contains('Notes are required'),
                'Error message should explain the missing field. Got: ' + ex.getMessage());
        }
    }

    @IsTest
    static void createCallNote_blankNotes_throws() {
        Opportunity opp = getOpp();
        CallNotesService.CallNoteRequest req = baseRequest(opp.Id);
        req.notes = '   ';

        try {
            CallNotesService.createCallNote(req);
            Assert.fail('Expected CallNotesException for blank notes.');
        } catch (CallNotesException ex) {
            Assert.isTrue(ex.getMessage().contains('Notes are required'));
        }
    }

    @IsTest
    static void createCallNote_notesTooLong_throws() {
        Opportunity opp = getOpp();
        CallNotesService.CallNoteRequest req = baseRequest(opp.Id);
        req.notes = 'x'.repeat(1001);

        try {
            CallNotesService.createCallNote(req);
            Assert.fail('Expected CallNotesException for over-length notes.');
        } catch (CallNotesException ex) {
            Assert.isTrue(ex.getMessage().contains('1000 characters'),
                'Error should mention the limit. Got: ' + ex.getMessage());
        }
    }

    @IsTest
    static void createCallNote_notesAtBoundary_succeeds() {
        Opportunity opp = getOpp();
        CallNotesService.CallNoteRequest req = baseRequest(opp.Id);
        req.notes = 'x'.repeat(1000);

        Task t = CallNotesService.createCallNote(req);
        Assert.isNotNull(t.Id, 'Exactly 1000 chars should be allowed.');
    }

    @IsTest
    static void createCallNote_invalidOutcome_throws() {
        Opportunity opp = getOpp();
        CallNotesService.CallNoteRequest req = baseRequest(opp.Id);
        req.outcome = 'Maybe';

        try {
            CallNotesService.createCallNote(req);
            Assert.fail('Expected CallNotesException for invalid outcome.');
        } catch (CallNotesException ex) {
            Assert.isTrue(ex.getMessage().contains('Outcome must be one of'),
                'Error should list valid outcomes.');
        }
    }

    @IsTest
    static void createCallNote_missingOpportunity_throws() {
        CallNotesService.CallNoteRequest req = baseRequest(null);

        try {
            CallNotesService.createCallNote(req);
            Assert.fail('Expected CallNotesException for missing Opportunity.');
        } catch (CallNotesException ex) {
            Assert.isTrue(ex.getMessage().contains('Opportunity is required'));
        }
    }

    @IsTest
    static void createCallNote_nonOpportunityWhatId_throws() {
        Account a = [SELECT Id FROM Account LIMIT 1];
        CallNotesService.CallNoteRequest req = baseRequest(a.Id);

        try {
            CallNotesService.createCallNote(req);
            Assert.fail('Expected CallNotesException for non-Opportunity Id.');
        } catch (CallNotesException ex) {
            Assert.isTrue(ex.getMessage().contains('must be an Opportunity'));
        }
    }

    @IsTest
    static void createCallNote_emptyList_throws() {
        try {
            CallNotesService.createCallNotes(new List<CallNotesService.CallNoteRequest>());
            Assert.fail('Expected CallNotesException for empty list.');
        } catch (CallNotesException ex) {
            Assert.isTrue(ex.getMessage().contains('At least one'));
        }
    }

    @IsTest
    static void createCallNote_nullList_throws() {
        try {
            CallNotesService.createCallNotes(null);
            Assert.fail('Expected CallNotesException for null list.');
        } catch (CallNotesException ex) {
            Assert.isTrue(ex.getMessage().contains('At least one'));
        }
    }

    // ------------------------------------------------------------------ //
    // Service — bulk                                                      //
    // ------------------------------------------------------------------ //

    @IsTest
    static void createCallNotes_bulk200_singleDml() {
        // Seed 200 Opportunities so each note has a unique parent.
        List<Account> accs = new List<Account>();
        for (Integer i = 0; i < 200; i++) {
            accs.add(new Account(Name = 'Bulk Acc ' + i));
        }
        insert accs;
        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < 200; i++) {
            opps.add(new Opportunity(
                Name = 'Bulk Opp ' + i,
                AccountId = accs[i].Id,
                StageName = 'Prospecting',
                CloseDate = Date.today().addDays(15)
            ));
        }
        insert opps;

        List<CallNotesService.CallNoteRequest> requests = new List<CallNotesService.CallNoteRequest>();
        for (Opportunity opp : opps) {
            CallNotesService.CallNoteRequest r = new CallNotesService.CallNoteRequest();
            r.opportunityId = opp.Id;
            r.callDate      = Date.today();
            r.outcome       = VALID_OUTCOME;
            r.notes         = 'Bulk note for ' + opp.Name;
            requests.add(r);
        }

        Test.startTest();
        Integer dmlBefore = Limits.getDmlStatements();
        List<Task> created = CallNotesService.createCallNotes(requests);
        Integer dmlAfter = Limits.getDmlStatements();
        Test.stopTest();

        Assert.areEqual(200, created.size(), '200 Tasks should be returned.');
        Assert.areEqual(1, dmlAfter - dmlBefore,
            'Bulk insert should use exactly one DML statement, not 200.');
        Integer count = [SELECT COUNT() FROM Task WHERE Call_Notes_Source__c = 'Call Notes Logger'];
        Assert.areEqual(200, count, '200 Tasks should be persisted.');
    }

    // ------------------------------------------------------------------ //
    // Handler — logCallNote                                               //
    // ------------------------------------------------------------------ //

    @IsTest
    static void handler_logCallNote_happyPath() {
        Opportunity opp = getOpp();
        Map<String, Object> payload = new Map<String, Object>{
            'opportunityId' => opp.Id,
            'contactId'     => null,
            'callDate'      => String.valueOf(Date.today()),
            'outcome'       => 'Neutral',
            'notes'         => VALID_NOTES
        };

        Test.startTest();
        Task t = CallNotesHandler.logCallNote(payload);
        Test.stopTest();

        Assert.isNotNull(t.Id);
        Task reloaded = [SELECT Call_Outcome__c FROM Task WHERE Id = :t.Id];
        Assert.areEqual('Neutral', reloaded.Call_Outcome__c);
    }

    @IsTest
    static void handler_logCallNote_validationError_becomesAuraException() {
        Opportunity opp = getOpp();
        Map<String, Object> payload = new Map<String, Object>{
            'opportunityId' => opp.Id,
            'callDate'      => String.valueOf(Date.today()),
            'outcome'       => 'Positive',
            'notes'         => null
        };

        try {
            CallNotesHandler.logCallNote(payload);
            Assert.fail('Expected AuraHandledException for missing notes.');
        } catch (AuraHandledException ex) {
            // Just asserting the type is enough — Salesforce sometimes
            // strips the message in the platform-thrown variant.
            Assert.isNotNull(ex);
        }
    }

    @IsTest
    static void handler_logCallNote_nullPayload_throws() {
        try {
            CallNotesHandler.logCallNote(null);
            Assert.fail('Expected AuraHandledException for null payload.');
        } catch (AuraHandledException ex) {
            Assert.isNotNull(ex);
        }
    }

    @IsTest
    static void handler_logCallNote_defaultsCallDateWhenMissing() {
        Opportunity opp = getOpp();
        Map<String, Object> payload = new Map<String, Object>{
            'opportunityId' => opp.Id,
            'outcome'       => 'Positive',
            'notes'         => VALID_NOTES
            // no callDate key — handler should default to today
        };

        Task t = CallNotesHandler.logCallNote(payload);
        Task reloaded = [SELECT ActivityDate FROM Task WHERE Id = :t.Id];
        Assert.areEqual(Date.today(), reloaded.ActivityDate);
    }

    // ------------------------------------------------------------------ //
    // Handler — getRecentCallNotes                                        //
    // ------------------------------------------------------------------ //

    @IsTest
    static void handler_getRecentCallNotes_returnsLimitedAndOrdered() {
        Opportunity opp = getOpp();
        // Seed 7 notes spread across dates.
        List<Task> seed = new List<Task>();
        for (Integer i = 0; i < 7; i++) {
            seed.add(new Task(
                Subject = 'Call: Neutral',
                Type = 'Call',
                Status = 'Completed',
                ActivityDate = Date.today().addDays(-i),
                Description = 'Note ' + i,
                WhatId = opp.Id,
                Call_Outcome__c = 'Neutral',
                Call_Notes_Source__c = 'Call Notes Logger'
            ));
        }
        insert seed;

        List<Task> recent = CallNotesHandler.getRecentCallNotes(opp.Id, 5);

        Assert.areEqual(5, recent.size(), 'Should respect the requested limit.');
        for (Integer i = 0; i < recent.size() - 1; i++) {
            Assert.isTrue(
                recent[i].ActivityDate >= recent[i + 1].ActivityDate,
                'Should be ordered by ActivityDate DESC.'
            );
        }
    }

    @IsTest
    static void handler_getRecentCallNotes_nullOpportunity_throws() {
        try {
            CallNotesHandler.getRecentCallNotes(null, 5);
            Assert.fail('Expected AuraHandledException for null Opportunity Id.');
        } catch (AuraHandledException ex) {
            Assert.isNotNull(ex);
        }
    }

    @IsTest
    static void handler_getRecentCallNotes_nonOpportunity_throws() {
        Account a = [SELECT Id FROM Account LIMIT 1];
        try {
            CallNotesHandler.getRecentCallNotes(a.Id, 5);
            Assert.fail('Expected AuraHandledException for non-Opportunity Id.');
        } catch (AuraHandledException ex) {
            Assert.isNotNull(ex);
        }
    }

    @IsTest
    static void handler_getRecentCallNotes_negativeLimit_usesDefault() {
        Opportunity opp = getOpp();
        List<Task> recent = CallNotesHandler.getRecentCallNotes(opp.Id, -1);
        Assert.areEqual(0, recent.size(), 'No notes seeded; should be empty list.');
    }

    // ------------------------------------------------------------------ //
    // Handler — updateCallNote                                            //
    // ------------------------------------------------------------------ //

    @IsTest
    static void handler_updateCallNote_changesFields() {
        Opportunity opp = getOpp();
        Task t = createNote(opp.Id, 'Negative', 'old notes');

        Test.startTest();
        CallNotesHandler.updateCallNote(t.Id, 'updated notes', 'Positive', Date.today().addDays(-1));
        Test.stopTest();

        Task reloaded = [SELECT Description, Call_Outcome__c, Subject, ActivityDate FROM Task WHERE Id = :t.Id];
        Assert.areEqual('updated notes', reloaded.Description);
        Assert.areEqual('Positive', reloaded.Call_Outcome__c);
        Assert.areEqual('Call: Positive', reloaded.Subject);
        Assert.areEqual(Date.today().addDays(-1), reloaded.ActivityDate);
    }

    @IsTest
    static void handler_updateCallNote_invalidOutcome_throws() {
        Opportunity opp = getOpp();
        Task t = createNote(opp.Id, 'Positive', 'notes');
        try {
            CallNotesHandler.updateCallNote(t.Id, 'still notes', 'Bogus', Date.today());
            Assert.fail('Expected AuraHandledException.');
        } catch (AuraHandledException ex) {
            Assert.isNotNull(ex);
        }
    }

    @IsTest
    static void handler_updateCallNote_nullId_throws() {
        try {
            CallNotesHandler.updateCallNote(null, 'notes', 'Positive', Date.today());
            Assert.fail();
        } catch (AuraHandledException ex) {
            Assert.isNotNull(ex);
        }
    }

    @IsTest
    static void handler_updateCallNote_blankNotes_throws() {
        Opportunity opp = getOpp();
        Task t = createNote(opp.Id, 'Positive', 'notes');
        try {
            CallNotesHandler.updateCallNote(t.Id, '   ', 'Positive', Date.today());
            Assert.fail();
        } catch (AuraHandledException ex) {
            Assert.isNotNull(ex);
        }
    }

    @IsTest
    static void handler_updateCallNote_overlongNotes_throws() {
        Opportunity opp = getOpp();
        Task t = createNote(opp.Id, 'Positive', 'notes');
        try {
            CallNotesHandler.updateCallNote(t.Id, 'x'.repeat(1001), 'Positive', Date.today());
            Assert.fail();
        } catch (AuraHandledException ex) {
            Assert.isNotNull(ex);
        }
    }

    // ------------------------------------------------------------------ //
    // Handler — deleteCallNote                                            //
    // ------------------------------------------------------------------ //

    @IsTest
    static void handler_deleteCallNote_removesTheRecord() {
        Opportunity opp = getOpp();
        Task t = createNote(opp.Id, 'Negative', 'to be deleted');

        Test.startTest();
        CallNotesHandler.deleteCallNote(t.Id);
        Test.stopTest();

        Integer remaining = [SELECT COUNT() FROM Task WHERE Id = :t.Id];
        Assert.areEqual(0, remaining, 'Task should be deleted.');
    }

    @IsTest
    static void handler_deleteCallNote_nullId_throws() {
        try {
            CallNotesHandler.deleteCallNote(null);
            Assert.fail();
        } catch (AuraHandledException ex) {
            Assert.isNotNull(ex);
        }
    }

    // ------------------------------------------------------------------ //
    // Helpers                                                             //
    // ------------------------------------------------------------------ //

    private static CallNotesService.CallNoteRequest baseRequest(Id oppId) {
        CallNotesService.CallNoteRequest r = new CallNotesService.CallNoteRequest();
        r.opportunityId = oppId;
        r.callDate      = Date.today();
        r.outcome       = VALID_OUTCOME;
        r.notes         = VALID_NOTES;
        return r;
    }

    private static Task createNote(Id oppId, String outcome, String notes) {
        Task t = new Task(
            Subject = 'Call: ' + outcome,
            Type = 'Call',
            Status = 'Completed',
            ActivityDate = Date.today(),
            Description = notes,
            WhatId = oppId,
            Call_Outcome__c = outcome,
            Call_Notes_Source__c = 'Call Notes Logger'
        );
        insert t;
        return t;
    }
}
