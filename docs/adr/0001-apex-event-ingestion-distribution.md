# ADR 0001: Ship apex-event-ingestion as its own unlocked package on top of apex-core-lib

- **Status:** Accepted
- **Date:** 2026-11-13
- **Deciders:** Chad Countryman

## Context

`apex-core-lib` (A) provides the layers this repo (C) builds on: the DI container, the Unit of Work, selectors, the trigger framework and the ports `ILogger` and `IAlertSink`. C adds an inbound message store, Command and Composite dispatch, Finalizer recovery, Claim Check payloads and stall detection. Subscriber orgs plug their own message handlers into C.

Constraints:

1. C must install into an org that already has A, and pin A's version (`1.1.0-1`, `04tak000000u3MbAAI`). C uses `IUnitOfWork.registerUpsert`, which arrived in `1.1.0`.
2. C must not depend on `apex-platform-logging` (B). It logs only through `ILogger` and alerts only through `IAlertSink`. If B is installed, B's bindings route C's logs and alerts with no change to C.
3. The free Developer Edition Dev Hub allows 6 package version creates per rolling 24 hours, shared with A's and B's releases.

## Options

1. **Own unlocked package, no namespace, depending on `apex-core-lib@1.1.0-1`** (chosen). For: an org installs ingestion as one versioned unit and pins it, the same model as A and B (A's ADR 0001, B's ADR 0001). Handlers live in the subscriber org, outside the package, and are found through `Message_Route__mdt` rows, so a new message type needs no new version of C. Against: each release spends one of the 6 daily package version creates. Without a namespace, C's public surface is governed by ApexDoc `@group Public API`, not by the compiler.
2. **A source-only repo with no package.** For: no `release.yml`, no package builds. Against: consumers would have to copy source, and nothing pins the version they run.
3. **Add ingestion to A as another module.** For: one install. Against: every A consumer would carry the message store object, its Platform Event and its scheduled job. That reverses A's lean-core boundary (A's ADR 0002).

## Decision

Option 1: an unlocked package with no namespace that declares `apex-core-lib@1.1.0-1` as its dependency, because it keeps A lean, keeps C independent of B, and lets subscriber orgs extend C through configuration alone.

## Consequences

- `sfdx-project.json` pins A with `packageAliases` (`apex-core-lib@1.1.0-1` → `04tak000000u3MbAAI`). `scripts/org-setup.sh` installs it before the deploy, locally and in CI.
- CI runs only this repo's `*Test` classes (`--class-names`), because `RunLocalTests` would also run A's packaged tests, which assert A's defaults.
- Upgrading A is a PR in this repo that changes the alias, and the CI scratch org proves it.
- `release.yml` builds a beta on a `vX.Y.Z` tag. Promotion is manual and irreversible. A tag is pushed only with the owner's approval.
- **Amended 2026-11-16 (the example):** `example/` holds a sample subscriber-org integration (two handlers on `order.status_changed`, their route rows, an `Order` selector, `Shipment__c` and the `Event_Ingestion_Example` permission set). It is a second entry in `packageDirectories` with no `package` key, chosen over a separate CI deploy step (more workflow code, and `org:setup` wouldn't deploy it) and over leaving its classes out of the coverage gate (the code readers copy would be held to a lower bar). So:
  - `org:setup` deploys it and assigns its permission set; CI's `find` over the package directories runs its tests and counts its classes in the 90% gate, which the job summary labels "package + example".
  - `sf package version create` converts only the package's own directory (`packageObject.path` in `@salesforce/packaging`), and `--code-coverage` runs only the package's tests, which never depend on `example/`. The one thing it collects from every directory is profiles, so `example/` ships a permission set and **no profile**.
  - The example handlers run as the Automated Process user with no permission set; a live check in a scratch org (2026-11-16) showed that user updating `Order` and creating `Shipment__c` in user mode, as probe 2 showed for this package's objects (ADR 0007). `Event_Ingestion_Example` is for people and the least-privilege tests.
- Rollback: uninstall C. Messages still in the store are lost with the object, so export them first. A is unaffected.
- Revisit if C needs a capability only B provides (that would argue for a new port in A, not a dependency on B), or if build allocations stop being a constraint.
