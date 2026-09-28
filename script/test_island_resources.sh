#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-resource-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc "$ROOT_DIR/SimpleMole/Services/IslandResourcePolicy.swift" \
    "$ROOT_DIR/script/IslandResourcePolicyTests.swift" -o "$TEST_DIR/IslandResourcePolicyTests"
"$TEST_DIR/IslandResourcePolicyTests"
