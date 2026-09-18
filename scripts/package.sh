#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
app_path="${1:-$project_root/.derived/Build/Products/Release/Grokoo.app}"
output_directory="${2:-$project_root/dist}"

[[ -d "$app_path" ]] || { print -u2 "Build the Release app first: ./scripts/verify.sh"; exit 1; }
/usr/bin/codesign --verify --deep --strict "$app_path"
/usr/bin/lipo "$app_path/Contents/MacOS/Grokoo" -verify_arch arm64 x86_64
/usr/bin/lipo "$app_path/Contents/Helpers/GrokooDockItem.app/Contents/MacOS/GrokooDockItem" -verify_arch arm64 x86_64

app_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")
app_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_path/Contents/Info.plist")
mkdir -p "$output_directory"
archive_path="$output_directory/Grokoo-$app_version-$app_build-macOS.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_path" "$archive_path"
(cd "$output_directory" && /usr/bin/shasum -a 256 "${archive_path:t}") > "$archive_path.sha256"
print "$archive_path"
