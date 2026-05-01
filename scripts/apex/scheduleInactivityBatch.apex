// Schedules OpportunityInactivityBatch to run every day at 07:00 (org TZ).
// Run via: sf apex run -f scripts/apex/scheduleInactivityBatch.apex
//
// Cron: seconds minutes hours day-of-month month day-of-week year
//                ↓        ↓
String cron = '0 0 7 * * ?';
System.schedule('OppInactivityDaily', cron, new OpportunityInactivityBatch());
System.debug('Scheduled OppInactivityDaily with cron: ' + cron);
