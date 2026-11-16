# ADR 0008: Carry large payloads by Claim Check on a producer-uploaded ContentVersion

- **Status:** Accepted
- **Date:** 2026-11-16
- **Deciders:** Chad Countryman

## Context

`Payload__c` on `Inbound_Message__c` and `Inbound_Message_Event__e` holds at most 131,072 characters (ADR 0002, ADR 0007). Some messages are larger, for example an order with thousands of lines. The EIP **Claim Check** pattern fits: the producer stores the large payload elsewhere and sends a reference (the claim), and the receiver loads the payload only when it needs it.

On Salesforce, "elsewhere" is a file: a `ContentVersion`. The questions are who may point a message at a file, how the processor reads it, how large it may be, and how many large payloads one job can hold.

A probe in a Developer Edition scratch org (2026-11-16, probe 7), run as the Automated Process user from a Platform Event trigger and from the Queueable it enqueued, established:

1. **The processor can read every file.** That user read the `ContentVersion` and its `VersionData` in user mode for a file another user uploaded with no `ContentDocumentLink`, for one linked to a record, and for one shared with it directly. `with sharing` or `without sharing` made no difference. It could also insert a `ContentDocumentLink` for a file it didn't own.
2. **Query versions, not documents.** A user-mode `ContentDocument` query returned no rows for those files unless they were shared with that user directly.
3. **Heap.** `VersionData` costs about its size in heap (1,048,705 bytes per MiB). `Blob.toString()` adds the same again for ASCII text, so a file costs about twice its size while it is converted, and its size once the blob is released.
4. **Limits as reported.** `Limits.getLimitHeapSize()` returned 10,000,000 in the trigger and 25,000,000 in the job, above the documented 6 MB and 12 MB. The design keeps to the documented limits.

A unit test also showed that `Blob.toString()` throws `StringException` on data that isn't valid UTF-8.

## Options

### Who may point a message at a file

1. **Only the user who uploaded that version: `ContentVersion.CreatedById` must equal the message's producer** (chosen). For intake the producer is the event's publisher (`CreatedById` on the event); for a direct `IMessageStore.append` it is the running user, or the producer passed in. For: probe 1 means visibility proves nothing when the Automated Process user looks, so without this check anyone allowed to publish could have the processor read any file in the org (an HR document, say) and pass it to a handler: a **confused deputy**. Against: a producer can't claim a file a colleague uploaded; it must upload its own copy.
2. **Trust visibility (the version is readable by whoever stores it).** Against: intake stores as the Automated Process user, which sees everything (probe 1).
3. **Check that the producer can read the file.** For: lets producers share files. Against: Apex can't ask "can user X read file Y" without running as X, and the processor never runs as the publisher.

### How the processor reads the file

1. **No sharing step; the processor reads the version in user mode** (chosen). Probe 1 shows the Automated Process user needs no link. A direct producer that stores and processes as itself owns the file, so it can read it too. For: no extra DML, nothing to clean up. Against: an operator holding `Event_Ingestion_Viewer` sees the version Id on the message, not a file attached to it.
2. **Link the file to the message record with a `ContentDocumentLink` at intake.** For: operators see the file on the record. Against: one more DML statement and failure mode per intake run, for no processing benefit. It can be added later without changing the contract.
3. **A shared library.** Against: setup steps in every subscriber org, and libraries widen access instead of narrowing it.

### What the claim names

1. **A `ContentVersion` Id (`068…`)** (chosen). For: a version is immutable, so the content a message names can't change after it is sent, which keeps redelivery idempotent. Against: none found.
2. **A `ContentDocument` Id.** Against: a new upload would silently change what a stored message means, and documents aren't visible in user mode (probe 2).

### The inline cut-over

1. **The field limit: anything up to 131,072 characters goes inline; anything larger must be claimed. A message with both is rejected** (chosen). For: one rule, enforced by the platform's field length, and no ambiguity about which payload a handler gets. Against: producers near the limit must measure.
2. **A lower threshold in settings.** Against: two limits to explain, and the store would have to move payloads itself.

### How large a file may be, and how much one job may hold

1. **A per-message cap, `Claim_Max_Bytes__c` (default 3,000,000), checked when the message is stored; and a per-job budget, `Dispatch_Payload_Budget__c` (default 4,000,000 characters and bytes)** (chosen). The store records `Payload_Size__c`: the inline payload's characters or the file's bytes. The processor job claims as before, then dispatches in claim order only the messages that fit the budget together, always at least the first. The rest keep their state, with no attempt counted, and the Finalizer continues at once as after a full batch. For: by probe 3, 4,000,000 of payload peaks near 8 MB, inside the documented 12 MB with room for handlers. It also closes a gap that predates this ADR: 200 full inline payloads (26 million characters) never fitted one job. Against: a burst of large payloads takes more jobs.
2. **Resolve one file per message as handlers ask for it.** Against: a query per message, which breaks the bulk rule and the 100-SOQL limit.
3. **Shrink the claim's `LIMIT` when claims are present.** Against: the claim query can't know payload sizes without reading them, and a lower count still doesn't bound bytes.

The resolver also releases each file's blob once it has converted it, so the peak is the text plus one file, not twice the total.

### A claim that can't be loaded at dispatch

1. **`FATAL`, so the message goes `Dead`** (chosen). A deleted, unreadable or non-UTF-8 file can't heal by retrying. An operator can replay the message once the file is restored. The handler never sees the message.
2. **`RETRYABLE`.** Against: it burns every attempt and then dies anyway.

## Decision

- **Fields:** `Payload_Ref__c` (Text 18) on `Inbound_Message__c` and `Inbound_Message_Event__e`, and `Payload_Size__c` (set by the store) on `Inbound_Message__c`.
- **Resolver:** `IPayloadResolver`, bound by `DI_Binding.Payload_Resolver` to `ContentVersionPayloadResolver`, reads versions through `IContentVersionsSelector` in user mode.
  - `inspect(Set<String>)` returns a `PayloadClaim` per ref (version Id, size, uploader, or why it can't be used). It loads no file data.
  - `resolve(Set<String>)` returns the text per ref and leaves out any file that can't be loaded.
- **Store:** `MessageClaims` applies the rules before the insert, with one `inspect` per append. `PayloadClaim.problemFor(producerId)` is the uploader check. `IMessageStore` gained `append(messages, producerIds)`, and intake passes each event's publisher.
- **Dispatch:** `MessageDispatcher` resolves every claim in its batch in one call and hands handlers the text through `InboundMessage.getPayload()`. `getPayloadRef()` shows the claim.
- **Job:** `MessageProcessorJob` dispatches within `Dispatch_Payload_Budget__c`.

Changed after the API was approved, before tests: the approved `verify(Map<String, Id> producerIdByRef)` became `inspect(Set<String>)` returning `PayloadClaim`. A map keyed by ref can't express two messages that carry the same ref from different producers, so the producer comparison moved to the caller.

## Consequences

- **Limits:**
  - Append: one more SOQL when any message is claimed.
  - Dispatch: one more SOQL when any message is claimed.
  - Heap: about twice the largest file, plus the text of every payload the job takes.
  - Bulk-tested at 200 claims.
- **Producer contract:** upload the file as the same user that publishes or appends; send UTF-8 text; send the version Id; don't send `Payload__c` as well.
- **Trust boundary:** the uploader check guards against publishers, which can be external API users. `append(messages, producerIds)` trusts the Apex code that calls it to name the real producer, as intake does. Apex code that wanted another user's file could already read it in system mode, so the check adds nothing against it.
- **Retention:** the package never deletes a claimed file, and deleting one before dispatch sends its message to `Dead`. Retention of files and messages stays with the subscriber org (ADR 0002).
- **Revisit:**
  - If a release changes the Automated Process user's file access. `ClaimCheckIntegrationTest` publishes and delivers real events, so it would show the change.
  - If operators need the file on the message record: option 2 above.
- **Rollback:** the fields and settings are additive. Producers that never set `Payload_Ref__c` see no change, except that a job now takes fewer large inline payloads at once.
