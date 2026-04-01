#!/usr/bin/env bash

echo " "
echo "Pulling Model"
echo " "

cd server/models

#curl -L --progress-bar -o model.gguf "https://huggingface.co/ibm-granite/granite-4.0-h-small-GGUF/resolve/main/granite-4.0-h-small-Q4_K_M.gguf"

curl -L --progress-bar -o model.gguf "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf"

# no wget on our network so pivoted
# wget -q --show-progress -O model.gguf "https://huggingface.co/TheBloke/Mistral-7B-Instruct-v0.2-GGUF/resolve/main/mistral-7b-instruct-v0.2.Q4_0.gguf"


# use the meta model llama4 scout, with 128 gigs of ram would be idea. 64 if we have to MIGHT work
