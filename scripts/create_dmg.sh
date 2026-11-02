#!/bin/bash
set -euo pipefail

# Builds an unsigned, local-release DMG suitable for attaching to a GitHub Release.
# Users will need to approve the app once in System Settings because it is not notarized.

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project_path="$project_root/stopat.xcodeproj"
scheme="stopat"
build_root="$project_root/build/release"
staging_root="$build_root/staging"
release_root="$project_root/release"

if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "Xcode is required. Install Xcode, then run this script again." >&2
    exit 1
fi

# Prefer the standard full Xcode installation when the caller has not selected one.
if [[ -z "${DEVELOPER_DIR:-}" && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

# Version discovery should never prevent a local DMG from being produced; use a safe fallback
# if Xcode cannot report build settings on a particular machine.
version="$(xcodebuild -project "$project_path" -scheme "$scheme" -configuration Release -showBuildSettings 2>/dev/null | awk -F ' = ' '/^[[:space:]]*MARKETING_VERSION =/ { print $2; exit }' || true)"
if [[ -z "$version" ]]; then
    version="0.1.0"
fi

rm -rf "$build_root"
mkdir -p "$staging_root" "$release_root"

xcodebuild \
    -project "$project_path" \
    -scheme "$scheme" \
    -configuration Release \
    -sdk macosx \
    -derivedDataPath "$build_root/derived-data" \
    CODE_SIGNING_ALLOWED=NO \
    build

app_path="$build_root/derived-data/Build/Products/Release/stopat.app"
if [[ ! -d "$app_path" ]]; then
    echo "Build succeeded but stopat.app was not found at: $app_path" >&2
    exit 1
fi

cp -R "$app_path" "$staging_root/stopat.app"
ln -s /Applications "$staging_root/Applications"

dmg_path="$release_root/stopat-v${version}.dmg"
rm -f "$dmg_path"
hdiutil create \
    -volname "stopat" \
    -srcfolder "$staging_root" \
    -format UDZO \
    -ov \
    "$dmg_path"

echo "Created $dmg_path"
