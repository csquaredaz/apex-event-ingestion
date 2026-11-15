# Handoff: apex-event-ingestion

Last updated: 2026-11-15

## Done

- Repository scaffolded by hand from `apex-standards:sf-repo-scaffold` (the skill sets `disable-model-invocation`), using the template on `claude-code-salesforce-skills` `main` at `0d9badd`.
- Depends on `apex-core-lib@1.1.0-1` (`04tak000000u3MbAAI`). First feature folder: `force-app/store/`.
- ADR 0001: an unlocked package with no namespace on top of A.
- Design approved 2026-11-13 (below).
- **PR 1 `chore/scaffold`** merged as `759e0fc`.
- **PR 2 `feat/message-store` merged 2026-11-15 as `6d2f0ef` (PR #2).**
  - The ready run, 43741769336, used one CI org: 30 tests from C's 4 classes only, and 100% coverage of C's 133 lines.
  - The `main` run, 43742271168, reused that result (scratch-org job skipped) and published the badge at 100%.
- **PR 2 API, approved 2026-11-15:**
  - `IMessageStore.append(List<Inbound_Message__c>)` returns one `AppendResult` per message (`ACCEPTED`, `DUPLICATE` with the stored Id, or `REJECTED` with the error).
  - DML goes through `IPartialDml` / `UserModePartialDml`, because A's Unit of Work is all-or-none.
  - There is no in-memory dedupe.
  - `MessageStoreException` is thrown when the user can't create the object or its optional producer fields. The review caught the field gap.
  - ADRs 0002 and 0003 are written.
- **PR 3 `feat/dispatch` in review (2026-11-15).** API approved 2026-11-15: `IMessageHandler`, `InboundMessage` (with `getAttempt()` and `isOlderThan`), `HandlerResult` (`SUCCESS`, `RETRYABLE`, `FATAL`), `IMessageDispatcher.dispatch(Set<Id>)` returning `Map<Id, HandlerResult>`. Internal: `GuardedMessageHandler` (Decorator), `CompositeMessageHandler`, `IMessageRouter`/`MessageRouter`, `IMessageRoutesSelector`/`MessageRoutesSelector`, `Message_Route__mdt`, three `DI_Binding` rows, `IInboundMessagesSelector.selectWithPayloadByIds`. ADRs 0004 and 0005.
  - Chad's design calls: results keyed by message Id (a missing one is `RETRYABLE`); a savepoint per handler call (a throw rolls back and retries all of that call); no route → `FATAL`, a broken route → `RETRYABLE`; dispatch writes no status (PR 4 does); handlers make no synchronous callouts.
  - Local run in `aei-dev`: 79 tests from C's 13 classes, 100% on every class; Code Analyzer 0 High, 0 Moderate. A mutation check (savepoint release removed) made the callout test fail, so the test can fail.

## Approved design

| ADR  | Decision                | Choice                                                                                                                                                                                                                                                                                                                                                                              |
| ---- | ----------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 0001 | Distribution            | Own unlocked package, no namespace, on A `1.1.0-1`. Logs through `ILogger` and alerts through `IAlertSink`; never depends on B                                                                                                                                                                                                                                                      |
| 0002 | Message store           | Custom object `Inbound_Message__c`. Status `Received → Processing → Processed`, or `Failed` and then `Dead`. Fields: `Idempotency_Key__c`, `Message_Type__c`, `Source__c`, `External_Message_Id__c`, `Payload__c`, `Payload_Ref__c`, `Status__c`, `Attempts__c`, `Next_Attempt_At__c`, `Locked_Until__c`, `Last_Error__c`, `Correlation_Id__c`, `Occurred_At__c`, `Processed_At__c` |
| 0003 | Idempotency key         | The producer's key, `Source__c + ':' + External_Message_Id__c`, in a unique, case-sensitive external Id. Insert with `allOrNone=false` through `IPartialDml` (user mode); `DUPLICATE_VALUE` means already received, including repeats within one batch (no in-memory dedupe, changed 2026-11-15). No key means rejected; no Create access throws `MessageStoreException`            |
| 0004 | Dispatch                | Bulk Command `IMessageHandler.handle(List<InboundMessage>)` returning one `HandlerResult` per message (success, retryable, fatal). `Message_Route__mdt` maps a type to handler classes (`Type.forName`). More than one route becomes a `CompositeMessageHandler`; the worst result wins                                                                                             |
| 0005 | Ordering                | No ordering guarantee. Handlers guard against stale updates with `Occurred_At__c`                                                                                                                                                                                                                                                                                                   |
| 0006 | Finalizer recovery      | `MessageProcessorJob` claims a batch `FOR UPDATE` and records the Ids in `MessageProcessorFinalizer`. On an unhandled exception the Finalizer marks unfinished messages `Failed` with exponential backoff, or `Dead` at the maximum attempts, alerts, and enqueues the next job once. Limits in `Ingestion_Setting__mdt`                                                            |
| 0007 | Intake                  | High-volume Platform Event `Inbound_Message__e` with a trigger, `RetryableException` and resume checkpoints. The Automated Process user gets `Event_Ingestion_Processor` through a setup script, so DML stays in user mode. `PlatformEventSubscriberConfig` documented as the production alternative                                                                                |
| 0008 | Claim Check (built now) | A payload over the inline limit is uploaded by the producer as a `ContentVersion`. The event carries the claim (`Payload_Ref__c`), and `IPayloadResolver` loads it at dispatch, within a per-message size cap that fits the async heap                                                                                                                                              |
| 0009 | Stall detection         | Scheduled `StallSweeper` (four schedules for a 15-minute sweep, set up as a documented step). Resets expired `Processing` locks, re-enqueues old `Received` messages that have no job, and alerts                                                                                                                                                                                   |

## Next: PR plan (every PR targets `main`, none stacked)

1. `chore/scaffold` (this PR): template, dependency, ADR 0001, this handoff. No tests, on purpose.
2. `feat/message-store`: `Inbound_Message__c`, `IdempotencyKey`, `IMessageStore`, `MessageStore`, `AppendResult`, `IInboundMessagesSelector`, `InboundMessagesSelector`, `MessageStatuses`, `MessageStoreException`, `IPartialDml`, `UserModePartialDml`, three `DI_Binding` rows, permission sets `Event_Ingestion_Processor` and `Event_Ingestion_Viewer`, `EventIngestionTestFactory`. ADRs 0002 and 0003.
3. `feat/dispatch`: `IMessageHandler`, `InboundMessage`, `HandlerResult`, `CompositeMessageHandler`, `Message_Route__mdt`, `MessageRoutesSelector`, `MessageRouter`, `MessageDispatcher`. ADRs 0004 and 0005.
4. `feat/finalizer-recovery`: `MessageProcessorJob`, `MessageProcessorFinalizer`, `RetrySchedule`, `Ingestion_Setting__mdt`, `MessageProcessing.enqueue`. ADR 0006.
5. `feat/event-intake`: `Inbound_Message__e`, its trigger and `InboundMessageEventHandler`, the `Event_Ingestion_Publisher` permission set, the Automated Process assignment script. ADR 0007.
6. `feat/claim-check`: `IPayloadResolver`, `ContentVersionPayloadResolver`, the claim path in `MessageStore` and `MessageDispatcher`, a size cap. ADR 0008.
7. `feat/stall-detection`: `StallDetector`, `StallSweeperSchedulable`, alert through `IAlertSink`, the scheduling script. ADR 0009.
8. `feat/example-and-docs`: unpackaged `example/` (`OrderStatusChangedHandler` upserting `Order` by `OrderReferenceNumber`, a second handler so one route is a Composite, route rows), `IngestionEndToEndTest`, the full README, the case study and the `## 1.0.0` changelog section.
9. `docs/release-1.0.0`: after the owner approves the tag and promotes, the `04t` alias, README install and handoff.

## What C's first PRs prove for E's template

- **PR 1:** no test classes, so no `apex-test-results` artifact. The `main` run's `reuse` job should report `reuse=true` with empty coverage and spend no second org.
- **PR 2: proven 2026-11-15.** The run listed only C's 4 `*Test` classes (none of A's). The gate filtered the coverage JSON, which also has rows for A's classes, down to C's 7 classes. `package-coverage.txt` is that one number (100); with A's rows counted it would have been 59%.
- **Tag `v1.0.0`:** `changelog-section.sh` finds `## 1.0.0`, and both release jobs add it to the notes. The failure path is checked locally (`bash scripts/changelog-section.sh 9.9.9` exits non-zero), not with a throwaway tag.

## Probes for the dev org, before spending CI orgs

1. **Proven 2026-11-13 in `aei-dev`:** an `allOrNone=false` insert (system or user mode) gives `DUPLICATE_VALUE` only to the repeated row. The first copy in a list succeeds and the rest of the batch is unaffected, so the in-memory dedupe is optional. A stored key also gives `DUPLICATE_VALUE`; the key is case-sensitive; `getFields()` is empty, so classify on the status code. Defaults: `Received`, attempts 0.
2. User-mode DML from the Platform Event trigger fails for the Automated Process user without `Event_Ingestion_Processor` and passes with it.
3. Finalizer: its fields keep the claimed Ids after a `LimitException`; it can do DML after the job rolls back; it can enqueue one job; the `AsyncOptions` delay and stack depth; how it behaves at `stopTest`.
4. Whether a test can trigger a `LimitException` deterministically, or whether tests use a fake `FinalizerContext` only.
5. **Proven 2026-11-15 in `aei-dev`:** apex-core-lib (installed 04t, no namespace) resolves C's unpackaged `public` `MessageStore` through one-argument `Type.forName`, the same path `MessageRouter` uses for `example/`. An unknown name returns `null`; names match case-insensitively; inner classes resolve. C running as a 04t itself is checked in PR 8's install smoke test.
   5b. **Proven 2026-11-15:** while a savepoint is active, every callout throws "All active Savepoints must be released before making callouts", even after a rollback. `Database.releaseSavepoint` lifts it, also after DML and a rollback. `HttpCalloutMock` enforces the same rule in tests.
6. Two jobs never claim the same rows with `FOR UPDATE`.
7. Claim Check: whether the Automated Process user can read a `ContentVersion` another user uploaded (sharing through `ContentDocumentLink`), and the heap cost of `VersionData`.
8. A skip-validation package build (from the 500/day budget) before tagging.

## Open decisions

| Decision                                         | Options                                                                                                                             | Leaning                                                 | Needed by |
| ------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------- | --------- |
| How a claimed file is shared with the processor  | `ContentDocumentLink` to the message record, a library, or the producer shares it                                                   | Decide after probe 7                                    | PR 6      |
| Inline payload cut-over size                     | The 131,072-character field limit, or a lower threshold                                                                             | The field limit: anything larger must be claimed        | PR 6      |
| Stall sweeper access to messages it does not own | Modify All (needs Delete too), run the sweeper as the Automated Process user, or a documented `without sharing` selector and update | Decide in PR 7; PR 2 ships Processor without Modify All | PR 7      |

## Notes for the next session

- **PR 3 `feat/dispatch`** is in review. After it merges, put the handoff update as the first commit on `feat/finalizer-recovery`.
- **PR 4 must:** truncate joined handler errors to `Last_Error__c` (32,768 characters; the review's one Medium finding); turn `Map<Id, HandlerResult>` into status changes (`SUCCESS` → Processed with `Processed_At__c`, `RETRYABLE` → Failed with backoff or Dead at the maximum, `FATAL` → Dead); run probes 3, 4 and 6 first. The claim DML happens before dispatch, so the no-callout rule in ADR 0004 holds either way.
- Dev Hub on 2026-11-15, after PR 2: 2 of 3 active slots free (`aei-dev` holds one; the CI org is deleted), 5/6 daily scratch orgs, 6/6 package creates.
- `aei-dev` (expires around 2026-12-13) is in sync with `main`: the store, its permission sets, the bindings and the tests are deployed, and Processor is assigned to the default user.
- To check CI's gate before spending an org, a local replay of the test step (the same `--class-names` and own-class filter) worked well. `npm run org:test` covers the test run itself.
- Run tests in the dev org with `npm run org:test`, which uses the same `--class-names` scope as CI.
