#!/bin/zsh
# Builds Icy Weasel for distribution.
#
#   scripts/release.sh direct      Developer ID build for the website and GitHub:
#                                  signed, notarized + stapled (if credentials
#                                  are saved), packaged as .dmg and .zip.
#   scripts/release.sh appstore    Mac App Store package (.pkg) for Transporter,
#                                  or uploaded directly when an App Store Connect
#                                  API key is configured (see below).
#   scripts/release.sh upload      Archive and upload to App Store Connect using
#                                  the Apple account signed in to Xcode.
#
# One-time setup, done by you (the script never handles passwords):
#   Notarization:  xcrun notarytool store-credentials icyweasel-notary \
#                    --apple-id <your Apple ID> --team-id ZY74XX7D42
#                  (asks for an app-specific password from appleid.apple.com)
#   App Store:     sign in to Xcode > Settings > Accounts with the team's Apple ID,
#                  so Xcode can create the distribution certificates and profile.
#   Direct upload (optional): export ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH
#                  for an App Store Connect API key with the App Manager role.
set -euo pipefail
cd "${0:A:h}/.."

TEAM=ZY74XX7D42
NOTARY_PROFILE=${NOTARY_PROFILE:-icyweasel-notary}
VERSION=$(awk -F'"' '/MARKETING_VERSION/ {print $2; exit}' project.yml)
OUT=build/release
ARCHIVE=$OUT/IcyWeasel.xcarchive
APP_NAME="Icy Weasel"

archive() {
  xcodegen generate >/dev/null
  rm -rf "$ARCHIVE"
  xcodebuild archive -project IcyWeasel.xcodeproj -scheme IcyWeasel -configuration Release \
    -archivePath "$ARCHIVE" -destination "generic/platform=macOS" \
    DEVELOPMENT_TEAM=$TEAM CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" \
    OTHER_CODE_SIGN_FLAGS=--timestamp | grep -E "error:|warning: .*sign|\*\* ARCHIVE" || true
  [[ -d "$ARCHIVE" ]] || { echo "Archive failed"; exit 1; }
}

notarize() {  # $1: file to submit
  if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
    return 0
  fi
  echo "!! Not notarized: no '$NOTARY_PROFILE' credentials saved (see setup at the top of this script)."
  return 1
}

direct() {
  archive
  local dest=$OUT/direct
  rm -rf "$dest"
  xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist scripts/ExportOptions-DeveloperID.plist -exportPath "$dest" | grep -E "error:|\*\* EXPORT" || true
  local app="$dest/$APP_NAME.app"
  codesign --verify --deep --strict "$app"
  local zip="$OUT/IcyWeasel-$VERSION.zip"
  ditto -c -k --keepParent "$app" "$zip"
  local notarized=0
  if notarize "$zip"; then
    xcrun stapler staple "$app" && notarized=1
    rm -f "$zip"; ditto -c -k --keepParent "$app" "$zip"   # re-zip with the ticket stapled
  fi

  # Drag-to-install disk image.
  local dmg="$OUT/IcyWeasel-$VERSION.dmg" stage="$OUT/dmg-stage"
  rm -rf "$stage" "$dmg"; mkdir -p "$stage"
  cp -R "$app" "$stage/"; ln -s /Applications "$stage/Applications"
  hdiutil create -volname "$APP_NAME" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg" >/dev/null
  rm -rf "$stage"
  codesign --sign "Developer ID Application" --timestamp "$dmg"
  if (( notarized )) && notarize "$dmg"; then xcrun stapler staple "$dmg"; fi

  # Unversioned copy: the website links releases/latest/download/IcyWeasel.dmg.
  cp "$dmg" "$OUT/IcyWeasel.dmg"
  (cd "$OUT" && shasum -a 256 "${dmg:t}" "${zip:t}" > SHA256SUMS.txt)
  echo "\nBuilt:"; ls -lh "$dmg" "$zip" "$OUT/SHA256SUMS.txt"
  spctl --assess --type execute -vv "$app" 2>&1 | head -3 || true
}

appstore() {
  archive
  local dest=$OUT/appstore
  rm -rf "$dest"
  local auth=()
  if [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" && -n "${ASC_KEY_PATH:-}" ]]; then
    auth=(-authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID" -authenticationKeyPath "$ASC_KEY_PATH")
  fi
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist scripts/ExportOptions-AppStore.plist \
    -exportPath "$dest" -allowProvisioningUpdates "${auth[@]}"
  echo "\nApp Store package:"; ls -lh "$dest"/*.pkg
  if (( ${#auth[@]} )); then
    xcrun altool --upload-package "$dest/$APP_NAME.pkg" --type macos \
      --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
  else
    echo "Upload it with Apple's Transporter app (drag the .pkg in), or set ASC_* and rerun."
  fi
}

upload() {
  archive
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist scripts/ExportOptions-AppStoreUpload.plist \
    -exportPath "$OUT/appstore-upload" -allowProvisioningUpdates 2>&1 | grep -vE "Progress [0-9]+%|^\s*$|IDEDistribution"
}

case "${1:-}" in
  direct)   direct ;;
  appstore) appstore ;;
  upload)   upload ;;
  *) echo "usage: scripts/release.sh direct|appstore|upload"; exit 2 ;;
esac
