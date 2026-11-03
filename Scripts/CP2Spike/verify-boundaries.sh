#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
spike_output="${CP2_BOUNDARY_OUTPUT:-$(mktemp -d /private/tmp/cp2-boundaries.XXXXXX)}"
mkdir -p "$spike_output"
spike_sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
# Intentionally identical to verify-ownership.sh; assert equivalence before compiling.
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
python3 - <<'PY'
from pathlib import Path
import re, shlex
blocks=[]
for name in ['verify-ownership.sh','verify-boundaries.sh']:
    text=Path('Scripts/CP2Spike',name).read_text()
    block=re.search(r'spike_flags=\((.*?)"\$spike_output/ModuleCache"\)',text,re.S)
    assert block, name
    blocks.append(shlex.split(block.group(1)))
assert blocks[0]==blocks[1], 'Compiler flags diverged from original gate'
PY
xcrun swiftc --version > "$spike_output/toolchain.txt"
xcodebuild -version >> "$spike_output/toolchain.txt"
printf 'case\texpected\tactual\tobservation\n' > "$spike_output/results.tsv"
spike_failed=0
run_case() {
  local case_name="$1" expected="$2" description="$3"
  shift 3
  local actual=accept
  if ! xcrun swiftc "${spike_flags[@]}" "$@" > "$spike_output/$case_name.log" 2>&1; then actual=reject; fi
  local wanted="$expected"
  if [[ "$wanted" == unsafe-accept ]]; then wanted=accept; fi
  if [[ "$actual" != "$wanted" ]]; then
    echo "CHANGED $case_name: expected $expected, observed $actual"
    cat "$spike_output/$case_name.log"
    spike_failed=1
  elif [[ "$actual" == reject ]] && ! rg -q 'error: (sending|task or actor-isolated value cannot be sent|non-Sendable|conformance of .*Sendable)' "$spike_output/$case_name.log"; then
    echo "UNEXPECTED DIAGNOSTIC $case_name"
    cat "$spike_output/$case_name.log"
    spike_failed=1
  elif [[ "$expected" == unsafe-accept ]]; then
    echo "ACCEPTED UNSAFE CONTROL $case_name (NOT a safe design)"
  else
    echo "$actual $case_name"
  fi
  printf '%s\t%s\t%s\t%s\n' "$case_name" "$expected" "$actual" "$description" >> "$spike_output/results.tsv"
}
run_case original-pooled reject 'Original pooled producer remains rejected' \
  Sedactive/Shared/Players/Player.swift \
  Sedactive/Shared/BodyTracking/Models/BodyGeometry.swift \
  Sedactive/Shared/BodyTracking/Models/BodySnapshot.swift \
  Sedactive/Shared/BodyTracking/Models/PlayerCalibration.swift \
  Sedactive/Shared/BodyTracking/Models/BodyInputProviding.swift \
  Scripts/CP2Spike/PooledOwnershipProbe.swift Scripts/CP2Spike/OwnershipControls.swift
run_case original-negative reject 'Original writer-after-transfer negative control' \
  Scripts/CP2Spike/NegativeOwnershipControl.swift
while IFS=$'\t' read -r case_name expected description; do
  [[ -z "$case_name" || "$case_name" == \#* ]] && continue
  run_case "$case_name" "$expected" "$description" \
    Scripts/CP2Spike/BoundaryProbes/Support.swift "Scripts/CP2Spike/BoundaryProbes/$case_name.swift"
done < Scripts/CP2Spike/boundary-cases.tsv
echo "Results and full diagnostics: $spike_output"
echo 'Matching observations are not runtime validation or authorization for GPU implementation.'
exit "$spike_failed"
