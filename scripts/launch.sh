#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
if [[ ! -x "dist/Scene Deck.app/Contents/MacOS/SceneDeck" ]]; then ./scripts/build.sh; fi
open "$PWD/dist/Scene Deck.app"
