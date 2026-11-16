# ADR 0005: Guarantee no ordering; handlers skip stale updates by occurrence time

- **Status:** Accepted
- **Date:** 2026-11-15
- **Deciders:** Chad Countryman

## Context

Messages about the same record can be processed in a different order from the one in which they happened:

- Producers retry, so an older message can arrive after a newer one.
- A message that fails is retried with backoff (ADR 0006), while later messages for the same record go through.
- Two processor jobs can run at the same time, each with its own batch.

If an order ships and then gets cancelled, applying the messages in the wrong order leaves it shipped. The store records `Occurred_At__c`, the producer's time for the event (ADR 0002).

## Options

1. **No ordering guarantee; handlers compare `Occurred_At__c` with what the target record already reflects** (chosen). For: there's no head-of-line blocking, so one failing message never stalls the others; jobs run in parallel; the rule lives where the record's meaning is known. Against: each handler that updates state has to store and compare a "last applied" time.
2. **Process each record's messages one at a time, in occurrence order** (a sequence per order number). For: handlers stay simple. Against: a message that fails or is held blocks everything after it for that record. It needs a partition key that every message type would have to define, and jobs would have to serialise per key, which Apex has no primitive for.
3. **Order the whole stream by `Occurred_At__c` in a single job.** Against: no parallelism, and one poison message stops all ingestion until it goes `Dead`.

## Decision

The dispatcher makes no promise about order, within a batch or across batches. `InboundMessage.isOlderThan(Datetime lastApplied)` gives handlers one stale-update rule: a message is stale only if it happened strictly before the change already on the record. Equal times are not stale, and if either time is unknown, nothing is proven, so the message is applied.

## Consequences

- A handler that updates state stores the time of the last change it applied, for example a `Status_Changed_At__c` on the target. It answers `SUCCESS` for a stale message (handled by doing nothing), not `FATAL`.
- Producers that leave out `Occurred_At__c` get last-writer-wins.
- Clock skew between producers can let a message that really is older win. A producer with its own sequence number can compare that instead; `isOlderThan` is a convenience, not a requirement.
- `OrderStatusChangedHandler` in `example/` shows the pattern on `Order`: it skips a message older than `Status_Changed_At__c`, keeps only the newest of several changes for one order in a batch, and leaves the time alone when a message has none. `IngestionEndToEndTest` proves a stale change leaves the order as it was.
- Revisit if a message type truly needs ordering, for example events that only make sense as a sequence. A per-key sequence would be its own ADR.
