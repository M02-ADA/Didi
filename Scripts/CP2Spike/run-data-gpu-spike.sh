#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
spike_output="${CP2_GPU_OUTPUT:-/private/tmp/cp2-gpu/final}"
mkdir -p "$spike_output"
if [[ "${CP2_GPU_PLATFORM:-macos}" == simulator ]]; then
 sdk_name=iphonesimulator
 sdk="$(xcrun --sdk "$sdk_name" --show-sdk-path)"
 target=arm64-apple-ios26.5-simulator
else
 sdk_name=macosx
 sdk="$(xcrun --sdk "$sdk_name" --show-sdk-path)"
 target=arm64-apple-macosx26.0
fi
flags=(-parse-as-library -swift-version 5 -strict-concurrency=complete -warnings-as-errors -default-isolation MainActor
-enable-upcoming-feature NonisolatedNonsendingByDefault -enable-upcoming-feature InferIsolatedConformances
-enable-upcoming-feature InferSendableFromCaptures -enable-upcoming-feature GlobalActorIsolatedTypesUsability
-enable-upcoming-feature DisableOutwardActorInference -enable-upcoming-feature MemberImportVisibility
-sdk "$sdk" -target "$target" -module-cache-path "$spike_output/ModuleCache")
cp1=(Sedactive/Shared/Players/Player.swift Sedactive/Shared/BodyTracking/Models/{BodyGeometry,BodySnapshot,PlayerCalibration,BodyInputProviding}.swift)
core=(Scripts/CP2Spike/DataGPU/{SyntheticFrame,UploadStore}.swift)
sources=("${cp1[@]}" "${core[@]}" Scripts/CP2Spike/DataGPU/GPUTests.swift)
xcrun --sdk "$sdk_name" swiftc "${flags[@]}" -emit-sil -whole-module-optimization -o /dev/null "${sources[@]}" > "$spike_output/positive-sil.log" 2>&1
if xcrun --sdk "$sdk_name" swiftc "${flags[@]}" -emit-sil -whole-module-optimization -o /dev/null Scripts/CP2Spike/NegativeOwnershipControl.swift > "$spike_output/negative-sil.log" 2>&1; then
 echo 'FAIL: ownership negative accepted';exit 1
fi
rg -q 'risks causing data races' "$spike_output/negative-sil.log"
xcrun --sdk "$sdk_name" swiftc "${flags[@]}" -O -whole-module-optimization "${sources[@]}" -o "$spike_output/gpu-tests" > "$spike_output/build.log" 2>&1
if [[ "${CP2_GPU_BUILD_ONLY:-0}" != 1 ]]; then "$spike_output/gpu-tests" "$spike_output/results.json";fi
printf 'GPU spike build complete: %s\n' "$spike_output"
