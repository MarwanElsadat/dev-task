/**
 * Apex controller for the accountActivityTile LWC. Returns a single DTO so the
 * LWC needs only one round-trip per render — cheaper than splitting into
 * multiple wires for each KPI.
 *
 * - One SOQL query against Opportunity, filtered at the WHERE clause so we
 *   never pull data we don't need.
 * - Aggregates (open count, pipeline value, at-risk count) computed in Apex
 *   over the in-memory list — fewer queries and acceptable for the typical
 *   per-Account fan-out (well under SOQL row limits).
 * - cacheable=true so the platform serves repeats from the wire cache;
 *   refreshApex from the LWC invalidates it on demand.
 */
public with sharing class AccountActivityController {

    private static final Integer INACTIVITY_DAYS = 14;

    @AuraEnabled(cacheable=true)
    public static AccountActivitySummary getAccountActivitySummary(Id accountId) {
        if (accountId == null) {
            throwAura('Account Id is required.');
        }
        if (accountId.getSobjectType() != Account.SObjectType) {
            throwAura('Provided Id is not an Account.');
        }

        Date threshold = Date.today().addDays(-INACTIVITY_DAYS);

        List<Opportunity> opps;
        try {
            opps = [
                SELECT Id, Name, Amount, StageName, CloseDate, LastActivityDate
                FROM Opportunity
                WHERE AccountId = :accountId
                  AND IsClosed = false
                WITH USER_MODE
                ORDER BY Amount DESC NULLS LAST, CloseDate ASC
            ];
        } catch (Exception e) {
            throwAura('Could not load Opportunities: ' + e.getMessage());
            return null; // unreachable
        }

        AccountActivitySummary summary = new AccountActivitySummary();
        summary.openCount     = 0;
        summary.pipelineValue = 0;
        summary.atRiskCount   = 0;
        summary.opportunities = new List<OpportunitySummary>();

        for (Opportunity o : opps) {
            summary.openCount += 1;
            if (o.Amount != null) {
                summary.pipelineValue += o.Amount;
            }
            Boolean atRisk = (o.LastActivityDate == null || o.LastActivityDate < threshold);
            if (atRisk) {
                summary.atRiskCount += 1;
            }
            OpportunitySummary row = new OpportunitySummary();
            row.id               = o.Id;
            row.name             = o.Name;
            row.amount           = o.Amount;
            row.stageName        = o.StageName;
            row.closeDate        = o.CloseDate;
            row.lastActivityDate = o.LastActivityDate;
            row.status           = atRisk ? 'At Risk' : 'Active';
            summary.opportunities.add(row);
        }
        return summary;
    }

    private static void throwAura(String msg) {
        AuraHandledException ahe = new AuraHandledException(msg);
        ahe.setMessage(msg);
        throw ahe;
    }

    public class AccountActivitySummary {
        @AuraEnabled public Integer openCount;
        @AuraEnabled public Decimal pipelineValue;
        @AuraEnabled public Integer atRiskCount;
        @AuraEnabled public List<OpportunitySummary> opportunities;
    }

    public class OpportunitySummary {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public Decimal amount;
        @AuraEnabled public String stageName;
        @AuraEnabled public Date closeDate;
        @AuraEnabled public Date lastActivityDate;
        @AuraEnabled public String status;          // 'Active' | 'At Risk'
    }
}
