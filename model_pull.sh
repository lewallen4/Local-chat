#!/usr/bin/env bash
echo " "
echo "Pulling Model"
echo " "

wget -q --show-progress -O model.gguf "https://huggingface.co/TheBloke/Mistral-7B-Instruct-v0.2-GGUF/resolve/main/mistral-7b-instruct-v0.2.Q4_0.gguf"