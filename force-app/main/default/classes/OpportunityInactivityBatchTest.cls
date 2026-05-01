/**
 * Tests for OpportunityInactivityBatch.
 *
 * Important platform quirk: Opportunity.LastActivityDate is auto-rolled-up
 * from related Tasks/Events. We can't write to it directly, but creating a
 * Task with a specific ActivityDate causes the platform to recalculate it
 * immediately — and that's what the batch reads.
 *
 * Verifying that CustomNotification.send() actually fired is hard inside
 * Apex tests because the platform doesn't expose a queryable inbox. Instead
 * we lean on Database.Stateful counters (totalQualifying / totalOwnersNotified)
 * that the batch maintains, and assert those.
 */
@IsTest
private class OpportunityInactivityBatchTest {

    @TestSetup
    static void seed() {
        Account acc = new Account(Name = 'Inactivity Test Co');
        insert acc;

        Date oldDate    = Date.today().addDays(-30);
        Date recentDate = Date.today().addDays(-3);

        // 1) QUALIFIES — no activity, high value, open
        Opportunity qualNoActivity = new Opportunity(
            Name = 'Qual: No Activity', AccountId = acc.Id,
            StageName = 'Prospecting', CloseDate = Date.today().addDays(60),
            Amount = 50000
        );
        // 2) QUALIFIES — old activity (>14 days)
        Opportunity qualOldActivity = new Opportunity(
            Name = 'Qual: Old Activity', AccountId = acc.Id,
            StageName = 'Qualification', CloseDate = Date.today().addDays(60),
            Amount = 25000
        );
        // 3) Excluded — recent activity
        Opportunity recentActivity = new Opportunity(
            Name = 'Excl: Recent Activity', AccountId = acc.Id,
            StageName = 'Qualification', CloseDate = Date.today().addDays(60),
            Amount = 30000
        );
        // 4) Excluded — under £10k
        Opportunity lowValue = new Opportunity(
            Name = 'Excl: Low Value', AccountId = acc.Id,
            StageName = 'Prospecting', CloseDate = Date.today().addDays(60),
            Amount = 5000
        );
        // 5) Excluded — Closed Won
        Opportunity closedWon = new Opportunity(
            Name = 'Excl: Closed Won', AccountId = acc.Id,
            StageName = 'Closed Won', CloseDate = Date.today().addDays(-1),
            Amount = 75000
        );
        // 6) Excluded — Closed Lost
        Opportunity closedLost = new Opportunity(
            Name = 'Excl: Closed Lost', AccountId = acc.Id,
            StageName = 'Closed Lost', CloseDate = Date.today().addDays(-1),
            Amount = 75000
        );
        insert new List<Opportunity>{
            qualNoActivity, qualOldActivity, recentActivity, lowValue, closedWon, closedLost
        };

        // Seed Tasks to drive LastActivityDate rollup.
        insert new List<Task>{
            new Task(Subject = 'Old', Status = 'Completed', Type = 'Call',
                     ActivityDate = oldDate,    WhatId = qualOldActivity.Id),
            new Task(Subject = 'Recent', Status = 'Completed', Type = 'Call',
                     ActivityDate = recentDate, WhatId = recentActivity.Id)
        };
    }

    // ------------------------------------------------------------------ //
    // Qualifying / non-qualifying classification                          //
    // ------------------------------------------------------------------ //

    @IsTest
    static void qualifyingOpportunitiesAreIdentified() {
        OpportunityInactivityBatch job = new OpportunityInactivityBatch();

        Test.startTest();
        Database.executeBatch(job, 200);
        Test.stopTest();

        // Two Opps qualify: 'Qual: No Activity' and 'Qual: Old Activity'.
        Assert.areEqual(2, job.totalQualifying,
            'Exactly the two qualifying Opportunities should be processed.');
        // Both qualifying Opps are owned by the running user — single chunk
        // groups by OwnerId so we expect exactly one owner-notification pair.
        Assert.areEqual(1, job.totalOwnersNotified,
            'Two stale Opps for one Owner = one digest notification.');
    }

    @IsTest
    static void nonQualifyingOpportunitiesAreExcluded() {
        // Direct query against the same WHERE clause the batch uses,
        // independently of the batch class, to assert the filter.
        Date threshold = Date.today().addDays(-OpportunityInactivityBatch.INACTIVITY_DAYS);

        List<Opportunity> qualifying = [
            SELECT Id, Name FROM Opportunity
            WHERE IsClosed = false
              AND Amount >= :OpportunityInactivityBatch.MIN_AMOUNT
              AND (LastActivityDate = null OR LastActivityDate < :threshold)
        ];
        Set<String> qualifyingNames = new Set<String>();
        for (Opportunity o : qualifying) qualifyingNames.add(o.Name);

        Assert.isTrue(qualifyingNames.contains('Qual: No Activity'));
        Assert.isTrue(qualifyingNames.contains('Qual: Old Activity'));
        Assert.isFalse(qualifyingNames.contains('Excl: Recent Activity'),
            'Recent activity should disqualify.');
        Assert.isFalse(qualifyingNames.contains('Excl: Low Value'),
            'Amount under threshold should disqualify.');
        Assert.isFalse(qualifyingNames.contains('Excl: Closed Won'),
            'Closed Won should disqualify (IsClosed=true).');
        Assert.isFalse(qualifyingNames.contains('Excl: Closed Lost'),
            'Closed Lost should disqualify (IsClosed=true).');
    }

    // ------------------------------------------------------------------ //
    // Bulk                                                                //
    // ------------------------------------------------------------------ //

    @IsTest
    static void bulk_200OpportunitiesProcessedInOneBatch() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < 200; i++) {
            opps.add(new Opportunity(
                Name = 'Bulk Stale ' + i, AccountId = acc.Id,
                StageName = 'Prospecting', CloseDate = Date.today().addDays(60),
                Amount = 12000
            ));
        }
        insert opps;

        OpportunityInactivityBatch job = new OpportunityInactivityBatch();

        Test.startTest();
        Database.executeBatch(job, 200);
        Test.stopTest();

        // 200 new + 2 from setup = 202 qualifying.
        Assert.areEqual(202, job.totalQualifying,
            '200 bulk + 2 seeded qualifying Opportunities should all be processed.');
    }

    // ------------------------------------------------------------------ //
    // Schedulable                                                         //
    // ------------------------------------------------------------------ //

    @IsTest
    static void schedulable_kicksOffBatch() {
        String cron = '0 0 0 1 1 ? 2099'; // far-future, never actually fires
        Test.startTest();
        Id jobId = System.schedule(
            'OppInactivityTestSchedule',
            cron,
            new OpportunityInactivityBatch()
        );
        Test.stopTest();
        Assert.isNotNull(jobId);
        CronTrigger ct = [SELECT Id, CronExpression FROM CronTrigger WHERE Id = :jobId];
        Assert.areEqual(cron, ct.CronExpression);
    }

    // ------------------------------------------------------------------ //
    // Notification dispatch — defensive paths                             //
    // ------------------------------------------------------------------ //

    @IsTest
    static void sendNotifications_missingTypeId_recordsError() {
        // Force the no-type branch by passing null typeId directly.
        OpportunityInactivityBatch job = new OpportunityInactivityBatch();
        Map<Id, List<Opportunity>> grouped = new Map<Id, List<Opportunity>>();
        grouped.put(UserInfo.getUserId(), new List<Opportunity>{
            new Opportunity(Name = 'Won\'t actually send', StageName = 'Prospecting',
                            CloseDate = Date.today().addDays(10), Amount = 20000)
        });

        Test.startTest();
        job.sendNotifications(grouped, null);
        Test.stopTest();

        Assert.isFalse(job.errors.isEmpty(),
            'Missing CustomNotificationType id should be recorded as an error.');
        Assert.isTrue(job.errors[0].contains('not found'));
    }
}
