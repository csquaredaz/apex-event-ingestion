# ADR 0004: Dispatch to bulk Command handlers routed by Custom Metadata, combined as a Composite

- **Status:** Accepted
- **Date:** 2026-11-15
- **Deciders:** Chad Countryman

## Context

Stored messages (ADR 0002) have to reach the code that acts on them. Message types are open-ended: the package ships none, and each subscriber org adds its own (the `example/` folder adds `order.status_changed`). One type can need more than one action, for example updating the order and notifying shipping. Messages arrive in bulk, up to 200 per job, and handlers run inside the processor job's transaction (ADR 0006), next to the other handlers of that job.

Probes in a scratch org (2026-11-15) established:

1. With no namespace, packaged code resolves a `public` class outside the package through one-argument `Type.forName`. apex-core-lib, installed as a package, resolves this repo's unpackaged `MessageStore` that way. An unknown name returns `null`, and names match case-insensitively.
2. While a savepoint is active, every callout throws `CalloutException: All active Savepoints must be released before making callouts`, even after rolling back to it. `Database.releaseSavepoint` lifts the block, including after DML and a rollback.

## Options

### Handler shape

1. **A bulk Command, `IMessageHandler.handle(List<InboundMessage>)`, returning one `HandlerResult` per message** (chosen). For: one call per type per job keeps handlers bulk-safe; three outcomes (`SUCCESS`, `RETRYABLE`, `FATAL`) let a handler say whether retrying can help. Against: handlers have to build a result for every message.
2. **One call per message.** For: simpler handlers. Against: a handler with one query per message hits the 100-SOQL limit at 101 messages.
3. **Handlers that throw on failure.** Against: one bad message fails the whole call, and nothing tells retryable failures from permanent ones.

Handlers receive `InboundMessage`, an immutable view, not the `Inbound_Message__c` row, so they can't change lifecycle fields and the store can change shape without breaking them. Results are matched by message Id, not position, so a handler can return them in any order.

### Routing

1. **`Message_Route__mdt` rows map a type to a handler class, resolved with `Type.forName`** (chosen). For: subscribers add types by deploying metadata, with no change to this package. `getAll()` reads the metadata cache: no SOQL and no object permission for the Automated Process user. Against: a class name is only checked at run time, so a typo shows up as failing messages rather than a failed deploy.
2. **A `DI_Binding__mdt` row per type.** Against: DI binds one implementation per interface; it has no notion of several handlers in run order.
3. **An Apex map in a registry class.** Against: subscribers would have to change this package's code.

### Several handlers for one type

1. **Composite: `CompositeMessageHandler` runs every route in `Order__c` order, and the most severe result per message wins** (chosen). For: callers see one handler either way, and each handler stays a small Command. Against: a message that one handler fails is retried through all of them.
2. **One route per type, with the handler fanning out itself.** Against: every subscriber reinvents the fan-out and its error merging.
3. **Chain of Responsibility, stopping at the first failure.** Against: independent actions would wait on each other, and a failure in the first would hide whether the rest work.

### Isolating a handler that throws

1. **Decorator: `GuardedMessageHandler` sets a savepoint, rolls back and releases it when the handler throws, and marks every message in the call `RETRYABLE`** (chosen). It also fills in a `RETRYABLE` result for any message the handler didn't answer for, and drops results for Ids it wasn't given. For: one handler's half-finished writes never persist, and the other handlers still run. Against: each call counts a savepoint as a DML statement, and handlers can't make synchronous callouts while it is active (probe 2).
2. **No savepoint; let the exception end the job.** Against: one bad handler fails every message in the job, of every type.
3. **A per-route flag that skips the savepoint for handlers that make callouts.** Against: such a handler's partial writes could persist, and the job's own claim DML (ADR 0006) already blocks callouts in that transaction.

A rollback undoes DML only. It can't recall a Publish Immediately event or a job the handler already enqueued.

### Configuration errors

- **No active route for a type → `FATAL`.** Nobody handles the type. The message goes to `Dead` (ADR 0006), where it can be replayed once a route exists.
- **A route whose class is missing, not public, not an `IMessageHandler`, or whose constructor throws → `RETRYABLE`.** Someone meant to handle the type, so a fix deployed within the retry window heals it without a replay.

## Decision

`MessageDispatcher` loads the messages with their payloads in one user-mode query, groups them by type, and asks `MessageRouter` for a handler per type. The router reads `Message_Route__mdt` through `IMessageRoutesSelector`, wraps each route's handler in `GuardedMessageHandler`, and combines several routes in `CompositeMessageHandler`. The dispatcher returns one `HandlerResult` per message, keyed by Id, and writes no status: the processor job (ADR 0006) turns results into lifecycle changes.

## Consequences

- **Handlers must be idempotent.** Delivery is at least once per handler: a retried message reaches handlers that already succeeded for it.
- **Handlers make no synchronous callouts.** They enqueue a Queueable for them, for example with apex-core-lib's `CalloutClient`.
- **Errors are joined, not truncated.** The status writer in PR 4 truncates them to `Last_Error__c`'s 32,768 characters.
- **Uncatchable errors** (`LimitException`) end the transaction past the guard. Finalizer recovery (ADR 0006) handles them.
- **Limits per dispatch:** 1 SOQL, no SOQL for routes, and one handler call plus one savepoint per route per message type. Bulk-tested at 200.
- **Rollback posture:** deactivating a route (`Is_Active__c = false`) stops its handler without a code deploy. Its messages then go `FATAL` if it was the type's only route.
