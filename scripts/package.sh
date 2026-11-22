#!/bin/zsh
# Builds the app and wraps it in an installer: ./Editor Workflow <version>.pkg in the project folder (installs to /Applications).
# Usage: scripts/package.sh [--no-seeds]   --no-seeds ships without the bundled template library.
# Unsigned unless DEVELOPER_ID_INSTALLER is set, e.g. "Developer ID Installer: Your Name (TEAMID)".
set -euo pipefail
cd "${0:A:h}/.."
NO_SEEDS=0
for a in "$@"; do [[ "$a" == "--no-seeds" ]] && NO_SEEDS=1; done
VERSION="$(cat VERSION 2>/dev/null || echo 0.1.0)"
EW_NO_SEEDS="$NO_SEEDS" scripts/build.sh release

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/root/Applications"
ditto --norsrc --noextattr "build/Editor Workflow.app" "$STAGE/root/Applications/Editor Workflow.app"
# Uninstaller travels with the app: recipients always have a way back.
cp "Uninstall Editor Workflow.command" "$STAGE/root/Applications/"
chmod 755 "$STAGE/root/Applications/Uninstall Editor Workflow.command"
xattr -cr "$STAGE/root"   # macOS re-adds provenance attributes; they would ship as ._ files

# Not relocatable: otherwise macOS may "update" a copy found elsewhere (e.g. this build folder) instead of /Applications.
pkgbuild --analyze --root "$STAGE/root" "$STAGE/components.plist" >/dev/null
plutil -replace 0.BundleIsRelocatable -bool NO "$STAGE/components.plist"

OUT="Editor Workflow ${VERSION}.pkg"
[[ "$NO_SEEDS" == 1 ]] && OUT="Editor Workflow ${VERSION} (no templates).pkg"
SIGN=()
[[ -n "${DEVELOPER_ID_INSTALLER:-}" ]] && SIGN=(--sign "$DEVELOPER_ID_INSTALLER")
pkgbuild --root "$STAGE/root" --component-plist "$STAGE/components.plist" --install-location / \
  --identifier app.editorworkflow.mac --version "$VERSION" "${SIGN[@]}" "$OUT"
echo "Built $OUT"
