#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../../.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
output="${CP2_ALPHA_OUTPUT:-/private/tmp/cp2-alpha}"
mkdir -p "$output"
flags=(-parse-as-library -swift-version 5 -strict-concurrency=complete -warnings-as-errors -default-isolation MainActor
-enable-upcoming-feature NonisolatedNonsendingByDefault -enable-upcoming-feature InferIsolatedConformances
-enable-upcoming-feature InferSendableFromCaptures -enable-upcoming-feature GlobalActorIsolatedTypesUsability
-enable-upcoming-feature DisableOutwardActorInference -enable-upcoming-feature MemberImportVisibility
-sdk "$(xcrun --sdk macosx --show-sdk-path)" -target arm64-apple-macosx26.0 -module-cache-path "$output/ModuleCache")
base=(Sedactive/Shared/Players/Player.swift Sedactive/Shared/BodyTracking/Models/{BodyGeometry,BodySnapshot,PlayerCalibration,BodyInputProviding}.swift
Scripts/CP2Spike/DataGPU/{SyntheticFrame,UploadStore}.swift)
xcrun --sdk macosx swiftc "${flags[@]}" -emit-sil -whole-module-optimization -o /dev/null "${base[@]}" Scripts/CP2Spike/DataGPU/AlphaReview/{AlphaEncoding,OffscreenScene,ReviewMain}.swift > "$output/review-sil.log" 2>&1
xcrun --sdk macosx swiftc "${flags[@]}" -O -whole-module-optimization "${base[@]}" Scripts/CP2Spike/DataGPU/AlphaReview/{AlphaEncoding,OffscreenScene,ReviewMain}.swift -o "$output/review" > "$output/review-build.log" 2>&1

if xcrun --sdk macosx swiftc "${flags[@]}" -emit-sil -whole-module-optimization -o /dev/null Scripts/CP2Spike/NegativeOwnershipControl.swift > "$output/negative-sil.log" 2>&1; then
 echo "FAIL: negative ownership control was accepted";exit 1
fi
rg -q 'risks causing data races' "$output/negative-sil.log"
xcrun --sdk macosx swiftc "${flags[@]}" -emit-sil -whole-module-optimization -o /dev/null Scripts/CP2Spike/DataGPU/AlphaReview/InspectRecording.swift > "$output/recording-sil.log" 2>&1
printf 'Complete concurrency/SIL positive clean; negative control diagnosed. Built: %s/review\n' "$output"
if [[ "${CP2_ALPHA_VISUAL:-0}" == 1 ]]; then
 visual=("${base[@]}" Scripts/CP2Spike/DataGPU/AlphaReview/{AlphaEncoding,OffscreenScene}.swift Scripts/CP2Spike/DataGPU/VisualHarness.swift)
 for variant in Before After; do
  extra=(-D CP2_ALPHA_REVIEW)
  if [[ "$variant" == Before ]]; then extra+=(-D CP2_ALPHA_BASELINE);fi
  xcrun --sdk macosx swiftc "${flags[@]}" "${extra[@]}" -emit-sil -whole-module-optimization -o /dev/null "${visual[@]}" > "$output/visual-$variant-sil.log" 2>&1
  app="$output/CP2Alpha$variant.app"
  mkdir -p "$app/Contents/MacOS"
  xcrun --sdk macosx swiftc "${flags[@]}" "${extra[@]}" -O -whole-module-optimization "${visual[@]}" -o "$app/Contents/MacOS/CP2Alpha$variant" > "$output/visual-$variant-build.log" 2>&1
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>CP2Alpha$variant</string><key>CFBundleIdentifier</key><string>com.sedactive.spike.cp2-alpha-$variant</string><key>CFBundleName</key><string>CP2 Alpha $variant</string><key>CFBundlePackageType</key><string>APPL</string><key>LSMinimumSystemVersion</key><string>26.0</string><key>NSHighResolutionCapable</key><true/></dict></plist>
PLIST
  codesign --force --sign - "$app" > "$output/sign-$variant.log" 2>&1
 done
fi
