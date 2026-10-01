# Sparkle dependency and signing

`script/fetch_sparkle.py` downloads the official Sparkle 2.10.0 release SDK. The
version, immutable release URL, and SHA256 are pinned in
`vendor/sparkle/release.json`. The SHA256 comes from the official
[GitHub asset page](https://github.com/sparkle-project/Sparkle/releases/expanded_assets/2.10.0).
The checked-in `vendor/sparkle/LICENSE` includes Sparkle's external licenses.

The SDK cache is `.build/dependencies/sparkle/2.10.0`. The downloader checks the
archive digest on every invocation and verifies cached framework/tool contents;
modified extracted contents are restored from the verified archive. A corrupt
cached archive is rejected. `--offline` requires that verified archive to exist.
The command writes only the SDK path to stdout, so release scripts can use:

```sh
SPARKLE_DIR="$(/usr/bin/python3 script/fetch_sparkle.py)"
"$SPARKLE_DIR/bin/sign_update" --help
```

The complete framework contains arm64 and x86_64 code and requires macOS 12 or
later. Nori continues targeting macOS 13. `script/build.sh` adds the framework
search path and `@executable_path/../Frameworks` runpath, preserves the versioned
framework's symlinks with `ditto`, and signs Installer.xpc, Downloader.xpc,
Autoupdate, Updater.app, the framework, and the host in that order. Downloader's
original entitlements are preserved. Signing uses the same resolved certificate
as Nori, including the pinned public release certificate. Strict deep
verification runs after signing; `--deep` is not used to sign.
The App includes Sparkle's license at `Contents/Resources/Licenses/Sparkle.txt`.
Each architecture's built `Info.plist` points to its matching appcast URL.
`SM_OUTPUT_DIR` can isolate build artifacts from the default `dist` directory.

## The self-signed host exception

Hardened runtime library validation requires an Apple-signed library or a library
with the host's Apple Team ID. Nori's existing `ForgeSweep Release Signing`
certificate is self-signed and has no Team ID. Signing both Nori and Sparkle with
that same certificate therefore does not satisfy this requirement.

An arm64 macOS 13-targeted probe linked to `SPUUpdater` reproduced this on the
development Mac: every component passed `codesign --verify --deep --strict`, but
the executable aborted with dyld reporting:

```text
mapping process and mapped file (non-platform) have different Team IDs
```

Re-signing only the probe host with
`com.apple.security.cs.disable-library-validation = true` allowed the same
framework to load and print `Sparkle-loaded: SPUUpdater` with exit status 0.
The build therefore applies the explicit
`signing/sparkle-selfsigned.entitlements` file only to self-signed and ad-hoc
hosts. It contains that single exception and adds no other privileges. Apple
Development and Developer ID hosts keep library validation enabled. Sparkle's
helper executables link only system libraries and receive no such exception.
The exception does not replace code-signature verification or Ed25519 update
validation and does not alter Nori's pinned public certificate.

Sources: [Sparkle installation](https://sparkle-project.org/documentation/),
[Sparkle signing order](https://sparkle-project.org/documentation/sandboxing/#code-signing),
[Apple library-validation entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation).

`script/test_sparkle.py` checks the locked dependency cache, extraction safety,
restoration of modified cached files, and entitlement selection for each signing
identity class. A real signed launch and update remain release verification
steps; dependency fixture tests alone do not prove update installation works.
