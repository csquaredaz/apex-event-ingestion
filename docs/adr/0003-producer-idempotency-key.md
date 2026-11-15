# ADR 0003: Deduplicate on the producer's key with a unique index and a partial-success insert

- **Status:** Accepted
- **Date:** 2026-11-15
- **Deciders:** Chad Countryman

## Context

The same message can be delivered more than once: the producer retries, Platform Events redeliver, and two transactions can receive copies at the same moment. The store (ADR 0002) must store each message once, tell the caller which messages were new, which were already stored and which it refused, and never let one bad message fail the others.

Probes in a scratch org (2026-11-13 and 2026-11-15) established:

1. A `Database.insert(rows, false, …)` against a unique field gives `DUPLICATE_VALUE` only to the repeated row: an already stored key, or the second copy within the same list. The first copy in a list succeeds and the rest of the batch is unaffected. This holds in system and user mode.
2. The key field is case-sensitive, and `Database.Error.getFields()` is empty for `DUPLICATE_VALUE`, so duplicates are classified by status code.
3. A user without Create on the object gets no exception from a partial-success insert: every row fails with `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY`.
4. `Database.SaveResult` can be built with `JSON.deserialize`, so unit tests can fake insert results.

## Options

### What the key is

1. **The producer's key, `Source__c + ':' + External_Message_Id__c`, in a unique, case-sensitive external Id** (chosen). For: the producer already knows when a message is a retry, and the key is stable across retries even when the payload's formatting changes. Against: a producer that reuses message Ids is deduplicated wrongly. The contract says Ids are unique per source.
2. **A hash of the payload.** For: works without producer cooperation. Against: two different messages with the same content (two identical status updates) would be merged, and a retry with reformatted JSON would not be.

`IdempotencyKey.of` rejects a blank source or Id, and a source containing `:`, because `a:b` + `c` and `a` + `b:c` would build the same key. Keys are taken exactly as sent: not trimmed and not lower-cased. The field lengths (80 + 1 + 160) fit the key's 255 characters.

### How duplicates are found

1. **Insert with `allOrNone=false` and let the unique index decide** (chosen). For: correct when two transactions race, because the database, not a prior query, is the arbiter. One DML statement for the batch, and no SOQL unless there are duplicates. Against: a duplicate costs a failed row in the statement, which is harmless.
2. **Query the keys first, then insert the rest.** For: no failed rows. Against: two concurrent transactions both see "not stored" and both insert, so it still needs the unique index, and it always spends a query.
3. **Upsert on the key.** For: one statement. Against: a redelivery overwrites the stored row, losing the "already received" signal and possibly resetting a message mid-processing.

### Repeats within one batch

Approved first as "removed in memory first", then changed on 2026-11-15 after probe 1. The store leaves them to the database: the first copy wins and later copies get `DUPLICATE_VALUE`. In-memory removal would misclassify one case. If the first copy is rejected (for example, it has no message type) and a later copy is valid, removal in memory would report the valid copy as a duplicate of a message that was never stored. The database stores it instead.

Every duplicate, within the batch or across calls, gets the stored row's Id from one `selectByIdempotencyKeys` query. SOQL compares text case-insensitively, so the selector applies the case-sensitive match in Apex after the query.

### Where the DML runs

1. **A partial-success seam, `IPartialDml`, bound to `UserModePartialDml` (user mode)** (chosen). For: `MessageStore` stays unit-testable with a Stub API mock and fake save results; the adapter is two lines. Against: it is a documented exception to the repository rule that a Unit of Work owns DML.
2. **apex-core-lib's Unit of Work.** Against: `IUnitOfWork` and `IDml` are all-or-none by contract, so one bad message would fail the batch.
3. **`Database.insert` called directly in `MessageStore`.** For: one class fewer. Against: the classification logic could only be tested with real DML.

If another repo needs partial-success DML, `IPartialDml` is a candidate to move into apex-core-lib in a minor version.

### A user who can't create messages

1. **Check `isCreateable()` on the object and on the optional producer fields first, and throw `MessageStoreException`** (chosen). A user with object Create but no edit access to `Payload__c`, `Correlation_Id__c` or `Occurred_At__c` would otherwise have every row rejected by user-mode DML. For: a missing permission set is a setup error. Throwing lets the intake trigger (ADR 0007) retry the delivery once the permission set is assigned. Against: one describe call per append (deferred describe, no SOQL).
2. **Return every message as rejected.** Against: a rejected message is final by contract, so good messages would be dropped because of a configuration mistake.

## Decision

Key on `Source__c:External_Message_Id__c` in a unique, case-sensitive external Id. Insert with partial success through `IPartialDml`, in user mode. Classify each row:

- accepted when it saves;
- a duplicate on `DUPLICATE_VALUE`;
- rejected on any other error, or when it has no valid key.

Throw when the user can't create messages. `IMessageStore.append` returns one `AppendResult` per input, in input order.

## Consequences

- Retrying a delivery is always safe: duplicates come back as `DUPLICATE` with the stored row's Id when the caller can see it.
- Callers must handle three outcomes. A `REJECTED` result is final (the same message would be rejected again); a `MessageStoreException` is not.
- `DUPLICATE_VALUE` means "already stored" only while `Idempotency_Key__c` is the object's only unique field. Adding another unique field requires revisiting `MessageStore.isDuplicate`.
- Limits per append: 1 DML statement, plus 1 SOQL only when there are duplicates; bulk-tested at 200.
