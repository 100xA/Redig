#!/bin/bash
# Test the macOS engine without building llama.cpp, downloading models or resolving app dependencies.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$(uname -s)" == Darwin ]] || { echo "Use swift test from the main package on Linux/Windows (portable vendor libraries required)." >&2; exit 1; }
TASK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/digup-kit-tests.XXXXXX")"
trap 'rm -rf "$TASK_DIR"' EXIT
mkdir -p "$TASK_DIR/Sources" "$TASK_DIR/Tests"
ln -s "$ROOT/Sources/DigUpKit" "$TASK_DIR/Sources/DigUpKit"
ln -s "$ROOT/Tests/DigUpKitTests" "$TASK_DIR/Tests/DigUpKitTests"
cat > "$TASK_DIR/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "DigUpEngineChecks", platforms: [.macOS(.v14)], targets: [
    .target(name: "DigUpKit"),
    .testTarget(name: "DigUpKitTests", dependencies: ["DigUpKit"], exclude: ["Pictures", "Videos"]),
])
SWIFT
swift test --package-path "$TASK_DIR" --build-system native "$@"
