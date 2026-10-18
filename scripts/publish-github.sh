#!/bin/zsh
# Builds the notarized Developer ID release and publishes it on GitHub.
# Refuses to publish anything Apple hasn't notarized: an un-notarized app is
# blocked by Gatekeeper on other Macs.
set -euo pipefail
cd "${0:A:h}/.."
VERSION=$(awk -F'"' '/MARKETING_VERSION/ {print $2; exit}' project.yml)
TAG="v$VERSION"
OUT=build/release

scripts/release.sh direct
xcrun stapler validate "$OUT/IcyWeasel.dmg" >/dev/null 2>&1 || {
  echo "The disk image is not notarized. Save notary credentials first (see scripts/release.sh)."; exit 1; }

NOTES=distribution/release-notes-$VERSION.md
if ! gh release view "$TAG" >/dev/null 2>&1; then
  # A draft made earlier has no tag yet; find it by title.
  DRAFT=$(gh release list --json tagName,name,isDraft --jq ".[] | select(.isDraft and .name == \"Icy Weasel ${VERSION%.0}\") | .tagName" | head -1)
  if [[ -n "$DRAFT" ]]; then gh release edit "$DRAFT" --tag "$TAG"; else
    gh release create "$TAG" --draft --title "Icy Weasel ${VERSION%.0}" --notes-file "$NOTES"; fi
fi
gh release upload "$TAG" --clobber "$OUT/IcyWeasel.dmg" "$OUT/IcyWeasel-$VERSION.dmg" "$OUT/IcyWeasel-$VERSION.zip" "$OUT/SHA256SUMS.txt"
gh release edit "$TAG" --draft=false --latest
echo "Published: $(gh release view "$TAG" --json url --jq .url)"
