# Handoff: apex-event-ingestion

Last updated: 2026-11-13

## Done

- Repository scaffolded by hand from `apex-standards:sf-repo-scaffold` (the skill sets `disable-model-invocation`), using the template on `claude-code-salesforce-skills` `main` at `0d9badd`.
- Depends on `apex-core-lib@1.1.0-1` (`04tak000000u3MbAAI`). First feature folder: `force-app/store/`.
- ADR 0001: an unlocked package with no namespace on top of A.
- Design approved 2026-11-13 (below).

## Approved design

| ADR  | Decision                | Choice                                                                                                                                                                                                                                                                                                                                                                              |
| ---- | ----------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 0001 | Distribution            | Own unlocked package, no namespace, on A `1.1.0-1`. Logs through `ILogger` and alerts through `IAlertSink`; never depends on B                                                                                                                                                                                                                                                      |
| 0002 | Message store           | Custom object `Inbound_Message__c`. Status `Received → Processing → Processed`, or `Failed` and then `Dead`. Fields: `Idempotency_Key__c`, `Message_Type__c`, `Source__c`, `External_Message_Id__c`, `Payload__c`, `Payload_Ref__c`, `Status__c`, `Attempts__c`, `Next_Attempt_At__c`, `Locked_Until__c`, `Last_Error__c`, `Correlation_Id__c`, `Occurred_At__c`, `Processed_At__c` |
| 0003 | Idempotency key         | The producer's key, `Source__c + ':' + External_Message_Id__c`, in a unique, case-sensitive external Id. Insert with `allOrNone=false`; `DUPLICATE_VALUE` means already received. Repeats in one batch are removed in memory first. No key means rejected                                                                                                                           |
| 0004 | Dispatch                | Bulk Command `IMessageHandler.handle(List<InboundMessage>)` returning one `HandlerResult` per message (success, retryable, fatal). `Message_Route__mdt` maps a type to handler classes (`Type.forName`). More than one route becomes a `CompositeMessageHandler`; the worst result wins                                                                                             |
| 0005 | Ordering                | No ordering guarantee. Handlers guard against stale updates with `Occurred_At__c`                                                                                                                                                                                                                                                                                                   |
| 0006 | Finalizer recovery      | `MessageProcessorJob` claims a batch `FOR UPDATE` and records the Ids in `MessageProcessorFinalizer`. On an unhandled exception the Finalizer marks unfinished messages `Failed` with exponential backoff, or `Dead` at the maximum attempts, alerts, and enqueues the next job once. Limits in `Ingestion_Setting__mdt`                                                            |
| 0007 | Intake                  | High-volume Platform Event `Inbound_Message__e` with a trigger, `RetryableException` and resume checkpoints. The Automated Process user gets `Event_Ingestion_Processor` through a setup script, so DML stays in user mode. `PlatformEventSubscriberConfig` documented as the production alternative                                                                                |
| 0008 | Claim Check (built now) | A payload over the inline limit is uploaded by the producer as a `ContentVersion`. The event carries the claim (`Payload_Ref__c`), and `IPayloadResolver` loads it at dispatch, within a per-message size cap that fits the async heap                                                                                                                                              |
| 0009 | Stall detection         | Scheduled `StallSweeper` (four schedules for a 15-minute sweep, set up as a documented step). Resets expired `Processing` locks, re-enqueues old `Received` messages that have no job, and alerts                                                                                                                                                                                   |

## Next: PR plan (every PR targets `main`, none stacked)

1. `chore/scaffold` (this PR): template, dependency, ADR 0001, this handoff. No tests, on purpose.
2. `feat/message-store`: `Inbound_Message__c`, `IdempotencyKey`, `IMessageStore`, `MessageStore`, `AppendResult`, `InboundMessagesSelector`, `MessageStatuses`, permission sets `Event_Ingestion_Processor` and `Event_Ingestion_Viewer`, `EventIngestionTestFactory`. ADRs 0002 and 0003.
3. `feat/dispatch`: `IMessageHandler`, `InboundMessage`, `HandlerResult`, `CompositeMessageHandler`, `Message_Route__mdt`, `MessageRoutesSelector`, `MessageRouter`, `MessageDispatcher`. ADRs 0004 and 0005.
4. `feat/finalizer-recovery`: `MessageProcessorJob`, `MessageProcessorFinalizer`, `RetrySchedule`, `Ingestion_Setting__mdt`, `MessageProcessing.enqueue`. ADR 0006.
5. `feat/event-intake`: `Inbound_Message__e`, its trigger and `InboundMessageEventHandler`, the `Event_Ingestion_Publisher` permission set, the Automated Process assignment script. ADR 0007.
6. `feat/claim-check`: `IPayloadResolver`, `ContentVersionPayloadResolver`, the claim path in `MessageStore` and `MessageDispatcher`, a size cap. ADR 0008.
7. `feat/stall-detection`: `StallDetector`, `StallSweeperSchedulable`, alert through `IAlertSink`, the scheduling script. ADR 0009.
8. `feat/example-and-docs`: unpackaged `example/` (`OrderStatusChangedHandler` upserting `Order` by `OrderReferenceNumber`, a second handler so one route is a Composite, route rows), `IngestionEndToEndTest`, the full README, the case study and the `## 1.0.0` changelog section.
9. `docs/release-1.0.0`: after the owner approves the tag and promotes, the `04t` alias, README install and handoff.

## What C's first PRs prove for E's template

- **PR 1:** no test classes, so no `apex-test-results` artifact. The `main` run's `reuse` job should report `reuse=true` with empty coverage and spend no second org.
- **PR 2:** the run lists only C's `*Test` classes (`--class-names`, none of A's), and `package-coverage.txt` lists only C's classes.
- **Tag `v1.0.0`:** `changelog-section.sh` finds `## 1.0.0`, and both release jobs add it to the notes. The failure path is checked locally (`bash scripts/changelog-section.sh 9.9.9` exits non-zero), not with a throwaway tag.

## Probes for the dev org, before spending CI orgs

1. **Proven 2026-11-13 in `aei-dev`:** an `allOrNone=false` insert (system or user mode) gives `DUPLICATE_VALUE` only to the repeated row. The first copy in a list succeeds and the rest of the batch is unaffected, so the in-memory dedupe is optional. A stored key also gives `DUPLICATE_VALUE`; the key is case-sensitive; `getFields()` is empty, so classify on the status code. Defaults: `Received`, attempts 0.
2. User-mode DML from the Platform Event trigger fails for the Automated Process user without `Event_Ingestion_Processor` and passes with it.
3. Finalizer: its fields keep the claimed Ids after a `LimitException`; it can do DML after the job rolls back; it can enqueue one job; the `AsyncOptions` delay and stack depth; how it behaves at `stopTest`.
4. Whether a test can trigger a `LimitException` deterministically, or whether tests use a fake `FinalizerContext` only.
5. `Type.forName` resolves a `public` handler in unpackaged `example/` from the package.
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

- Dev Hub on 2026-11-13: 6/6 daily scratch orgs, 6/6 package creates. `acl-dev` and `apl-dev` held two of the three active slots; the owner is deleting both so a dev org (`aei-dev`, 30 days) and a CI org fit.
- Run tests in the dev org with `npm run org:test`, which uses the same `--class-names` scope as CI.
