/**
 * Daily batch that finds high-value Opportunities going stale and pings
 * their Owner with a Salesforce bell notification.
 *
 * Criteria (per the spec):
 *   - StageName not Closed Won / Closed Lost   → IsClosed = false
 *   - Amount >= £10,000
 *   - No Task or Event activity in the past 14 days
 *
 * Implementation choice — Batch over Scheduled Flow / Platform Event:
 *   - Designed for tens of thousands of Opportunity records; Database.QueryLocator
 *     can iterate up to 50M rows whereas Flow stops at 50k records per run.
 *   - Filter pushed down to SOQL (no in-memory filtering) so we never load
 *     records we won't act on.
 *   - LastActivityDate is platform-maintained from open + completed Tasks
 *     and Events — using it avoids a second SOQL on Tasks per Opportunity
 *     (which would be a governor-limit timebomb at scale).
 *   - Notifications are grouped by OwnerId so a rep with 20 stale Opps gets
 *     one notification, not 20 (better UX, fewer API calls).
 *
 * Scheduling:
 *   System.schedule('OppInactivityDaily', '0 0 7 * * ?',
 *                   new OpportunityInactivityBatch());
 */
public with sharing class OpportunityInactivityBatch
        implements Database.Batchable<SObject>, Database.Stateful, Schedulable {

    public static final Decimal MIN_AMOUNT     = 10000;
    public static final Integer INACTIVITY_DAYS = 14;
    public static final String NOTIFICATION_TYPE_NAME = 'NimbusPoint_Inactivity_Alert';

    /** Carried across chunks via Database.Stateful — used for finish() reporting. */
    @TestVisible private Integer totalQualifying = 0;
    @TestVisible private Integer totalOwnersNotified = 0;
    @TestVisible private List<String> errors = new List<String>();

    // -------------------------------------------------------------------- //
    // Schedulable                                                           //
    // -------------------------------------------------------------------- //

    public void execute(SchedulableContext sc) {
        Database.executeBatch(this, 200);
    }

    // -------------------------------------------------------------------- //
    // Batchable                                                             //
    // -------------------------------------------------------------------- //

    public Database.QueryLocator start(Database.BatchableContext bc) {
        Date threshold = Date.today().addDays(-INACTIVITY_DAYS);
        // Push the filter into SOQL so we never pull data we don't act on.
        return Database.getQueryLocator([
            SELECT Id, Name, OwnerId, Owner.Email, Amount, LastActivityDate, StageName
            FROM Opportunity
            WHERE IsClosed = false
              AND Amount >= :MIN_AMOUNT
              AND (LastActivityDate = null OR LastActivityDate < :threshold)
        ]);
    }

    public void execute(Database.BatchableContext bc, List<Opportunity> scope) {
        if (scope == null || scope.isEmpty()) return;
        totalQualifying += scope.size();

        // Group stale Opps by Owner so each Owner gets one digest notification
        // per chunk rather than N notifications.
        Map<Id, List<Opportunity>> oppsByOwner = new Map<Id, List<Opportunity>>();
        for (Opportunity o : scope) {
            if (!oppsByOwner.containsKey(o.OwnerId)) {
                oppsByOwner.put(o.OwnerId, new List<Opportunity>());
            }
            oppsByOwner.get(o.OwnerId).add(o);
        }

        Id notificationTypeId = lookupNotificationTypeId();
        sendNotifications(oppsByOwner, notificationTypeId);
        totalOwnersNotified += oppsByOwner.size();
    }

    public void finish(Database.BatchableContext bc) {
        // No DML/notifications here — the work is already done. A real-world
        // implementation would persist a custom log object or post to a
        // monitoring channel. Logging via System.debug for now so the
        // outcome shows up in the Apex log.
        System.debug(LoggingLevel.INFO,
            'OpportunityInactivityBatch finished: ' +
            totalQualifying + ' qualifying Opportunities; ' +
            totalOwnersNotified + ' owner notifications sent; ' +
            errors.size() + ' errors.'
        );
    }

    // -------------------------------------------------------------------- //
    // Notification dispatch                                                 //
    // -------------------------------------------------------------------- //

    private Id lookupNotificationTypeId() {
        List<CustomNotificationType> types = [
            SELECT Id
            FROM CustomNotificationType
            WHERE DeveloperName = :NOTIFICATION_TYPE_NAME
            LIMIT 1
        ];
        return types.isEmpty() ? null : types[0].Id;
    }

    @TestVisible
    private void sendNotifications(Map<Id, List<Opportunity>> oppsByOwner, Id notificationTypeId) {
        if (notificationTypeId == null) {
            // Type wasn't deployed — log and skip rather than fail the batch.
            errors.add('CustomNotificationType "' + NOTIFICATION_TYPE_NAME + '" not found.');
            return;
        }
        for (Id ownerId : oppsByOwner.keySet()) {
            List<Opportunity> opps = oppsByOwner.get(ownerId);
            try {
                Messaging.CustomNotification notif = new Messaging.CustomNotification();
                notif.setNotificationTypeId(notificationTypeId);
                notif.setTitle(opps.size() == 1
                    ? 'Stale high-value Opportunity'
                    : opps.size() + ' stale high-value Opportunities');
                notif.setBody(buildBody(opps));
                // Deep-link to the first Opp; the body summarises the rest.
                notif.setTargetId(opps[0].Id);
                notif.send(new Set<String>{ ownerId });
            } catch (Exception e) {
                errors.add('Failed to notify owner ' + ownerId + ': ' + e.getMessage());
            }
        }
    }

    private static String buildBody(List<Opportunity> opps) {
        if (opps.size() == 1) {
            Opportunity o = opps[0];
            return o.Name + ' — no activity in the last '
                 + INACTIVITY_DAYS + ' days.';
        }
        // Multi-line digest for multiple stale Opps.
        List<String> lines = new List<String>();
        Integer shown = 0;
        for (Opportunity o : opps) {
            if (shown >= 5) {
                lines.add('… and ' + (opps.size() - shown) + ' more');
                break;
            }
            lines.add('• ' + o.Name);
            shown++;
        }
        return String.join(lines, '\n');
    }
}
