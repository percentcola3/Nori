# Nori application boundaries

Nori targets macOS 13 and later. Its SwiftUI presentation still uses `ObservableObject` and `@Published`; the service boundaries below do not require newer observation APIs. The window layout and glass conventions remain defined by `AGENTS.md`.

## Ownership and responsibilities

| Layer | Responsibility | Main files |
| --- | --- | --- |
| Presentation | Published UI state, confirmation, navigation, queue ownership and result projection | `AppState.swift`, `AppState+Cleanup`, `+Analysis`, `+Processes`, `+AutoCleanup`, `+Development` |
| Session state | Cancellation controls, generations, retries and sampling bookkeeping for one domain; these do not publish UI changes themselves | Domain runtime state types beside their `AppState` extensions |
| Software workflows | Bounded version-check scheduling; execution of an already-confirmed uninstall request | `SoftwareUpdateChecking.swift`, `UninstallWorkflow.swift` |
| Application discovery | Read-only application roots, physical identities and bundle metadata; optional bounded allocated-byte measurement | `ApplicationInventoryService.swift`, `ApplicationSizeMeasurer.swift` |
| Uninstall planning | Read-only residual ownership, sibling protection, cache/data classification and cask lookup | `UninstallPlanningService.swift` |
| CLI inventory | Provider discovery, reconciliation, optional version/size enrichment and independent failure results | `CommandLineToolInventory.swift`, `CLIInstalledToolDiscovery.swift`, `CommandLineTool.swift` |
| CLI command planning | Fixed argv, manager binding, installation environment and root verification shared by update/uninstall | `CLIManagedCommand.swift` |
| Command I/O | Bounded subprocess lifetime and capped output collection for metadata queries and uninstall commands | `CLICommandRunner.swift` |
| Execution | CLI uninstall and async software-update execution | `CLIUninstallService.swift`, `SoftwareUpdateExecution.swift` |
| Audited cleanup engine | Live identity/access/occupancy revalidation and the existing deletion funnel | `NativeCore.swift`, `DeletionPlan.swift` |

`AppState` remains the composition root and presentation facade. Its domain extensions organize actions without widening existing `private(set)` inventory/queue setters. Moving a function between files alone does not change its responsibility: workflows with independent side effects are separate services, while UI publication remains on the main actor.

## SOLID in these boundaries

- **Single responsibility:** filesystem discovery, uninstall preview policy, command planning, execution and UI publication have separate owners. Inventory discovery never starts a mutation or recursively measures every package while collecting metadata.
- **Open/closed:** a CLI `DiscoveryProvider` is registered through inventory dependencies; the orchestration loop does not need a new branch for each discovery source. Package-manager-specific mutation rules remain explicit and reviewed in the command planner.
- **Liskov substitution:** injected inventory, size, metadata-check and uninstall implementations must honor the same observable contracts. Tests use replacements to verify source failures preserve other records, concurrency remains bounded, and an elevation result cannot claim success without removing the captured application.
- **Interface segregation:** `ApplicationSizeMeasuring`, `ApplicationInventoryReading`, `SoftwareUpdateChecking` and `UninstallExecuting` expose their own small operations. A metadata checker does not receive installation or shutdown APIs.
- **Dependency inversion:** presentation depends on checker/executor interfaces. Read-only uninstall planning receives inventory, sizing and access/command-query dependencies. The composition root supplies the existing production implementations; tests supply deterministic replacements.

These are practical seams for the current product, rather than a requirement to create a protocol for every helper or service.

## Execution contracts

A confirmed uninstall keeps the original queue request and selected data paths. The workflow stops scoped processes, obtains a fresh plan, stops any respawned scoped process, intersects selected data with that plan, and performs the appropriate administrator/native route. Failed elevation does not clean residual data. `NativeCore` remains responsible for final live identity and deletion checks.

Update and uninstall commands share the same installation-root context. Root probes must match before a mutation command runs. Different prefixes containing the same package remain distinct installations. Unknown or incomplete optional measurements never remove a discovered record.

## Verification and extension

Use `script/test_software_workflows.sh` for dependency and workflow contracts, `test_cli_tools.sh` and `test_software_update_execution.sh` for provider and command contracts, and `test_uninstall_residue.sh` for sibling/identity/residual policy. `script/test.sh` runs the existing broader safety, lifecycle and type checks. Its source contracts follow the domain files instead of requiring every action to remain in the main state file.

New native-core helper files must be included in the explicit fixture compiler source lists. Production builds already compile `SimpleMole/*.swift`, `Services/*.swift` and `Views/*.swift` from a frozen source copy. After a completed requirement, run `script/install_update.sh` as prescribed by `AGENTS.md`.
