# Case study: apex-event-ingestion

<!--
Reused verbatim on the portfolio site, so keep it self-contained: no relative links, no employer
or client names, and no production metrics. "Informed by production experience at scale" is the
most specific claim allowed.
-->

**Problem.** Integrations deliver messages at least once, and Salesforce async work can die on an uncatchable governor limit halfway through a batch. Handling each event in its trigger processes duplicates twice, loses whatever a failed job had picked up, and leaves no record of what arrived or why it failed.

**Approach.** Every message lands once in a message store, keyed by the producer's idempotency key in a unique field, through a partial-success insert that lets the database settle races. A Queueable claims a batch with a row lock and dispatches it to bulk **Command** handlers routed by Custom Metadata, combined as a **Composite** and each wrapped in a savepoint **Decorator**; its **Transaction Finalizer** recovers the batch with exponential backoff when the job dies and decides the next run. Intake is a high-volume Platform Event, large payloads travel by **Claim Check**, and a scheduled sweeper wakes processing for late retries and alerts on stalls, all on an FFLIB-style core library (Service Locator, Selector, Unit of Work).

**Trade-offs.** The row lock is the claim, so there's no stored "processing" status and nothing to reset after a crash; the cost is that batches effectively run one at a time, a choice the ADR records along with when to revisit it. There's no ordering guarantee: handlers skip stale changes by occurrence time instead of serialising per record, so one poison message never blocks the rest. Several platform facts the design depends on were proven with throwaway probes in a scratch org before any code relied on them. One of them changed the design: the Automated Process user, which stores every message, can read every file in the org. Without the check that only a file's uploader may claim it, any publisher could have had the processor read any file and hand it to a handler (a confused deputy).

**Result.** An unlocked package with no namespace, plus an unpackaged example integration that updates orders and records shipments through a two-handler Composite. 238 Apex tests, among them Stub API unit tests, real event deliveries run as least-privilege users, 200-record bulk cases and an end-to-end test with nothing mocked, cover 100% of the repo's own classes. Mutation checks confirmed the tests fail when key behaviour is removed. CI on GitHub Actions runs Prettier, Code Analyzer (zero High, zero Moderate) and gitleaks, then deploys to a fresh scratch org per PR, and reuses the PR's result on merge. Nine ADRs record each decision with the options rejected. The design is informed by production experience at scale.

**Stack.** Apex · Platform Events · Transaction Finalizers · Custom Metadata · Salesforce DX · GitHub Actions · Claude Code (`apex-standards`)
