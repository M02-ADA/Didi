#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
spike_output="${CP2_GPU_OUTPUT:-/private/tmp/cp2-gpu/final}"
mkdir -p "$spike_output"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
flags=(-parse-as-library -swift-version 5 -strict-concurrency=complete -warnings-as-errors -default-isolation MainActor
-enable-upcoming-feature NonisolatedNonsendingByDefault -enable-upcoming-feature InferIsolatedConformances
-enable-upcoming-feature InferSendableFromCaptures -enable-upcoming-feature GlobalActorIsolatedTypesUsability
-enable-upcoming-feature DisableOutwardActorInference -enable-upcoming-feature MemberImportVisibility
-sdk "$sdk" -target arm64-apple-macosx26.0 -module-cache-path "$spike_output/ModuleCache")
sources=(Sedactive/Shared/Players/Player.swift Sedactive/Shared/BodyTracking/Models/{BodyGeometry,BodySnapshot,PlayerCalibration,BodyInputProviding}.swift
Scripts/CP2Spike/DataGPU/{SyntheticFrame,UploadStore,VisualHarness}.swift)
xcrun swiftc "${flags[@]}" -emit-sil -whole-module-optimization -o /dev/null "${sources[@]}" > "$spike_output/visual-sil.log" 2>&1
app="$spike_output/CP2Synthetic.app"
mkdir -p "$app/Contents/MacOS"
xcrun swiftc "${flags[@]}" -O -whole-module-optimization "${sources[@]}" -o "$app/Contents/MacOS/CP2Synthetic" > "$spike_output/visual-build.log" 2>&1
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>CP2Synthetic</string><key>CFBundleIdentifier</key><string>com.sedactive.spike.cp2-synthetic</string><key>CFBundleName</key><string>CP2 Synthetic Cutout Spike</string><key>CFBundlePackageType</key><string>APPL</string><key>LSMinimumSystemVersion</key><string>26.0</string><key>NSHighResolutionCapable</key><true/></dict></plist>
PLIST
codesign --force --sign - "$app" > "$spike_output/visual-sign.log" 2>&1
printf 'Built isolated app: %s\n' "$app"
