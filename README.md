# NimbusPoint Salesforce Developer Assessment

Solution to the Mid–Senior Sales Cloud assessment: structured call-note logging plus a daily inactivity alert for high-value Opportunities.

## Solution overview

Two pain points, two halves of the solution:

1. **Call notes are inconsistent** → a structured `callNotesLogger` LWC on the Opportunity record page that captures Contact, Date, Outcome, and Notes, persists each entry as a `Task`, and shows the last five so reps can see what happened recently.
2. **High-value deals go cold** → a daily `OpportunityInactivityBatch` that scans for open Opps ≥ £10,000 with no activity in the last 14 days and pings the Owner via a Salesforce bell notification (one digest per Owner, not per Opp). Plus an `accountActivityTile` LWC on the Account record page that surfaces the same signal at-a-glance.

### Architecture

Three layers, kept separate so each is testable on its own:

```
┌──────────────────────────────────────────────────────────────────┐
│  LWC                                                              │
│  ─────                                                            │
│  callNotesLogger ──┐         accountActivityTile                  │
│  (Opp page)        │         (Account page)                       │
└────────────────────┼─────────────────┬────────────────────────────┘
                     │                 │
┌────────────────────┴─────────────────┴────────────────────────────┐
│  Apex handler / controller (LWC-facing)                           │
│  ──────────────────────────────────────                           │
│  CallNotesHandler            AccountActivityController            │
│  (logCallNote, getRecent…,                                        │
│   updateCallNote, deleteCallNote)                                 │
└────────────────────┬─────────────────────────────────────┬────────┘
                     │                                     │
┌────────────────────┴─────────────────────────────────────┴────────┐
│  Apex service (pure logic)                Async                   │
│  ───────────────────────                  ──────                  │
│  CallNotesService (bulkified)             OpportunityInactivityBatch │
│  CallNotesException                       (Batchable + Schedulable)  │
└──────────────────────────────────────────────────────────────────┘
```

* **Service layer** (`CallNotesService`) holds pure business logic — no `@AuraEnabled`, no LWC concerns. Bulkified from day one so the same code path is reusable from triggers, queueables, batches.
* **Handler layer** (`CallNotesHandler`, `AccountActivityController`) is the only entry point from LWC. Translates loose JS payloads into typed DTOs, catches `CallNotesException` and unexpected exceptions, and rethrows them as `AuraHandledException` (with `setMessage()` so the message actually surfaces — that's a known platform quirk).
* **Async layer** (`OpportunityInactivityBatch`) implements both `Database.Batchable<sObject>` and `Schedulable` so a single class scans, groups, and schedules.

## Custom fields

Two restricted picklists added to `Task`. Everything else uses standard fields.

| Object | API name                | Type                          | Values                                      | Purpose |
|--------|-------------------------|-------------------------------|---------------------------------------------|---------|
| Task   | `Call_Outcome__c`       | Picklist (restricted)         | Positive · Neutral · Negative · No Answer   | Structured outcome for call-type Tasks. Cleaner than overloading `Status` or `Description`. |
| Task   | `Call_Notes_Source__c`  | Picklist (restricted)         | Call Notes Logger · Other (default)         | Tags Tasks created via the LWC so the recent-notes query can filter to LWC-sourced entries. |

## Deployment

### Prerequisites

* Salesforce CLI (`sf`) installed and authenticated to the target Developer Org as the default org (`sf org login web -a NimbusPointDev -d`).
* Node 18+ if you want to run the Jest setup (optional).

### Deploy

```sh
# from the repo root
./scripts/deploy.sh           # deploys force-app/ to the default org
./scripts/deploy.sh -c        # deploys + runs all local tests
./scripts/deploy.sh -o myOrg  # deploy to a specific org alias
```

…or directly:

```sh
sf project deploy start -d force-app
```

### Schedule the inactivity batch

Once deployed, run this anonymous Apex once to schedule the daily run at 07:00 (org time zone):

```sh
sf apex run -f scripts/apex/scheduleInactivityBatch.apex
```

### Add the LWCs to record pages

The `*.js-meta.xml` files target `lightning__RecordPage` for `Opportunity` (`callNotesLogger`) and `Account` (`accountActivityTile`). Drag them onto the relevant record pages via **Setup → Lightning App Builder → Edit Page** for each object. (FlexiPage definitions weren't included in this submission so we don't override the org's default layouts.)

### Run the test suite

```sh
sf apex run test -l RunLocalTests --code-coverage --result-format human --wait 10
```

## Decisions worth defending

**Batch vs Scheduled Flow vs Platform Event.** Batch wins for this scale: `Database.QueryLocator` iterates up to 50M rows, whereas Flow stops at 50,000 records per run and doesn't bulkify notifications neatly. Platform Events are for real-time fan-out, not nightly scans. The chosen Batchable/Schedulable hybrid lets one class own the full lifecycle.

**Where the inactivity rule reads `LastActivityDate`.** The platform already maintains `Opportunity.LastActivityDate` as a rolled-up max of related Task and Event activity dates. Filtering on it directly avoids a second SOQL on `Task` per Opportunity, which would be a governor-limit timebomb at 50K Opportunities.

**Client vs server validation.** Both, with the server as source of truth. The LWC validates eagerly for UX feedback (disabled submit, char counter, `reportValidity()`); `CallNotesService.validate()` re-checks every field server-side and throws `CallNotesException` if anything is wrong. Client validation is never the *only* line of defence.

**`AccessLevel.USER_MODE` on every DML / SOQL.** Modern equivalent of `WITH SECURITY_ENFORCED` plus FLS — enforces FLS/CRUD for the running user without hand-rolled `isCreateable()` checks. Cleaner than `with sharing` alone.

**One digest per Owner, not one per Opp.** A rep with 20 stale Opportunities gets a single bell notification ("20 stale high-value Opportunities") with the first 5 listed. Better UX, fewer API calls.

**Custom DTOs over loose Maps for service inputs.** `CallNotesService.CallNoteRequest` is typed and easy to extend; the handler's `Map<String, Object>` boundary stays at the LWC seam where JS-serialised types are unavoidable.

## Assumptions

* Org is single-currency (GBP). `Opportunity.Amount` is treated as a plain Decimal; multi-currency support would require a `CurrencyIsoCode` field check.
* Org sharing model on Task is the default. `USER_MODE` enforces FLS/CRUD; if record-access concerns arise, swap `with sharing` strategies as needed.
* `CustomNotificationType` "NimbusPoint_Inactivity_Alert" is enabled for relevant users (the metadata is included).
* `LastActivityDate` is the right inactivity signal. The product team may later want to track email activity captured by Einstein Activity Capture; that already feeds into `LastActivityDate` when EAC writes a Task, so no code change required.

## Known limitations / what I'd do differently with more time

* **Apex Enterprise Patterns.** The service/handler split is a lightweight version of fflib. With more time I'd extract `OpportunityInactivitySelector`, use a `UnitOfWork` for DML, and split the LWC controller from the service per fflib conventions.
* **Custom Metadata-driven thresholds.** The 14-day window and £10,000 amount are constants. A `Inactivity_Rule__mdt` would let admins change thresholds per stage, region, or product line without a deploy.
* **`lightning-modal` for inline edit.** Inline-expansion works for one row at a time but a modal would feel cleaner for richer editing (Contact change, history, etc.). Not done to keep the form cohesive.
* **Platform Cache for the recent-notes wire.** The `@AuraEnabled(cacheable=true)` already piggy-backs on the wire cache, but org-level Platform Cache would survive page navigation.
* **Per-user opt-out for the bell.** A `User.Inactivity_Alerts_Opt_In__c` flag plus a check in `sendNotifications` would let reps mute it.
* **More granular permissions.** A Custom Permission `CallNotes_Delete` gating `deleteCallNote` so non-admins can't wipe peer-logged notes.
* **Custom Labels for every UI string.** Currently the LWC strings are hard-coded English; Custom Labels enable translation and admin tweaks.
* **Integration tests in Jest.** The Apex side is well-covered; the LWC side has no Jest tests in this submission. Standard `lwc-jest` mocks for `getRecord`, `getRecentCallNotes`, and `LightningConfirm` would round it out.

## File map

```
force-app/main/default
├── classes/
│   ├── AccountActivityController.cls         (+ test)
│   ├── CallNotesException.cls
│   ├── CallNotesHandler.cls
│   ├── CallNotesService.cls
│   ├── CallNotesServiceTest.cls
│   ├── OpportunityInactivityBatch.cls
│   └── OpportunityInactivityBatchTest.cls
├── lwc/
│   ├── callNotesLogger/                      (Opportunity record page)
│   └── accountActivityTile/                  (Account record page)
├── notificationtypes/
│   └── NimbusPoint_Inactivity_Alert.notiftype-meta.xml
└── objects/Task/fields/
    ├── Call_Outcome__c.field-meta.xml
    └── Call_Notes_Source__c.field-meta.xml

manifest/package.xml
scripts/
├── deploy.sh
└── apex/
    ├── scheduleInactivityBatch.apex
    └── seedDemoData.apex
```
