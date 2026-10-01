#!/usr/bin/env bash
# Speed benchmark: Apple SpeechTranscriber (./transcribe) vs. mlx_whisper and
# whisper.cpp, each with a tiny and a large model.
#
# usage: ./benchmark.sh [audio-file]   (default: mlk.wav)
set -euo pipefail

cd "$(dirname "$0")"

AUDIO=${1:-mlk.wav}
MODELS_DIR=models
OUT_DIR=$(mktemp -d)
trap 'rm -rf "$OUT_DIR"' EXIT

# whisper.cpp ggml file name -> mlx-community repo name
TINY=tiny
LARGE=large-v3-turbo

echo "==> installing tools"
python3 -m pip install --quiet mlx-whisper
brew list whisper.cpp &>/dev/null || brew install whisper.cpp
brew list hyperfine &>/dev/null || brew install hyperfine
brew list llimllib/tap/transcribe &>/dev/null || brew install llimllib/tap/transcribe

echo "==> fetching models"
mkdir -p "$MODELS_DIR"
for m in "$TINY" "$LARGE"; do
    f="$MODELS_DIR/ggml-$m.bin"
    if [[ ! -f "$f" ]]; then
        curl -fL --progress-bar -o "$f.part" \
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$m.bin"
        mv "$f.part" "$f"
    fi
    python3 -c "from huggingface_hub import snapshot_download; snapshot_download('mlx-community/whisper-$m')"
done

mlx() {
    echo "mlx_whisper --model mlx-community/whisper-$1 --verbose False -o '$OUT_DIR' '$AUDIO'"
}
cpp() {
    echo "whisper-cli -np -m '$MODELS_DIR/ggml-$1.bin' -f '$AUDIO'"
}

echo "==> benchmarking $AUDIO"
hyperfine --warmup 1 \
    --export-markdown benchmark.md \
    -n "apple transcribe" "transcribe '$AUDIO'" \
    -n "mlx_whisper $TINY" "$(mlx "$TINY")" \
    -n "mlx_whisper $LARGE" "$(mlx "$LARGE")" \
    -n "whisper.cpp $TINY" "$(cpp "$TINY")" \
    -n "whisper.cpp $LARGE" "$(cpp "$LARGE")"
