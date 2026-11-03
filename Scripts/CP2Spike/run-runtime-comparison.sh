#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
spike_output="${CP2_RUNTIME_OUTPUT:-$(mktemp -d /private/tmp/cp2-runtime.XXXXXX)}"
mkdir -p "$spike_output"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
flags=(-parse-as-library -swift-version 5 -strict-concurrency=complete -warnings-as-errors -default-isolation MainActor
-enable-upcoming-feature NonisolatedNonsendingByDefault -enable-upcoming-feature InferIsolatedConformances
-enable-upcoming-feature InferSendableFromCaptures -enable-upcoming-feature GlobalActorIsolatedTypesUsability
-enable-upcoming-feature DisableOutwardActorInference -sdk "$sdk" -target arm64-apple-macosx26.0
-module-cache-path "$spike_output/ModuleCache")
sources=(Scripts/CP2Spike/Runtime/*.swift)
xcrun swiftc --version > "$spike_output/toolchain.txt" 2>&1
xcodebuild -version >> "$spike_output/toolchain.txt"
sw_vers >> "$spike_output/toolchain.txt"
xcrun swiftc "${flags[@]}" -emit-sil -whole-module-optimization -o /dev/null "${sources[@]}" > "$spike_output/positive-sil.log" 2>&1
if xcrun swiftc "${flags[@]}" -emit-sil -whole-module-optimization -D CP2_RUNTIME_NEGATIVE -o /dev/null "${sources[@]}" > "$spike_output/negative-sil.log" 2>&1; then
    echo 'FAIL: runtime ownership negative control was accepted'; exit 1
fi
rg -q "sending 'owner' risks causing data races" "$spike_output/negative-sil.log"
if xcrun swiftc "${flags[@]}" -emit-sil -whole-module-optimization -o /dev/null Scripts/CP2Spike/NegativeOwnershipControl.swift > "$spike_output/original-negative-sil.log" 2>&1; then
    echo 'FAIL: original ownership negative control was accepted'; exit 1
fi
rg -q "sending 'value' risks causing data races" "$spike_output/original-negative-sil.log"
echo 'Complete-checking SIL positive clean; runtime and original negative controls diagnosed.'
xcrun swiftc "${flags[@]}" -O -whole-module-optimization "${sources[@]}" -o "$spike_output/comparison" > "$spike_output/build.log" 2>&1
xcrun swiftc "${flags[@]}" -emit-sil -whole-module-optimization -o /dev/null Scripts/CP2Spike/RuntimeBackingProbe.swift > "$spike_output/backing-sil.log" 2>&1
xcrun swiftc "${flags[@]}" -O -whole-module-optimization Scripts/CP2Spike/RuntimeBackingProbe.swift -o "$spike_output/backing-probe" > "$spike_output/backing-build.log" 2>&1
if [[ "${CP2_RUNTIME_BUILD_ONLY:-0}" == 1 ]]; then echo "Built: $spike_output/comparison"; exit 0; fi
python3 Scripts/CP2Spike/Runtime/run-comparison.py "$spike_output/comparison" "$spike_output"
