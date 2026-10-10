#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
DIRECTORY_GIT_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-directory-git.XXXXXX")"
trap 'rm -rf "$DIRECTORY_GIT_TEST_DIR"' EXIT

# Compile the production runner and helpers, without unrelated UI model types.
awk 'BEGIN { print "import Foundation" } /^struct RunResult / { copying=1 } copying { print } copying && /^}/ { exit }' \
    "$ROOT_DIR/SimpleMole/Models.swift" > "$DIRECTORY_GIT_TEST_DIR/RunResult.swift"
awk '/^extension DeveloperSSHGitService/ { print "enum DeveloperSSHGitService {}" } /^    static func gitCommand/ { print "}"; exit } { print }' \
    "$ROOT_DIR/SimpleMole/Services/DeveloperSSHGitCommands.swift" > "$DIRECTORY_GIT_TEST_DIR/GitEnvironment.swift"
awk 'BEGIN { print "import Foundation" } /^    static func executable\(/ { print "enum DeveloperToolchainService {"; copying=1 } /^    private static func activeExecutable/ { print "}"; exit } copying { print }' \
    "$ROOT_DIR/SimpleMole/Services/DeveloperToolchainService.swift" > "$DIRECTORY_GIT_TEST_DIR/GitExecutable.swift"

swiftc -Onone -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "$DIRECTORY_GIT_TEST_DIR/cache" -framework Security \
    "$DIRECTORY_GIT_TEST_DIR/RunResult.swift" \
    "$DIRECTORY_GIT_TEST_DIR/GitEnvironment.swift" \
    "$DIRECTORY_GIT_TEST_DIR/GitExecutable.swift" \
    "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift" \
    "$ROOT_DIR/SimpleMole/Services/MoleEngine.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperTerminalEnvironment.swift" \
    "$ROOT_DIR/SimpleMole/Services/DirectoryGitService.swift" \
    "$ROOT_DIR/script/DirectoryGitTests.swift" \
    -o "$DIRECTORY_GIT_TEST_DIR/tests"
"$DIRECTORY_GIT_TEST_DIR/tests" "$DIRECTORY_GIT_TEST_DIR/fixture"
