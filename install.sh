
#!/usr/bin/env bash
# terhm installer: llama-server + GGUF model (Qwen3.5-4B) + systemd service + shell plugins.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/terhm"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/terhm"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
PORT="${TERHM_PORT:-11500}"
LLAMA_BIN=""; LOCAL_MODEL=""; YES=0; NO_RC=0; NO_SERVICE=0; SKIP_MODEL=0; UPDATE_LLAMA=0

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m  %s\n' "$*" >&2; exit 1; }
ask()  { [ "$YES" = 1 ] && return 0; local a; read -r -p "$1 [Y/n] " a || return 1; [[ ! $a =~ ^[nN] ]]; }

usage() {
  cat <<USAGE
Usage: ./install.sh [options]
  --yes                  do not ask for confirmation
  --llama-server PATH    use an existing llama-server
  --model-file PATH      use an already downloaded GGUF
  --skip-model           do not download the model
  --no-shell-rc          do not modify .bashrc/.zshrc/fish
  --no-service           do not install the systemd service
  --update-llama         download the latest llama.cpp even if one is already installed
Variables: TERHM_PORT, TERHM_MODEL_URL, TERHM_MODEL_REPO, TERHM_MODEL_FILE, TERHM_MODEL_SHA256
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) YES=1 ;;
    --llama-server) LLAMA_BIN="${2:?missing path}"; shift ;;
    --model-file) LOCAL_MODEL="${2:?missing path}"; shift ;;
    --update-llama) UPDATE_LLAMA=1 ;;
    --skip-model) SKIP_MODEL=1 ;;
    --no-shell-rc) NO_RC=1 ;;
    --no-service) NO_SERVICE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown option: $1" ;;
  esac
  shift
done

[ "$(uname -s)" = Linux ] || die "terhm only supports Linux"
for c in curl jq tar; do command -v "$c" >/dev/null || die "missing dependency: $c (install it with your package manager)"; done

mkdir -p "$BIN_DIR" "$DATA_DIR/shell" "$DATA_DIR/prompts" "$CONF_DIR"

# --- 0. model ------------------------------------------------------------
MODEL_NAME="Qwen3.5-4B"
DEF_REPO="unsloth/Qwen3.5-4B-GGUF"; DEF_FILE="Qwen3.5-4B-Q4_K_M.gguf"
DEF_SHA="00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4"
# --jinja: use the model's chat template, needed to turn thinking off per request
MODEL_SIZE="~2.7 GB"; MODEL_RAM_MB=4000; SERVER_EXTRA="--jinja"
MODEL_REPO="${TERHM_MODEL_REPO:-$DEF_REPO}"
MODEL_FILE="${TERHM_MODEL_FILE:-$DEF_FILE}"
MODEL_URL="${TERHM_MODEL_URL:-https://huggingface.co/${MODEL_REPO}/resolve/main/${MODEL_FILE}}"
# checksum of the default file; a different model is not verified unless TERHM_MODEL_SHA256 is set
if [ -z "${TERHM_MODEL_URL:-}${TERHM_MODEL_REPO:-}${TERHM_MODEL_FILE:-}" ]; then
  MODEL_SHA256="${TERHM_MODEL_SHA256:-$DEF_SHA}"
else
  MODEL_SHA256="${TERHM_MODEL_SHA256:-}"
fi
info "Model: $MODEL_NAME ($MODEL_FILE)"
avail_mb=$(awk '/^MemAvailable:/ {print int($2 / 1024)}' /proc/meminfo 2>/dev/null || echo 0)
if [ "${avail_mb:-0}" -gt 0 ] && [ "$avail_mb" -lt "$MODEL_RAM_MB" ]; then
  warn "only ${avail_mb} MB of RAM available, $MODEL_NAME needs about ${MODEL_RAM_MB} MB"
fi

# --- 1. llama-server ------------------------------------------------------
download_llama() {
  local arch tag url tmp found
  case "$(uname -m)" in
    x86_64) arch=x64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) die "architecture not supported by the automatic download: use --llama-server" ;;
  esac
  info "Looking for the latest llama.cpp binary release…"
  # the newest release whose binaries are uploaded already (a release appears on GitHub
  # before its files, which take a while to build)
  url=$(curl -fsSL "https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=10" 2>/dev/null \
    | jq -r --arg a "bin-ubuntu-$arch.tar.gz" \
        '[.[] | .assets[] | select(.name | endswith($a) and startswith("llama-")) | .browser_download_url][0] // empty' 2>/dev/null || true)
  if [ -z "$url" ]; then
    # API unavailable (rate limit...): the release page, checking that the file exists
    # (|| true: with pipefail a failed curl/grep would end the script silently)
    for tag in $( { curl -fsSL "https://github.com/ggml-org/llama.cpp/releases" | grep -oE 'releases/tag/b[0-9]+' | sed 's#.*/##' | awk '!s[$0]++' | head -n5; } 2>/dev/null || true); do
      url="https://github.com/ggml-org/llama.cpp/releases/download/$tag/llama-$tag-bin-ubuntu-$arch.tar.gz"
      curl -fsIL -o /dev/null "$url" && break
      url=""
    done
  fi
  [ -n "$url" ] || die "could not find the llama.cpp release (use --llama-server)"
  tag=$(printf '%s' "$url" | grep -oE '/download/b[0-9]+/' | tr -d /); tag=${tag#download}
  tmp=$(mktemp -d)
  info "Downloading llama.cpp $tag ($arch)…"
  curl -fL --progress-bar -o "$tmp/llama.tgz" "$url" || die "download failed: $url"
  rm -rf "$DATA_DIR/llama"; mkdir -p "$DATA_DIR/llama"
  tar -xzf "$tmp/llama.tgz" -C "$DATA_DIR/llama"
  rm -rf "$tmp"
  found=$(find "$DATA_DIR/llama" -type f -name llama-server | head -n1)
  [ -n "$found" ] || die "llama-server not found in the archive"
  LLAMA_BIN="$found"
}

if [ -z "$LLAMA_BIN" ] && [ "$UPDATE_LLAMA" = 1 ]; then download_llama; fi
if [ -z "$LLAMA_BIN" ]; then
  existing=$(find "$DATA_DIR/llama" -type f -name llama-server 2>/dev/null | head -n1 || true)
  if [ -n "$existing" ]; then LLAMA_BIN="$existing"
  elif command -v llama-server >/dev/null; then LLAMA_BIN="$(command -v llama-server)"
  else download_llama; fi
fi
[ -x "$LLAMA_BIN" ] || die "llama-server is not executable: $LLAMA_BIN"
LLAMA_BIN="$(readlink -f "$LLAMA_BIN")"
info "llama-server: $LLAMA_BIN"

# --- 2. model -------------------------------------------------------------
MODEL_PATH="$DATA_DIR/$MODEL_FILE"
if [ -n "$LOCAL_MODEL" ]; then
  [ -r "$LOCAL_MODEL" ] || die "model not readable: $LOCAL_MODEL"
  MODEL_PATH="$(readlink -f "$LOCAL_MODEL")"
elif [ "$SKIP_MODEL" = 1 ]; then
  warn "Model skipped: remember to put the GGUF at $MODEL_PATH"
elif [ ! -s "$MODEL_PATH" ]; then
  info "Downloading the model ($MODEL_SIZE) from $MODEL_URL"
  curl -fL -C - --progress-bar -o "$MODEL_PATH.part" "$MODEL_URL" \
    || die "model download failed. Check the URL or use --model-file / TERHM_MODEL_URL"
  mv "$MODEL_PATH.part" "$MODEL_PATH"
fi
# model of older versions, no longer used
old_model="$DATA_DIR/nl2sh-1.5b-Q4_K_M.gguf"
if [ -f "$old_model" ] && [ "$MODEL_PATH" != "$(readlink -f "$old_model")" ]; then
  if ask "Delete the old nl2sh-1.5b model (~1 GB, no longer used)?"; then rm -f "$old_model"; fi
fi
# the default checksum only applies to the downloaded model, not to --model-file
if [ -n "$LOCAL_MODEL" ] && [ -z "${TERHM_MODEL_SHA256:-}" ]; then MODEL_SHA256=""; fi
if [ -n "$MODEL_SHA256" ] && [ -s "$MODEL_PATH" ]; then
  echo "$MODEL_SHA256  $MODEL_PATH" | sha256sum -c - >/dev/null || die "wrong model checksum"
  info "Model checksum verified"
fi

# --- 3. project files -----------------------------------------------------
install -m 0755 "$REPO_DIR/bin/terhm" "$BIN_DIR/terhm"
install -m 0644 "$REPO_DIR"/shell/terhm.* "$DATA_DIR/shell/"
install -m 0644 "$REPO_DIR/prompts/system.txt" "$DATA_DIR/prompts/"
rm -f "$DATA_DIR/prompts/hints.txt"   # older versions
[ -f "$CONF_DIR/config" ] || install -m 0644 "$REPO_DIR/config/terhm.conf" "$CONF_DIR/config"
# older versions wrote the chosen model (nl2sh or qwen3.5-4b) to the config: only Qwen3.5-4B now
sed -i -e '/^# model chosen at install time/d' -e '/^TERHM_MODEL=/d' "$CONF_DIR/config"
[ "$PORT" = 11500 ] || { grep -q '^TERHM_PORT=' "$CONF_DIR/config" || echo "TERHM_PORT=$PORT" >> "$CONF_DIR/config"; }
case ":$PATH:" in *":$BIN_DIR:"*) ;; *) warn "$BIN_DIR is not in PATH: add it in your rc file" ;; esac

# --- 4. systemd service (start at boot) -----------------------------------
if [ "$NO_SERVICE" = 0 ]; then
  if command -v systemctl >/dev/null && systemctl --user show-environment >/dev/null 2>&1; then
    mkdir -p "$UNIT_DIR"
    threads=$(( $(nproc) / 2 )); [ "$threads" -ge 2 ] || threads=2
    sed -e "s#@LLAMA_SERVER@#$LLAMA_BIN#" -e "s#@LLAMA_LIBDIR@#$(dirname "$LLAMA_BIN")#" \
        -e "s#@MODEL@#$MODEL_PATH#" -e "s#@PORT@#$PORT#" -e "s#@THREADS@#$threads#" \
        -e "s#@EXTRA@#$SERVER_EXTRA#" -e "s#@MODEL_NAME@#$MODEL_NAME#" \
        "$REPO_DIR/systemd/terhm.service.in" > "$UNIT_DIR/terhm.service"
    systemctl --user daemon-reload
    systemctl --user enable terhm.service
    systemctl --user restart terhm.service   # restart: picks up a model change on reinstall
    loginctl enable-linger "$USER" 2>/dev/null \
      || warn "to start at boot without logging in, run: sudo loginctl enable-linger $USER"
    info "Service running. Waiting for the model to load…"
    ready=0
    for _ in $(seq 1 120); do
      curl -fs "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && { ready=1; info "Server ready"; break; }
      sleep 1
    done
    if [ "$ready" = 0 ]; then
      warn "the server did not answer yet. Logs: journalctl --user -u terhm -e"
      warn "Qwen3.5 needs a recent llama.cpp: if the logs say 'unknown model architecture', rerun ./install.sh --update-llama"
    fi
  else
    warn "user systemd not available: skipping the service (use --no-service to hide this warning)"
  fi
fi

# --- 5. shell integration -------------------------------------------------
add_rc() { # file, source line
  local rc="$1" line="$2"
  mkdir -p "$(dirname "$rc")"; touch "$rc"
  if grep -qF "terhm/shell" "$rc"; then info "already configured: $rc"; return; fi
  printf '\n# terhm\n%s\n' "$line" >> "$rc"
  info "added to $rc"
}
if [ "$NO_RC" = 0 ]; then
  if command -v bash >/dev/null && [ -f "$HOME/.bashrc" ] && ask "Enable terhm in bash (~/.bashrc)?"; then
    add_rc "$HOME/.bashrc" "[ -f \"$DATA_DIR/shell/terhm.bash\" ] && source \"$DATA_DIR/shell/terhm.bash\""
  fi
  if command -v zsh >/dev/null && { [ -f "$HOME/.zshrc" ] || [ "$(basename "${SHELL:-}")" = zsh ]; } && ask "Enable terhm in zsh (~/.zshrc)?"; then
    add_rc "$HOME/.zshrc" "[ -f \"$DATA_DIR/shell/terhm.zsh\" ] && source \"$DATA_DIR/shell/terhm.zsh\""
  fi
  if command -v fish >/dev/null && ask "Enable terhm in fish?"; then
    add_rc "${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d/terhm.fish" "source \"$DATA_DIR/shell/terhm.fish\""
  fi
fi

info "Done. Open a new terminal, type a request and press Ctrl+G."
info "Diagnostics: terhm doctor"