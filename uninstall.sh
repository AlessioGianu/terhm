#!/usr/bin/env bash
# Removes terhm (service, binary, plugins). Asks before deleting the model.
set -uo pipefail
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/terhm"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/terhm"
UNIT="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/terhm.service"

systemctl --user disable --now terhm.service 2>/dev/null
rm -f "$UNIT"; systemctl --user daemon-reload 2>/dev/null
rm -f "$HOME/.local/bin/terhm"
for rc in "$HOME/.bashrc" "$HOME/.zshrc" "${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d/terhm.fish"; do
  [ -f "$rc" ] || continue
  sed -i '/^# terhm$/d;/terhm\/shell/d' "$rc"
done
read -r -p "Also delete the model and llama.cpp in $DATA_DIR (~1 GB)? [y/N] " a
if [[ ${a:-} =~ ^[yY] ]]; then rm -rf "$DATA_DIR"; else rm -rf "$DATA_DIR/shell" "$DATA_DIR/prompts"; fi
read -r -p "Delete the configuration in $CONF_DIR? [y/N] " a
[[ ${a:-} =~ ^[yY] ]] && rm -rf "$CONF_DIR"
echo "terhm removed."
