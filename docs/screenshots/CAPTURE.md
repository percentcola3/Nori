# README screenshot provenance

The English (`en`) and Simplified Chinese (`zh-CN`) images are native renders of the Nori SwiftUI views in this repository, hosted in real AppKit windows. They use synthetic demonstration data. The example `/Users/demo` paths, reclaimable sizes, installed tools, histories, clipboard entries, process metrics, and automation statistics are illustrations, not measurements from a user's Mac or a promised cleanup result.

| Image | Product view |
| --- | --- |
| `overview.png` | `MainWindowView` and the cleanup landing state |
| `cleanup.png` | `MainWindowView` / `CleanupTabView` with sample candidates |
| `developers.png` | The actual `DeveloperRuntimePanel`, shown separately so Shell, hosts, and CLI audits do not inspect the machine |
| `agents.png` | `MainWindowView` / `AgentsTabView` with sample Agent groups and a Skill |
| `automation.png` | The actual `AutoCleanupRulesView` presented from the main window |
| `clipboard.png` | `MainWindowView` / `ClipboardHistoryTabView` with fictional entries |
| `screenshot.png` | The actual `ScreenshotEditorView`, editing the generated overview image |
| `island.png` | The actual `FloatingIslandView`, expanded with sample memory statistics |

## Regenerate

Requires a Mac with an active graphical desktop, Swift, and a compatible macOS 26.x SDK. These assets were rendered on macOS 27.0.1 with the macOS 26.5 SDK, from the Nori 1.0.0 working sources on October 1, 2026. Glass appearance follows the OS renderer and the accessibility transparency preference.

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools script/capture_readme_screenshots.sh
```

Pass a directory as the first argument to write elsewhere. `SDKROOT` can select a compatible SDK. The renderer compiles into a disposable temporary bundle and does not replace or launch the installed Nori app.

The script first snapshots the product sources into its temporary directory so edits in the working checkout cannot change compile inputs midway through rendering. It then adjusts temporary copies of three product source files. It replaces `AppState.init` with fixture initialization, redirects clipboard and traffic persistence to the temporary fixture directory, disables the persisted automation-rule loader, seeds a permission fixture, and seeds the island's private expanded state. All view bodies remain product code. The two fixture-only view wrappers host the runtime panel and place the island over a neutral native gradient. No source file under `SimpleMole` is changed.

The temporary bundle has a separate identifier (`com.nori.readme-renderer`) and its own fixture defaults suite. Each language runs in a separate process with its own temporary history and locale defaults, including native date formatting. It does not start scans, deletion jobs, live inventory watchers, clipboard polling, hotkeys, or traffic monitoring. Its windows ignore mouse input.

Capture uses `/usr/sbin/screencapture -x -o -l <own-window-id>` to retain SwiftUI's native compositor and Liquid Glass. A dedicated opaque backing window supplies a neutral color for the glass to sample, so the resulting PNG contains no private backdrop. The borderless island fixture also has an opaque neutral window background so its transparent outer pixels remain readable in the README. The tool captures only that exact renderer window, never the desktop or another application's window. No image-generation or replacement UI is used. If the invoking terminal/app cannot capture that window, the script fails; it does not fall back to a desktop screenshot.

## Review

After regeneration, visually inspect both locales for clipping, untranslated keys, empty image previews, and changes to view layouts. Keep corresponding English and Chinese files together when updating the README. Permission fixtures are only for screenshot presentation and do not validate real macOS privacy permissions, release signing, or permission retention across upgrades.
