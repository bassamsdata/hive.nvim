#!/usr/bin/env sh

# Usage: neovim-help.sh "<help-topic>"

TAG="$1"
if [ -z "$TAG" ]; then
  echo "Usage: neovim-help.sh <help-topic>"
  exit 1
fi

nvim --headless -u NONE \
  -c "help $TAG" \
  -c "let start = line('.')" \
  -c "normal! j" \
  -c "let end = search('\\*[^*]\\+\\*\\s*$', 'W')" \
  -c "if end == 0 | let end = line('$') | else | let end -= 1 | endif" \
  -c "execute start.','.end.'print'" \
  -c "qa"
