#!/bin/zsh
# Builds build/Editor Workflow.app with swiftc only (Xcode Command Line Tools are enough).
# Usage: scripts/build.sh [debug|release]   (default release)
set -euo pipefail
cd "${0:A:h}/.."
CONFIG="${1:-release}"
APP="build/Editor Workflow.app"
mkdir -p .build build
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
OPT=(-O); [[ "$CONFIG" == debug ]] && OPT=(-Onone -g)

swiftc -swift-version 5 "${OPT[@]}" -parse-as-library -target arm64-apple-macos15.0 \
  Sources/Core/*.swift Sources/App/*.swift -lsqlite3 -o .build/EditorWorkflow

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/EditorWorkflow "$APP/Contents/MacOS/EditorWorkflow"
cp Resources/resolve_bridge.py Resources/probe_clip.mp4 Resources/AppIcon.icns "$APP/Contents/Resources/"
cp docs/capability-matrix.md "$APP/Contents/Resources/"
# Templates exported by scripts/seed.sh: a fresh install starts with this library.
# EW_NO_SEEDS=1 leaves them out (scripts/package.sh --no-seeds), for a package that ships empty.
if [[ -d Resources/templates && "${EW_NO_SEEDS:-0}" != "1" ]]; then
  ditto Resources/templates "$APP/Contents/Resources/templates"
fi
VERSION="$(cat VERSION 2>/dev/null || echo 0.1.0)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Editor Workflow</string>
  <key>CFBundleDisplayName</key><string>Editor Workflow</string>
  <key>CFBundleIdentifier</key><string>app.editorworkflow.mac</string>
  <key>CFBundleExecutable</key><string>EditorWorkflow</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSRemovableVolumesUsageDescription</key><string>Editor Workflow reads camera cards and external drives you choose so it can copy and verify footage.</string>
  <key>NSNetworkVolumesUsageDescription</key><string>Editor Workflow copies footage to network folders you choose.</string>
  <key>NSDesktopFolderUsageDescription</key><string>Editor Workflow uses project folders you choose on the Desktop.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Editor Workflow uses project folders you choose in Documents.</string>
</dict></plist>
PLIST
# Ad-hoc signature so macOS keeps permissions stable between launches. Release signing: scripts/notarize.sh.
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "note: ad-hoc codesign skipped"
echo "Built $APP"
