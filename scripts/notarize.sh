#!/bin/zsh
# Signs, notarizes and staples the app for distribution. Needs a paid Apple Developer ID.
# Usage: DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=my-profile scripts/notarize.sh
# Create the profile once: xcrun notarytool store-credentials my-profile --apple-id you@example.com --team-id TEAMID
set -euo pipefail
cd "${0:A:h}/.."
: "${DEVELOPER_ID:?set DEVELOPER_ID}" "${NOTARY_PROFILE:?set NOTARY_PROFILE}"
APP="build/Editor Workflow.app"
scripts/build.sh release
codesign --force --deep --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"
ditto -c -k --keepParent "$APP" "build/Editor Workflow.zip"
xcrun notarytool submit "build/Editor Workflow.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
ditto -c -k --keepParent "$APP" "build/Editor Workflow.zip"

# The installer is what people download: notarize and staple it too when an installer identity is set.
if [[ -n "${DEVELOPER_ID_INSTALLER:-}" ]]; then
  scripts/package.sh
  VERSION="$(cat VERSION 2>/dev/null || echo 0.1.0)"
  PKG="Editor Workflow ${VERSION}.pkg"
  xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$PKG"
  echo "Notarized: build/Editor Workflow.zip and $PKG"
else
  echo "Notarized: build/Editor Workflow.zip (set DEVELOPER_ID_INSTALLER to notarize the .pkg too)"
fi
