#!/bin/zsh
# Builds the optional Phonon 40m multilingual download that Settings offers
# (PhononModelDownload), as build/phonon/phonon-40m-multilingual-coreml.zip.
# Maintainers only: the zip is uploaded to the GitHub release named in
# PhononModelDownload, and its SHA-256 and size are pinned there.
#
#   scripts/export-phonon-multilingual.sh
#
# Needs Rust (brew install rust), uv, and a Hugging Face login whose account
# has accepted the model's terms at huggingface.co/gradium/phonon-40m-multilingual
# (uvx --from huggingface_hub hf auth login).
#
# Licence: Phonon 40m multilingual is CC BY-NC 4.0. It is never bundled in
# the app, may only be distributed non-commercially, and its licence and a
# note of the changes made (converted to Core ML, voices added) travel inside
# the zip. The voices (gradium/phonon-voices) and the runtime are Apache 2.0.
set -euo pipefail
cd "${0:A:h}/.."

VERSION=0.4.2
MODEL=hf://gradium/phonon-40m-multilingual
VOICES_REPO=gradium/phonon-voices
VOICES_REV=da6c9ec0d47be8df5c87c730a3aa97187f3229c3
WORK=build/phonon/work
OUT=build/phonon/phonon-40m-multilingual-coreml.zip

if [[ -z ${HF_TOKEN:-} ]]; then
  HF_TOKEN=$(uvx --from huggingface_hub python -c 'from huggingface_hub import get_token; print(get_token() or "")')
  export HF_TOKEN
fi
[[ -n $HF_TOKEN ]] || { echo "!! Log in to Hugging Face first: uvx --from huggingface_hub hf auth login"; exit 1; }

rm -rf "$WORK" && mkdir -p "$WORK"
git clone -q --depth 1 --branch "v$VERSION" https://github.com/gradium-ai/xn-ptts "$WORK/xn-ptts"

# The catalog's voices, named by their display names (the export names each
# voice after its file), plus the catalog itself for the app's voice menus.
mkdir -p "$WORK/voices"
curl -fsSL -o "$WORK/voices.jsonl" "https://huggingface.co/$VOICES_REPO/resolve/$VOICES_REV/voices.jsonl"
python3 -I - "$WORK" "$VOICES_REPO" "$VOICES_REV" <<'EOF'
import json, sys, urllib.request
work, repo, rev = sys.argv[1:]
for line in open(f"{work}/voices.jsonl", encoding="utf-8"):
    row = json.loads(line)
    url = f"https://huggingface.co/{repo}/resolve/{rev}/{row['filename']}"
    urllib.request.urlretrieve(url, f"{work}/voices/{row['name']}.safetensors")
EOF

(cd "$WORK/xn-ptts" && cargo run --release -q -p ptts --example export_coreml --features hub -- \
  --model "$MODEL" --voices "$PWD/../voices" "$PWD/../phonon-40m-multilingual")

BUNDLE=$WORK/phonon-40m-multilingual
cp "$WORK/voices.jsonl" "$BUNDLE/"
curl -fsSL -o "$BUNDLE/LICENSE-CC-BY-NC-4.0.txt" https://creativecommons.org/licenses/by-nc/4.0/legalcode.txt
cat > "$BUNDLE/NOTICE.txt" <<EOF
Phonon 40m multilingual by Gradium (https://gradium.ai/phonon), licensed under
CC BY-NC 4.0 (LICENSE-CC-BY-NC-4.0.txt): non-commercial use only.
Changes: converted to Core ML with Gradium's export_coreml (xn-ptts v$VERSION)
and given the voices of $VOICES_REPO@$VOICES_REV (Apache 2.0).
Distributed by Icy Weasel as an optional, separate download; it is not covered
by Icy Weasel's Mozilla Public License.
EOF

rm -f "$OUT"
OUT_ABS=$PWD/$OUT
(cd "$WORK" && ditto -c -k --keepParent phonon-40m-multilingual "$OUT_ABS")
echo "Wrote $OUT"
echo "size   $(stat -f %z "$OUT")"
echo "sha256 $(shasum -a 256 "$OUT" | awk '{print $1}')"
