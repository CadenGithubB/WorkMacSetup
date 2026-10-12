#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && /bin/pwd)"
SOURCE_FILE="${SCRIPT_DIR}/Sources/WorkMacSetupApp.swift"
APP_DIR="${SCRIPT_DIR}/dist/Work Mac Setup.app"
ZIP_FILE="${SCRIPT_DIR}/dist/Work Mac Setup.zip"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
DOCK_HELPER_DIR="${CONTENTS_DIR}/Helpers/Work Mac Dock Helper.app"
DOCK_HELPER_CONTENTS="${DOCK_HELPER_DIR}/Contents"
BUILD_DIR="${SCRIPT_DIR}/.build"

/bin/mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$BUILD_DIR" "${DOCK_HELPER_CONTENTS}/MacOS"
/bin/mkdir -p "${BUILD_DIR}/ModuleCache"

/usr/bin/swift -module-cache-path "${BUILD_DIR}/ModuleCache" \
  "$SCRIPT_DIR/Tools/EmbedGuide.swift" "$SCRIPT_DIR/GUIDE.md" "${BUILD_DIR}/EmbeddedGuide.swift"

/usr/bin/swiftc \
  -parse-as-library \
  -O \
  -module-cache-path "${BUILD_DIR}/ModuleCache" \
  -target arm64-apple-macosx13.0 \
  -framework SwiftUI \
  -framework AppKit \
  "$SOURCE_FILE" \
  "$SCRIPT_DIR/Sources/InstalledApp.swift" "$SCRIPT_DIR/Sources/DockDragRunner.swift" \
  "$SCRIPT_DIR/Sources/GuideView.swift" "$SCRIPT_DIR/Sources/GuideDocument.swift" "${BUILD_DIR}/EmbeddedGuide.swift" \
  "$SCRIPT_DIR/Sources/DragPalette.swift" \
  "$SCRIPT_DIR/Sources/SetupRunner.swift" \
  "$SCRIPT_DIR/Sources/ChromeProfileCreator.swift" \
  -o "${BUILD_DIR}/WorkMacSetup-arm64"

/usr/bin/swiftc \
  -parse-as-library \
  -O \
  -module-cache-path "${BUILD_DIR}/ModuleCache" \
  -target x86_64-apple-macosx13.0 \
  -framework SwiftUI \
  -framework AppKit \
  "$SOURCE_FILE" \
  "$SCRIPT_DIR/Sources/InstalledApp.swift" "$SCRIPT_DIR/Sources/DockDragRunner.swift" \
  "$SCRIPT_DIR/Sources/GuideView.swift" "$SCRIPT_DIR/Sources/GuideDocument.swift" "${BUILD_DIR}/EmbeddedGuide.swift" \
  "$SCRIPT_DIR/Sources/DragPalette.swift" \
  "$SCRIPT_DIR/Sources/SetupRunner.swift" \
  "$SCRIPT_DIR/Sources/ChromeProfileCreator.swift" \
  -o "${BUILD_DIR}/WorkMacSetup-x86_64"

/usr/bin/lipo -create \
  "${BUILD_DIR}/WorkMacSetup-arm64" \
  "${BUILD_DIR}/WorkMacSetup-x86_64" \
  -output "${MACOS_DIR}/WorkMacSetup"

# Ship a compiled profile helper; deployment Macs do not need Swift or Xcode.
for architecture in arm64 x86_64; do
  /usr/bin/swiftc -parse-as-library -O \
    -module-cache-path "${BUILD_DIR}/ModuleCache" \
    -target "${architecture}-apple-macosx13.0" \
    -framework Foundation -framework AppKit \
    "$SCRIPT_DIR/Sources/ChromeProfileCreator.swift" \
    "$SCRIPT_DIR/Sources/ChromeProfileTool.swift" \
    -o "${BUILD_DIR}/chrome-profile-helper-${architecture}"
done
/usr/bin/lipo -create \
  "${BUILD_DIR}/chrome-profile-helper-arm64" \
  "${BUILD_DIR}/chrome-profile-helper-x86_64" \
  -output "${BUILD_DIR}/chrome-profile-helper"
/bin/cp "${BUILD_DIR}/chrome-profile-helper" "$RESOURCES_DIR/chrome-profile-helper"
/bin/chmod 755 "$RESOURCES_DIR/chrome-profile-helper"
/usr/bin/codesign --force --sign - "$RESOURCES_DIR/chrome-profile-helper"

# The Dock panel runs separately under a read-only application sandbox. Keep
# the normal file-URL drag contract without permitting app-bundle writes.
for architecture in arm64 x86_64; do
  /usr/bin/swiftc -parse-as-library -O -D DOCK_DRAG_HELPER \
    -module-cache-path "${BUILD_DIR}/ModuleCache" \
    -target "${architecture}-apple-macosx13.0" \
    -framework AppKit -framework SwiftUI \
    "$SCRIPT_DIR/Sources/InstalledApp.swift" \
    "$SCRIPT_DIR/Sources/DragPalette.swift" \
    "$SCRIPT_DIR/Sources/DockDragHelper.swift" \
    -o "${BUILD_DIR}/dock-drag-helper-${architecture}"
done
/usr/bin/lipo -create "${BUILD_DIR}/dock-drag-helper-arm64" "${BUILD_DIR}/dock-drag-helper-x86_64" \
  -output "${DOCK_HELPER_CONTENTS}/MacOS/WorkMacDockHelper"
/usr/bin/plutil -create xml1 "${DOCK_HELPER_CONTENTS}/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string local.workmacsetup.dock-helper' "${DOCK_HELPER_CONTENTS}/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string WorkMacDockHelper' "${DOCK_HELPER_CONTENTS}/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleName string Work Mac Dock Helper' "${DOCK_HELPER_CONTENTS}/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "${DOCK_HELPER_CONTENTS}/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :LSUIElement bool true' "${DOCK_HELPER_CONTENTS}/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :LSMinimumSystemVersion string 13.0' "${DOCK_HELPER_CONTENTS}/Info.plist"
/usr/bin/codesign --force --sign - --entitlements "$SCRIPT_DIR/Resources/DockDragHelper.entitlements" "$DOCK_HELPER_DIR"

/bin/cp "$SCRIPT_DIR/post-enrollment.sh" "$RESOURCES_DIR/post-enrollment.sh"
/bin/cp "$SCRIPT_DIR/README.md" "$RESOURCES_DIR/README.md"
/bin/chmod 755 "$MACOS_DIR/WorkMacSetup" "$RESOURCES_DIR/post-enrollment.sh"

/usr/bin/plutil -create xml1 "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleDisplayName string Work Mac Setup' "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string WorkMacSetup' "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string local.workmacsetup.app' "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleInfoDictionaryVersion string 6.0' "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleName string Work Mac Setup' "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleShortVersionString string 1.1.3' "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleVersion string 6' "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :LSMinimumSystemVersion string 13.0' "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :NSHighResolutionCapable bool true' "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :NSHumanReadableCopyright string Internal support utility' "$CONTENTS_DIR/Info.plist"
# The setup script asks the running app to show the login item drag palette
# through this URL scheme. It is not a privacy usage key and grants nothing.
/usr/libexec/PlistBuddy -c 'Add :CFBundleURLTypes array' "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleURLTypes:0:CFBundleURLName string local.workmacsetup.app.palette' "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleURLTypes:0:CFBundleURLSchemes array' "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string workmacsetup' "$CONTENTS_DIR/Info.plist"

# Nested executables are already signed (the Dock helper must retain its
# read-only entitlements). Sign only the outer bundle here.
/usr/bin/codesign --force --sign - "$APP_DIR"

/bin/rm -f -- "$ZIP_FILE"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_FILE"

/usr/bin/printf 'Built: %s\n' "$APP_DIR"
/usr/bin/printf 'Packaged: %s\n' "$ZIP_FILE"
/usr/bin/file "$MACOS_DIR/WorkMacSetup"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_DIR"
