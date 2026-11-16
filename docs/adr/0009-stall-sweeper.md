# ADR 0009: Sweep for due messages every 15 minutes, and wake processing as the Automated Process user

- **Status:** Accepted
- **Date:** 2026-11-16
- **Deciders:** Chad Countryman

## Context

Processing is self-driving while work keeps arriving: intake enqueues a job (ADR 0007), and each job's Finalizer enqueues the next one when the batch was full or a retry is due within 10 minutes (ADR 0006). Three gaps remain:

1. A retry more than 10 minutes away has no job waiting for it. With a 60-minute backoff cap, that's most late retries.
2. An enqueue can be lost: a Finalizer whose recovery failed doesn't continue (ADR 0006's known limit), and a job aborted in Setup leaves its messages waiting.
3. Nobody hears about it. A message that always breaks the job never reaches `Dead`, so the `Dead` alert never fires.

ADR 0006 keeps no stored in-flight status, so there are no abandoned locks to reset. A message is just **due**: `Received`, or `Failed` with `Next_Attempt_At__c` passed. Something has to find due messages that no job is taking, start a job, and alert when they sit there.

Platform facts that shape the design:

- A scheduled job runs as the user who scheduled it (proven in apex-platform-logging). It isn't the Automated Process user, which stores every event-borne message (ADR 0007).
- A user with View All but not Modify All can read and lock another owner's message, but a user-mode update fails with `INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY` (proven 2026-11-15, ADR 0006). So a processor job the sweeper enqueues itself would run as the scheduler and fail on every row it claimed. In a dev org this is hidden: System Administrator has Modify All Data.
- A Platform Event trigger runs as the Automated Process user, and so does the Queueable it enqueues (proven in apex-platform-logging and in probe 2). Checked again for this feature in a scratch org (2026-11-16): an admin published `Processor_Wake_Event__e`, and the `MessageProcessorJob` it produced ran as Automated Process.
- Cron's finest granularity is a fixed minute of each hour, so a 15-minute cadence needs four schedules. An unlocked package can't run a post-install script, so scheduling is a setup step.
- A high-volume Platform Event can be defined with no custom fields.

## Options

### How the sweeper starts a job it can't run itself

1. **Publish a data-free `Processor_Wake_Event__e`; its trigger calls `MessageProcessing.enqueue()`** (chosen). For: the job runs as the Automated Process user, the same user that stores and processes every other message, so ownership never splits; the scheduler only reads and publishes; the duplicate signature still keeps one job queued, so waking twice costs nothing. Against: one more event and trigger, and the start is asynchronous (seconds).
2. **Enqueue directly and require a scheduler with Modify All on `Inbound_Message__c`.** Against: Modify All requires Delete, and the package never deletes messages (ADR 0002); the job's alerts and handlers would then run as a second user, so their callout permissions would need setting up twice.
3. **Write statuses in system mode in `MessageLifecycle`.** Against: it drops ADR 0006's user-mode updates on every path to fix one caller.
4. **Have the Automated Process user call `System.schedule` from a trigger.** Against: an unusual setup that operators can't easily see or manage, and a scheduled job owned by a user nobody can log in as.

### What counts as stalled

1. **Due for longer than `Stall_After_Minutes__c`, default 30** (chosen). That's two sweeps: a retry the Finalizer left for the sweeper is woken within 15 minutes and isn't flagged, while a job that keeps dying, a lost enqueue or a backlog that isn't draining is. For: one rule, subscriber-tunable. Against: a large but healthy backlog older than 30 minutes is reported. That's the point: it isn't keeping up.
2. **Only `Received` messages.** Against: misses the message that always breaks the job, which stays `Failed` and overdue.
3. **Check for a queued `AsyncApexJob` before alerting.** Against: one more query, and a queued job that never takes the message is still a stall.

### Alerts

1. **One WARNING per sweep while anything is stalled, with a count (capped at "200 or more") and the first 10 Ids** (chosen). Stateless, at most four an hour. Ids and counts only, as elsewhere, because errors can quote payload data.
2. **Alert once per stall and remember it.** Against: needs stored state and a rule for when a stall ends.
3. **A `COUNT()` for the exact figure.** Against: a count over a large backlog uses the synchronous query-row budget (50,000), and the exact number doesn't change what the operator does.

### Scheduler permissions

1. **A new `Event_Ingestion_Sweeper` permission set**: Read and View All on `Inbound_Message__c`, read on `Status__c` and `Next_Attempt_At__c`, Create on the wake event (chosen). `selectDue` selects only `Id`, `Status__c`, `Next_Attempt_At__c` and `CreatedDate`, so the set needs no access to payloads or errors.
2. **Reuse `Event_Ingestion_Viewer` plus Create on the event.** Against: Viewer reads `Payload__c`, which the sweeper never needs.

## Decision

`StallSweeperSchedulable` runs at :00, :15, :30 and :45 as the user who scheduled it (`scripts/schedule-stall-sweeper.apex`, `npm run org:schedule-sweeper`). It calls `IStallDetector.sweep`, bound by `DI_Binding.Stall_Detector` to `StallDetector`, which:

1. reads up to 200 messages due since `now − Stall_After_Minutes__c` through `IInboundMessagesSelector.selectDue` (user mode, no lock);
2. when none are stalled, reads one message due now;
3. calls `MessageProcessing.requestRun()` when anything is due. That publishes `Processor_Wake_Event__e` (Publish Immediately), and `ProcessorWakeEventTrigger` → `ProcessorWakeEventsDomain` enqueues one processor job as the Automated Process user;
4. raises one WARNING through `IAlertSink` when anything is stalled, and returns a `StallReport`.

## Consequences

- Limits per sweep: 1 SOQL when something is stalled, else 2, reading at most 201 rows; 1 event publish; no DML. The wake trigger costs 1 Queueable per run.
- The due filter is on `Status__c` and is not selective on a large table. That's acceptable in scheduled Apex (the non-selective error applies to triggers); revisit with an index if `Processed` rows reach the millions, or archive them.
- **Setup step:** assign `Event_Ingestion_Sweeper` to the scheduling user, plus whatever the bound `IAlertSink` needs (apex-platform-logging's Slack sink needs principal access on its External Credential), then run the script as that user. Scheduling Apex needs Author Apex, so in practice the scheduler is an admin or an integration admin; the permission set still matters, because an admin gets no field access to a package's new fields. Running it twice fails with "already scheduled" and changes nothing.
- A sweep that fails (for example, the scheduler lost the permission set) fails visibly in Setup → Apex Jobs; the next sweep runs anyway.
- A wake that can't enqueue is logged, not retried: the event carries no data, and the next sweep asks again.
- This settles ADR 0002's and 0006's open question for the sweeper: it never updates messages, and the job it asks for runs as the user that owns them. Apex producers that call `IMessageStore.append` as another user (ADR 0007) are still outside it: the sweeper wakes processing for their messages too, and the Automated Process job can update them (probe 2).
- Rollback posture: delete the four "aei stall sweeper" jobs in Setup → Scheduled Jobs to stop sweeping; a `Trigger_Setting__mdt` row for `Processor_Wake_Event__e` keeps the alerts and stops the wake.
