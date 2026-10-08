# Nori

**A quieter, cleaner, more capable Mac.**

Nori is a lightweight, native enhancement tool for **macOS 13 Ventura and later**. It brings deeper cleanup, disk and file management, screenshots, clipboard history, and everyday utilities together in a calm Mac companion, built with native Swift + SwiftUI and a Dynamic Island-inspired interface.

![Nori overview](docs/screenshots/en/overview.png)

## What is this?

Nori started with a simple, persistent problem: I couldn't find a lightweight, frictionless clipboard tool for Mac. Inspired by [tw93/Mole](https://github.com/tw93/Mole), I realized small utilities can solve real daily friction in a big way. So I brought most of Mole CLI's cleanup power into Nori (thank you, tw93), added the tools developers reach for every day, and shaped it into a quiet, reliable companion.

Clean junk, check disk usage, recover copied items, capture and annotate screenshots, and keep an eye on system state—no complex panels required.

> **Early development — not yet stable.** Scanning, cleanup, permissions, and interface behavior may still have issues. Review selected paths before deleting, keep backups of important data, and report issues with your macOS version and steps to reproduce.

## Core capabilities at a glance

| Module | One-line value | Typical use case |
| --- | --- | --- |
| **Deep cleanup** | Identifies safe-to-rebuild caches, logs, and leftovers, grouped by risk | Xcode / npm / pip caches, AI Agent data, uninstall leftovers, Trash |
| **Developer workspace** | Manage runtimes, Shell, hosts, CLI, and ports in one place | Old Node versions, conflicting PATH entries, occupied ports |
| **AI Agent cleanup** | Separates caches, sessions, credentials, and memories to avoid mistakes | Claude Code / Cursor / Codex / Devin and more |
| **Disk & directory analysis** | Directory sizes, disk analysis, duplicates, similar images | Find large folders, clean duplicate copies |
| **Directory & file management** | A Finder-plus entry point: search, hidden files, path copy, common actions | Locate files quickly, batch operations, global filename search |
| **Clipboard history** | Automatically records text, links, files, and images | Recover a command, screenshot, or link you copied earlier |
| **Screenshot & annotate** | Region/ratio capture + annotation + background presets | One-click polished screenshots, redaction, Mac-style framing |
| **Dynamic Island system monitor** | CPU, memory, disk, network, and battery at a glance | See Mac status without opening the main window |
| **Automated cleanup** | Keep chosen folders tidy by age or size limit | Downloads / temp folders stay clean automatically |

---

## Deep cleanup

Nori goes beyond ordinary app-cache cleaners to find system data, developer build artifacts, and AI Agent data. Compared to typical cleanup tools, it often surfaces **tens of gigabytes more** reclaimable space because it also targets the caches generic tools miss. Actual results depend on what is actually on your disk.

Results are grouped by risk:

- **Recommended**: Rebuildable, inactive, and unoccupied caches, selected by default.
- **Review**: Items that may contain history or have recovery cost, left unselected by default.
- **Protected**: In-use, recently active, or credential-bearing items, shown with reasons they are kept.

Supported areas include:

- **System**: logs, diagnostic reports, Trash, device firmware, Messages preview caches.
- **Apps & browsers**: general caches, IM container caches, uninstall leftovers.
- **Developer**: Xcode DerivedData, npm / pnpm / Yarn / Bun / pip / uv / Cargo / Go / Gradle build and download caches.
- **AI Agents**: Claude Code, Cursor, Codex, Devin, Windsurf, Gemini CLI, and more—with sessions and memories reviewed separately.

Developer caches are recommended for cleanup after **7 consecutive days of inactivity**; identity and activity are rechecked before deletion.

![Disk cleanup](docs/screenshots/en/cleanup.png)

## Built for developer Macs

Package managers and build systems leave behind far more than ordinary app caches. Nori recognizes these environments and provides targeted cleanup:

| Environment | What Nori can clean or manage |
| --- | --- |
| **Xcode / SwiftPM / Carthage** | DerivedData, downloaded package/build caches, simulator caches, unavailable simulators; Archives stay protected. |
| **Node.js** | npm / pnpm / Yarn / Bun caches, store prune; old nvm versions can be removed, current/default versions protected. |
| **Frontend tooling** | Known caches for node-gyp, TypeScript, Electron, Turborepo, Vite, Webpack, ESLint, Prettier, etc. |
| **Python** | pip / uv / Poetry / Conda caches and official cleanup commands; Poetry virtual environments excluded from normal cleanup. |
| **Java / Android** | Gradle build caches, daemon logs, worker scratch data. |
| **Rust / Go** | Cargo registry downloads, Go build and module caches. |
| **Homebrew / Ruby** | Homebrew download caches, `brew cleanup`, RubyGems cleanup when installed. |
| **Docker** | Storage inventory; explicit builder/system pruning through Docker's own commands. |

The workspace also inventories runtimes, Shell, hosts, CLI, and PATH, and lets you free up listening ports in one click.

![Developer workspace](docs/screenshots/en/developers.png)

## AI Agent cleanup

AI tools leave more than caches behind. Nori groups each tool's local data so you can see what can be rebuilt, what contains history, and what needs care:

- **Storage breakdown**: installation bodies are separate from associated data; data is split into garbage and preserved usage. Agent and Software pages share these measurements, count shared paths once, and mark partial results. Selected data shows its own deletion amount.
- **Rebuildable caches**: old CLI versions, desktop/update/compile caches, selected by default.
- **Persistent data**: sessions, history, memories, worktrees, VM data and credentials require manual selection with risk notes. Other review items follow their displayed recommendations.
- **Shared resources**: Skills and MCP registrations distinguish unlinking from deleting shared files.

Uninstall a selected CLI or desktop installation directly on the Agent page. Its identified Agent data is offered separately after successful removal; running consumers require confirmation before closing. Leftovers from uninstalled Agents remain visible and unselected.

Supports Claude Code, Cursor, Codex, GitHub Copilot CLI, Gemini CLI, OpenCode, Grok CLI, Devin, Windsurf, Zed, Warp, and more.

![AI agent cleanup](docs/screenshots/en/agents.png)

## Disk & directory analysis

- **Directory sizes**: files and folders show actual allocated disk usage, computed and cached in the background, with refresh.
- **Disk analysis**: choose user directory, root, or any folder; drill down by size to find large files.
- **Duplicate files**: find duplicates by content hash, review each group, and move to Trash while keeping at least one copy.
- **Similar images**: identify visually similar images for side-by-side review and cleanup.

## Directory & file management

The Directory tab is a Finder-plus entry point:

- Always-visible clickable breadcrumb path with copy-to-clipboard.
- Hidden files shown by default, with per-folder display state remembered.
- Create, copy, cut, paste, rename, move to Trash, drag-and-drop, and open in Finder.
- Filter current folder or search the global Spotlight filename index; a local index adds dotfiles and other chosen directories.

## Clipboard history

Enable local clipboard history for **text, links, files, and images**:

- Filter by type (text / URL / image / file / all).
- Pin frequently used items, copy again, and adjust history limit.
- Clear unpinned entries in one action. File entries store paths, not duplicated files.

![Clipboard history](docs/screenshots/en/clipboard.png)

## Capture, compose, share

- **⌘⇧S** for interactive region/window capture; **⌘⇧R** for capture at a chosen aspect ratio.
- Annotate with shapes, arrows, freehand, text, and mosaic redaction.
- Presets for iPhone/iPad frames, social ratios, gradient backgrounds, padding, rounded corners, and Mac-style presentation.
- Export PNG or JPEG at 1× or 2×; remembers your last composition and export settings.

![Screenshot editor](docs/screenshots/en/screenshot.png)

## Your Mac, at a glance

The Dynamic Island-inspired panel shows:

- CPU, memory, disk capacity and I/O, network rates, and battery information.
- Resource-hungry apps, process list, listening ports, and app traffic.
- Can attempt a normal quit for eligible background apps; memory cleanup also releases Nori's own caches.

![Nori island](docs/screenshots/en/island.png)

## Keep folders tidy automatically

Create rules for any folder:

- **Keep the last X days** or **stay below a size limit**.
- Preview before enabling, or run manually on demand.
- Checks schedules hourly while Nori is running, with at least six hours between scans; protects sensitive paths and recent writes.

![Scheduled folder cleanup](docs/screenshots/en/automation.png)

## Install and update

Requires **macOS 13 Ventura or later**. Native Liquid Glass requires macOS 26 or later.

1. Open [GitHub Releases](https://github.com/percentcola3/Nori/releases/latest).
2. Download `Nori-arm64.dmg` for Apple silicon or `Nori-x86_64.dmg` for Intel.
3. Drag `Nori.app` into `/Applications`, replacing an older version after quitting it.
4. Open Nori and grant **Full Disk Access** for scanning/cleanup. **Screen Recording** is requested separately for screenshots.

Starting with version 1.0.1, Nori checks for updates through Sparkle. Public releases reuse the same pinned signing certificate and `com.nori.app` bundle identifier; this is a fixed self-signed identity, **not Apple notarization**. See the [release signing guide](docs/release-signing.md) for identity verification.

## Languages

English, 简体中文, 繁體中文, 日本語, 한국어, Deutsch, Français, Español, Português, Italiano, Русский, and Türkçe. Nori follows your system language by default; switch instantly in Settings.

## Build and contribute

A Mac and an Xcode toolchain with `swiftc` are required:

```bash
bash script/dev_identity.sh --ensure
bash script/build_and_run.sh
```

Run `bash script/test.sh` for the regression suite. Architecture, build options, safety policies, and maintenance notes are in the [development guide](docs/development.md).

Bug reports and focused contributions are welcome through [Issues](https://github.com/percentcola3/Nori/issues) and pull requests.

## License and acknowledgments

Nori is open source under the [GNU General Public License v3.0](LICENSE). Mole's vendored source retains its [GPL v3 license](vendor/mole/LICENSE); upstream attribution and packaged components are documented in [Third-party notices](THIRD_PARTY_NOTICES.md).

Thank you to [tw93/Mole](https://github.com/tw93/Mole) for the inspiration and foundational cleanup work.
