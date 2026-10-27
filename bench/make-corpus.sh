#!/bin/bash
# Synthesizes bench/corpus/NN.wav (16 kHz mono) from phrases.txt with French macOS voices.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p corpus
voices=("Thomas" "Amélie" "Jacques")
i=0
while IFS= read -r phrase; do
  i=$((i + 1))
  say -v "${voices[$(( (i - 1) % ${#voices[@]} ))]}" --file-format=WAVE --data-format=LEI16@16000 \
    -o "corpus/$(printf %02d "$i").wav" "$phrase" </dev/null
done < phrases.txt
echo "$i files in $(pwd)/corpus"
