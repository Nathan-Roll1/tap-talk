#!/bin/bash
set -euo pipefail
python3 -m venv /tmp/tap-hf
/tmp/tap-hf/bin/pip -q install 'huggingface-hub>=0.34,<2'
export HF_HOME=/tmp/tap-hf-cache
folder="$HOME/Library/Application Support/talk.tap.app/models"
mkdir -p "$folder/Fourier" "$folder/Orukeet/packages"
GGUF=$(/tmp/tap-hf/bin/python -c "from huggingface_hub import hf_hub_download; print(hf_hub_download('oruk/oruk-fourier-2b','Fourier-2B-Q8_0.gguf',revision='8bcce21695e4ba13569c48de6cedffcb8a7576f5'))")
ORU=$(/tmp/tap-hf/bin/python -c "from huggingface_hub import hf_hub_download; print(hf_hub_download('oruk/orukeet','coreml/orukeet-r3-coreml-greedy.zip',revision='43142dd1897f9ddadcd70173fcb5ff45c08aa951'))")
printf '%s  %s\n' 6a7c419bd571f7b0e21da2d5ab1e3a1a3938a83470d622be57427af98f322981 "$GGUF" beccdc6f18c4b10527a764f6e3ab12e3e11b969220c0cee175b3bb7eaa94290e "$ORU" | shasum -a 256 -c
ln "$(realpath "$GGUF")" "$folder/Fourier/Fourier-2B-Q8_0.gguf"
mkdir /tmp/tap-orukeet
unzip -q "$ORU" -d /tmp/tap-orukeet
mv /tmp/tap-orukeet/orukeet-r3-coreml-greedy/* "$folder/Orukeet/packages/"
ls "$folder/Orukeet/packages"
