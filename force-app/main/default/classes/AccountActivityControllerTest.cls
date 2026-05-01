/**
 * Tests for AccountActivityController. Covers the aggregate logic (counts,
 * pipeline value, at-risk classification) and the validation paths.
 *
 * LastActivityDate is platform-maintained from the related Tasks/Events, so
 * we seed Tasks with specific ActivityDates and let the platform compute it.
 */
@IsTest
private class AccountActivityControllerTest {

    @TestSetup
    static void seed() {
        Account acc = new Account(Name = 'Activity Test Co');
        insert acc;

        // 1) Active Opp with a Task today
        Opportunity active = new Opportunity(
            Name = 'Active Opp', AccountId = acc.Id,
            StageName = 'Prospecting', CloseDate = Date.today().addDays(30),
            Amount = 50000
        );
        // 2) At-risk Opp — no activity at all
        Opportunity stale = new Opportunity(
            Name = 'Stale Opp', AccountId = acc.Id,
            StageName = 'Qualification', CloseDate = Date.today().addDays(45),
            Amount = 30000
        );
        // 3) At-risk Opp — old activity
        Opportunity oldActivity = new Opportunity(
            Name = 'Old Activity Opp', AccountId = acc.Id,
            StageName = 'Negotiation', CloseDate = Date.today().addDays(60),
            Amount = 15000
        );
        // 4) Closed Won — should not count as open
        Opportunity closedWon = new Opportunity(
            Name = 'Won Opp', AccountId = acc.Id,
            StageName = 'Closed Won', CloseDate = Date.today().addDays(-1),
            Amount = 99999
        );
        insert new List<Opportunity>{ active, stale, oldActivity, closedWon };

        insert new Task(
            Subject = 'Recent Call', Status = 'Completed', Type = 'Call',
            ActivityDate = Date.today(), WhatId = active.Id
        );
        insert new Task(
            Subject = 'Old Call', Status = 'Completed', Type = 'Call',
            ActivityDate = Date.today().addDays(-30), WhatId = oldActivity.Id
        );
    }

    @IsTest
    static void summary_classifiesActiveAndAtRisk() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        AccountActivityController.AccountActivitySummary s =
            AccountActivityController.getAccountActivitySummary(acc.Id);
        Test.stopTest();

        Assert.areEqual(3, s.openCount, '3 Opportunities are open (closed won excluded).');
        Assert.areEqual(95000, s.pipelineValue, '50k + 30k + 15k = 95k pipeline.');
        Assert.areEqual(2, s.atRiskCount, 'Stale + Old-activity Opps should be at risk.');
        Assert.areEqual(3, s.opportunities.size());

        Map<String, AccountActivityController.OpportunitySummary> byName =
            new Map<String, AccountActivityController.OpportunitySummary>();
        for (AccountActivityController.OpportunitySummary row : s.opportunities) {
            byName.put(row.name, row);
        }
        Assert.areEqual('Active', byName.get('Active Opp').status);
        Assert.areEqual('At Risk', byName.get('Stale Opp').status);
        Assert.areEqual('At Risk', byName.get('Old Activity Opp').status);
        Assert.isFalse(byName.containsKey('Won Opp'),
            'Closed Won Opportunities should never appear in the summary.');
    }

    @IsTest
    static void summary_emptyAccount_returnsZeros() {
        Account empty = new Account(Name = 'Empty Co');
        insert empty;

        AccountActivityController.AccountActivitySummary s =
            AccountActivityController.getAccountActivitySummary(empty.Id);

        Assert.areEqual(0, s.openCount);
        Assert.areEqual(0, s.pipelineValue);
        Assert.areEqual(0, s.atRiskCount);
        Assert.isTrue(s.opportunities.isEmpty());
    }

    @IsTest
    static void summary_nullId_throws() {
        try {
            AccountActivityController.getAccountActivitySummary(null);
            Assert.fail('Expected AuraHandledException.');
        } catch (AuraHandledException ex) {
            Assert.isNotNull(ex);
        }
    }

    @IsTest
    static void summary_nonAccountId_throws() {
        Opportunity o = [SELECT Id FROM Opportunity LIMIT 1];
        try {
            AccountActivityController.getAccountActivitySummary(o.Id);
            Assert.fail('Expected AuraHandledException.');
        } catch (AuraHandledException ex) {
            Assert.isNotNull(ex);
        }
    }
}
