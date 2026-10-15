#!/bin/bash
# Model-free native regressions for the actual search palette, command dispatcher and organizer controller.
# Reuse a built Kit with DIGUP_KIT_BUILD=.build/arm64-apple-macosx/debug scripts/test-organizer-commands.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
if [[ $(uname -s) != Darwin ]]; then
  echo "The native organizer command harness requires macOS; portable policy tests run with DigUpKit." >&2
  exit 1
fi
work=$ROOT/.build/organizer-command-regressions
mkdir -p "$work"
sources=(AppSettings OrganizerController OrganizerCommandActions CommandPalette)
if [[ -n ${DIGUP_KIT_BUILD:-} ]]; then
  kit=$(cd "$DIGUP_KIT_BUILD" && pwd)
  inputs=()
  for source in "${sources[@]}"; do inputs+=("Sources/DigUpApp/$source.swift"); done
  swiftc -swift-version 6 -default-isolation MainActor -parse-as-library -I "$kit/Modules" \
    "${inputs[@]}" scripts/testbed/organizer-command-main.swift "$kit"/DigUpKit.build/*.swift.o \
    -o "$work/organizer-command-probe"
  binary=$work/organizer-command-probe
else
  package=$work/package
  mkdir -p "$package/Sources/OrganizerCommandProbe"
  ln -sfn "$ROOT/Sources/DigUpKit" "$package/Sources/DigUpKit"
  for source in "${sources[@]}"; do
    ln -sfn "$ROOT/Sources/DigUpApp/$source.swift" "$package/Sources/OrganizerCommandProbe/$source.swift"
  done
  ln -sfn "$ROOT/scripts/testbed/organizer-command-main.swift" "$package/Sources/OrganizerCommandProbe/Probe.swift"
  cat > "$package/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "OrganizerCommandRegression", platforms: [.macOS(.v14)], targets: [
    .target(name: "DigUpKit"),
    .executableTarget(name: "OrganizerCommandProbe", dependencies: ["DigUpKit"],
                      swiftSettings: [.defaultIsolation(MainActor.self)]),
])
SWIFT
  swift build --package-path "$package" --scratch-path "$work/build" --product OrganizerCommandProbe
  binary=$(swift build --package-path "$package" --scratch-path "$work/build" --show-bin-path)/OrganizerCommandProbe
fi
# Bound the whole process as well as each asynchronous scenario; a lost continuation cannot hang CI.
python3 - "$binary" <<'PY'
import subprocess, sys, uuid
subprocess.run([sys.argv[1], '-defaultsSuite', 'com.redig.command-regression.' + str(uuid.uuid4())],
               check=True, timeout=120)
PY
