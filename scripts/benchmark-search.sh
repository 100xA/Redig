#!/usr/bin/env bash
# macOS, Swift 6.2+: no embedding models, llama.cpp build, or package downloads.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
baseline_revision="${BASELINE_REV:-ec28973268b81f836be72187ff23b3a16ef4fd97}"
if [[ "$(uname -s)" != Darwin ]]; then
    echo "This model-free benchmark currently uses the macOS engine target." >&2
    exit 1
fi
bench_root="$(mktemp -d "${TMPDIR:-/tmp}/digup-search-benchmark.XXXXXX")"
if [[ "${KEEP_BENCHMARK:-0}" == 1 ]]; then
    printf 'Retained benchmark directory: %s\n' "$bench_root"
else
    trap 'rm -rf "$bench_root"' EXIT
fi
printf 'Baseline revision: %s\n' "$(git -C "$repo_root" rev-parse "$baseline_revision")"
printf 'Current revision: %s (including working-tree source changes)\n' "$(git -C "$repo_root" rev-parse HEAD)"
swift --version
sysctl -n machdep.cpu.brand_string
sysctl -n hw.memsize
for variant in baseline current; do
    package_dir="$bench_root/$variant"
    mkdir -p "$package_dir/Sources/Benchmark"
    if [[ "$variant" == baseline ]]; then
        git -C "$repo_root" archive "$baseline_revision" Sources/DigUpKit | tar -xf - -C "$package_dir"
    else
        cp -R "$repo_root/Sources/DigUpKit" "$package_dir/Sources/DigUpKit"
    fi
    cp "$repo_root/scripts/testbed/search_benchmark.swift" "$package_dir/Sources/Benchmark/main.swift"
    python3 - "$package_dir" "$variant" <<'PY'
import pathlib, sys
folder, variant = pathlib.Path(sys.argv[1]), sys.argv[2]
flags = ', swiftSettings: [.define("INCREMENTAL_SEARCH")]' if variant == 'current' else ''
(folder / 'Package.swift').write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "SearchBenchmark", platforms: [.macOS(.v14)], products: [.executable(name: "search-benchmark", targets: ["Benchmark"])], targets: [.target(name: "DigUpKit", swiftSettings: [.unsafeFlags(["-enable-testing"])]), .executableTarget(name: "Benchmark", dependencies: ["DigUpKit"]''' + flags + ''')])
''')
PY
    printf '\nBuilding variant: %s\n' "$variant"
    (cd "$package_dir" && swift build --build-system native -c release --product search-benchmark)
done
# Complete both compilers before timing either executable. Retained builds can be rerun without compilation.
for variant in baseline current; do
    printf '\nVariant: %s\n' "$variant"
    (cd "$bench_root/$variant" && .build/release/search-benchmark "$@")
done
