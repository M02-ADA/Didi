#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
spike_output="${CP2_SPIKE_OUTPUT:-$(mktemp -d /private/tmp/cp2-ownership.XXXXXX)}"
mkdir -p "$spike_output"
spike_sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
# Region-based transfer diagnostics require SIL analysis; -typecheck alone missed this failure.
spike_flags=(-emit-sil -whole-module-optimization -o /dev/null
  -swift-version 5 -strict-concurrency=complete -warnings-as-errors
  -default-isolation MainActor
  -enable-upcoming-feature NonisolatedNonsendingByDefault
  -enable-upcoming-feature InferIsolatedConformances
  -enable-upcoming-feature InferSendableFromCaptures
  -enable-upcoming-feature GlobalActorIsolatedTypesUsability
  -enable-upcoming-feature DisableOutwardActorInference
  -sdk "$spike_sdk" -target arm64-apple-ios26.5-simulator
  -module-cache-path "$spike_output/ModuleCache")
spike_sources=(Sedactive/Shared/Players/Player.swift
  Sedactive/Shared/BodyTracking/Models/BodyGeometry.swift
  Sedactive/Shared/BodyTracking/Models/BodySnapshot.swift
  Sedactive/Shared/BodyTracking/Models/PlayerCalibration.swift
  Sedactive/Shared/BodyTracking/Models/BodyInputProviding.swift
  Scripts/CP2Spike/PooledOwnershipProbe.swift
  Scripts/CP2Spike/OwnershipControls.swift)
spike_failed=0
if xcrun swiftc "${spike_flags[@]}" "${spike_sources[@]}" > "$spike_output/positive.log" 2>&1; then
  echo "PASS: pooled positive path compiled cleanly"
else
  cat "$spike_output/positive.log"
  echo "BLOCKED: pooled positive path failed; do not continue to GPU implementation"
  spike_failed=1
fi
if xcrun swiftc "${spike_flags[@]}" Scripts/CP2Spike/NegativeOwnershipControl.swift > "$spike_output/negative.log" 2>&1; then
  echo "FAIL: compiler accepted the deliberate writer-after-transfer violation"
  spike_failed=1
elif rg -q 'sending .*risks causing data races|used after being passed as a .sending.|used after being transferred|Sending .* risks causing data races' "$spike_output/negative.log"; then
  cat "$spike_output/negative.log"
  echo "PASS: separate negative control diagnosed as expected"
else
  cat "$spike_output/negative.log"
  echo "FAIL: negative control failed for an unexpected reason"
  spike_failed=1
fi
echo "Logs: $spike_output"
exit "$spike_failed"
