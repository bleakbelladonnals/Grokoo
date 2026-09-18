#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
EVIDENCE="$ROOT/evidence/validation"
DERIVED="$ROOT/.derived"
mkdir -p "$EVIDENCE"

cd "$ROOT"

action_count=$(jq '.actions | length' Grokoo/Resources/animation-manifest.json)
mbti_count=$(jq '.presets | length' Grokoo/Resources/mbti-presets.json)
decoration_count=$(jq '[.presets[].decorationId | select(. != null)] | length' Grokoo/Resources/mbti-presets.json)

[[ "$action_count" == 17 ]]
[[ "$mbti_count" == 16 ]]
[[ "$decoration_count" == 4 ]]

jq -e '.version == 2 and ([.actions[] | has("driver") and has("state") and has("surfaces") and has("durationRangeSeconds") and has("loop") and has("preservesShape") and has("fallback")] | all)' Grokoo/Resources/animation-manifest.json >/dev/null
jq -e '.version == 1 and (.presets | length == 16)' Grokoo/Resources/mbti-presets.json >/dev/null

xcodegen generate

xcodebuild \
  -project Grokoo.xcodeproj \
  -scheme Grokoo \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  build | tee "$EVIDENCE/xcodebuild-debug.log"

xcodebuild \
  -project Grokoo.xcodeproj \
  -scheme Grokoo \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO test | tee "$EVIDENCE/xcodebuild-test.log"

xcodebuild \
  -project Grokoo.xcodeproj \
  -scheme Grokoo \
  -configuration Release \
  ONLY_ACTIVE_ARCH=NO \
  ARCHS="arm64 x86_64" \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  build | tee "$EVIDENCE/xcodebuild-release.log"

RELEASE_APP="$DERIVED/Build/Products/Release/Grokoo.app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$RELEASE_APP/Contents/Info.plist")" == "1.1" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$RELEASE_APP/Contents/Info.plist")" == "12" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$RELEASE_APP/Contents/Info.plist")" == "true" ]]
/usr/bin/lipo "$RELEASE_APP/Contents/MacOS/Grokoo" -verify_arch arm64 x86_64
/usr/bin/codesign --verify --deep --strict "$RELEASE_APP"
DOCK_HELPER="$RELEASE_APP/Contents/Helpers/GrokooDockItem.app"
/usr/bin/lipo "$DOCK_HELPER/Contents/MacOS/GrokooDockItem" -verify_arch arm64 x86_64
/usr/bin/codesign --verify --strict "$DOCK_HELPER"

xcodebuild -project Grokoo.xcodeproj -scheme Grokoo -configuration Release -showBuildSettings > "$EVIDENCE/build-settings-release.txt"
rg '^\s*ENABLE_APP_SANDBOX = NO$' "$EVIDENCE/build-settings-release.txt" >/dev/null
if rg '^\s*(DEVELOPMENT_TEAM|CODE_SIGN_IDENTITY) = (Apple Development|Developer ID)' "$EVIDENCE/build-settings-release.txt" >/dev/null; then
  print -u2 'Public distribution signing detected.'
  exit 1
fi

if rg -n --glob '*.swift' '\b(prompt|responseBody|messageBody|transcriptBody)\b' Grokoo/Presence Grokoo/Rendering Grokoo/Motion Grokoo/Workstation Grokoo/Personality Grokoo/Dock GrokooDockItem > "$EVIDENCE/privacy-source-scan.txt"; then
  print -u2 'Forbidden正文字段 entered Presence/rendering pipeline.'
  exit 1
fi

if rg -n --glob '*.swift' '\b(WKWebView|SpriteKit|SceneKit|SKPhysicsBody)\b' Grokoo GrokooDockItem > "$EVIDENCE/forbidden-architecture-scan.txt"; then
  print -u2 'Forbidden web/physics architecture detected.'
  exit 1
fi

if rg --pcre2 -n --glob '*.swift' --glob '*.json' --glob '*.svg' '\p{Extended_Pictographic}' Grokoo/Rendering Grokoo/Resources > "$EVIDENCE/emoji-resource-scan.txt"; then
  print -u2 'Emoji detected in runtime visual resources.'
  exit 1
fi

{
  /usr/bin/file "$RELEASE_APP/Contents/MacOS/Grokoo"
  /usr/bin/du -sh "$RELEASE_APP"
  /usr/bin/codesign -dv --verbose=4 "$RELEASE_APP" 2>&1 \
    | rg 'Identifier|Signature|TeamIdentifier'
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$RELEASE_APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$RELEASE_APP/Contents/Info.plist"
} > "$EVIDENCE/release-product.txt"

{
  print "shape_count=$(rg -o 'case (blob|pebble|squircle|tablet|wedge|hex|cloud|teardrop)' Grokoo/Rendering/OfficialAppearance.swift | wc -l | tr -d ' ')"
  print "official_color_count=$(rg -o 'case (black|brown|red|orange|yellow|green|cyan|blue|violet|magenta|gray)' Grokoo/Rendering/OfficialAppearance.swift | wc -l | tr -d ' ')"
  print "decoration_asset_count=$(find Grokoo/Resources/MBTIDecorations -name '*.svg' | wc -l | tr -d ' ')"
  print "app_icon_png_count=$(find Grokoo/Resources/Assets.xcassets/AppIcon.appiconset -name '*.png' | wc -l | tr -d ' ')"
  print "menu_template_svg_count=$(find Grokoo/Resources -maxdepth 1 -name 'MenuBarIconSource.svg' | wc -l | tr -d ' ')"
} > "$EVIDENCE/resource-counts.txt"

find Grokoo GrokooDockItem GrokooTests ThirdParty project.yml scripts README.md THIRD_PARTY_NOTICES.md -type f -not -path '*/xcuserdata/*' -print0 \
  | sort -z \
  | xargs -0 shasum -a 256 > "$EVIDENCE/final-source-sha256.txt"

git status --short --branch > "$EVIDENCE/git-status.txt"

{
  print "actions=$action_count"
  print "mbti=$mbti_count"
  print "decorations=$decoration_count"
  print "debug=PASS"
  print "tests=PASS"
  print "release=PASS"
} > "$EVIDENCE/summary.txt"

print "Grokoo verification completed. Evidence: $EVIDENCE"
