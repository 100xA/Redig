#!/bin/bash
# Model-free regression tests for the production search service's queues, backpressure, coalescing and startup retry.
# macOS: scripts/test-search-service.sh
# Reuse an already-built DigUpKit: DIGUP_KIT_BUILD=.build/arm64-apple-macosx/debug scripts/test-search-service.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
if [[ $(uname -s) != Darwin ]]; then
  echo "This standalone DigUpKit harness currently runs on macOS; portable builds use the platform package tests." >&2
  exit 1
fi
work=$ROOT/.build/service-regressions
mkdir -p "$work"
if [[ -n ${DIGUP_KIT_BUILD:-} ]]; then
  kit=$(cd "$DIGUP_KIT_BUILD" && pwd)
  ln -sfn "$ROOT/scripts/testbed/search-service-main.swift" "$work/main.swift"
  swiftc -swift-version 6 -I "$kit/Modules" Sources/digup/SearchService.swift "$work/main.swift" \
    "$kit"/DigUpKit.build/*.o -o "$work/service-probe"
  binary=$work/service-probe
else
  package=$work/package
  mkdir -p "$package/Sources/ServiceProbe"
  ln -sfn "$ROOT/Sources/DigUpKit" "$package/Sources/DigUpKit"
  ln -sfn "$ROOT/Sources/digup/SearchService.swift" "$package/Sources/ServiceProbe/SearchService.swift"
  ln -sfn "$ROOT/scripts/testbed/search-service-main.swift" "$package/Sources/ServiceProbe/main.swift"
  cat > "$package/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "ServiceRegression", platforms: [.macOS(.v14)], targets: [
    .target(name: "DigUpKit"),
    .executableTarget(name: "ServiceProbe", dependencies: ["DigUpKit"]),
])
SWIFT
  swift build --package-path "$package" --scratch-path "$work/build" --product ServiceProbe
  binary=$(swift build --package-path "$package" --scratch-path "$work/build" --show-bin-path)/ServiceProbe
fi
python3 scripts/testbed/check-search-service.py "$binary"
