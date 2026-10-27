#!/bin/zsh
# Downloads Phonon, the on-device voice behind Read Page Aloud, into
# ThirdParty/Phonon (git-ignored: 51 MB of library and 163 MB of model).
#
#   scripts/fetch-phonon.sh
#
# Both archives come from Gradium's pinned GitHub release and are checked
# against the SHA-256 below before anything is unpacked. Licences: the code is
# MIT or Apache-2.0, Phonon 31m and its voices Apache-2.0. Only Phonon 31m may
# ship: the 40m models are CC BY-NC.
#
# Without these files the app still builds and Read Page Aloud uses Apple's
# voices. Phonon's core is arm64 only and its models need macOS 15, so Intel
# Macs and macOS 14 use Apple's voices too.
set -euo pipefail
cd "${0:A:h}/.."

VERSION=0.4.2
BASE=https://github.com/gradium-ai/xn-ptts/releases/download/v$VERSION
CORE_ZIP=PhononCore.xcframework.zip
CORE_SHA=d7a9dbda50e3696133a8a61d69c5c8ea85da19ec506a9de7f270333b73645efa
MODEL_ZIP=phonon-31m-en-coreml.zip
MODEL_SHA=10f3a99fd39256db44f826267ef21d78cca959b16c0554926344c09fde27b436
# Gradium's voice catalog (Apache 2.0) at the revision the model's voices
# came from (its source.json): names, languages and accents for Settings.
CATALOG=https://huggingface.co/gradium/phonon-voices/resolve/da6c9ec0d47be8df5c87c730a3aa97187f3229c3/voices.jsonl
CATALOG_SHA=874f34998ce581b94f2b8912aa015639f52b5fd62eba3ba11e1b64dcaed7d802

DEST=ThirdParty/Phonon
STAMP=$DEST/.fetched-$VERSION-2
if [[ -f $STAMP ]]; then
  echo "Phonon $VERSION is already in $DEST"
  exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fetch() {  # $1: file name, $2: expected SHA-256
  echo "Downloading $1"
  curl -fL --retry 3 -o "$WORK/$1" "$BASE/$1"
  local got=$(shasum -a 256 "$WORK/$1" | awk '{print $1}')
  if [[ $got != $2 ]]; then
    echo "!! $1 has SHA-256 $got, expected $2. Not using it." >&2
    exit 1
  fi
}

fetch $CORE_ZIP $CORE_SHA
fetch $MODEL_ZIP $MODEL_SHA
mkdir -p "$WORK/core" "$WORK/model"
ditto -x -k "$WORK/$CORE_ZIP" "$WORK/core"
ditto -x -k "$WORK/$MODEL_ZIP" "$WORK/model"

rm -rf "$DEST"
mkdir -p "$DEST/lib" "$DEST/include/PhononCore"
SLICE=$(find "$WORK/core" -type d -name macos-arm64 | head -1)
cp "$SLICE/libptts_ffi.a" "$DEST/lib/"
cp "$SLICE/Headers/ptts.h" "$DEST/include/PhononCore/"
# Gradium's module map plus link directives, so importing the module links the
# library and the frameworks it needs (only the arm64 slice ever imports it).
cat > "$DEST/include/PhononCore/module.modulemap" <<'EOF'
module PhononCore {
    header "ptts.h"
    link "ptts_ffi"
    link framework "CoreML"
    link framework "CoreVideo"
    link framework "Accelerate"
    export *
}
EOF
# Copied into the app as Resources/PhononModel by project.yml.
mv "$WORK/model/phonon-31m-en-coreml" "$DEST/PhononModel"
curl -fsSL -o "$WORK/voices.jsonl" "$CATALOG"
if [[ $(shasum -a 256 "$WORK/voices.jsonl" | awk '{print $1}') != $CATALOG_SHA ]]; then
  echo "!! The voice catalog does not match its SHA-256. Not using it." >&2
  exit 1
fi
mv "$WORK/voices.jsonl" "$DEST/PhononModel/"
for licence in LICENSE-MIT LICENSE-APACHE; do
  curl -fsSL -o "$DEST/PhononModel/$licence" "https://raw.githubusercontent.com/gradium-ai/xn-ptts/v$VERSION/$licence"
done
touch "$STAMP"
echo "Phonon $VERSION is in $DEST"
