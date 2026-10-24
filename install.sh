#!/usr/bin/env bash
# terhm installer: Gemini API key (online model) and, optionally, the offline backup model
# (nl2sh-1.5b on llama-server, systemd service) + shell plugins.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/terhm"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/terhm"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
PORT="${TERHM_PORT:-11500}"
LLAMA_BIN=""; LOCAL_MODEL=""; YES=0; NO_RC=0; NO_SERVICE=0; SKIP_MODEL=0; UPDATE_LLAMA=0
OFFLINE=""; GEMINI_KEY="${GEMINI_API_KEY:-}"; NO_KEY=0
KEY_FILE="$CONF_DIR/gemini.key"
GEMINI_URL="${TERHM_GEMINI_URL:-https://generativelanguage.googleapis.com/v1beta/openai}"
GEMINI_MODEL="${TERHM_GEMINI_MODEL:-gemini-3.5-flash-lite}"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m  %s\n' "$*" >&2; exit 1; }
ask()  { [ "$YES" = 1 ] && return 0; local a; read -r -p "$1 [Y/n] " a || return 1; [[ ! $a =~ ^[nN] ]]; }

usage() {
  cat <<USAGE
Usage: ./install.sh [options]
  --yes                  do not ask for confirmation (key from GEMINI_API_KEY or --gemini-key)
  --gemini-key KEY       Gemini API key (online model); or the GEMINI_API_KEY variable
  --no-gemini            do not use Gemini (offline model only)
  --offline              install the offline backup model nl2sh-1.5b (~1 GB) without asking
  --no-offline           do not install the offline model (Gemini only)
  --llama-server PATH    offline model: use an existing llama-server
  --model-file PATH      offline model: use an already downloaded GGUF
  --skip-model           offline model: do not download it
  --no-shell-rc          do not modify .bashrc/.zshrc/fish
  --no-service           do not install the systemd service
  --update-llama         download the latest llama.cpp even if one is already installed
Variables: GEMINI_API_KEY, TERHM_GEMINI_MODEL, TERHM_PORT, TERHM_MODEL_URL, TERHM_MODEL_REPO,
           TERHM_MODEL_FILE, TERHM_MODEL_SHA256
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) YES=1 ;;
    --gemini-key) GEMINI_KEY="${2:?missing key}"; shift ;;
    --no-gemini) NO_KEY=1 ;;
    --offline) OFFLINE=1 ;;
    --no-offline) OFFLINE=0 ;;
    --llama-server) LLAMA_BIN="${2:?missing path}"; shift; OFFLINE=1 ;;
    --model-file) LOCAL_MODEL="${2:?missing path}"; shift; OFFLINE=1 ;;
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

# --- 0. online model: Gemini API key ---------------------------------------
# Checks a key without spending tokens: 0 = valid, 1 = rejected, 2 = no connection.
check_key() {
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
    -H @<(printf 'Authorization: Bearer %s\n' "$1") "$GEMINI_URL/models/$GEMINI_MODEL" 2>/dev/null) || code=000
  case "$code" in
    200) return 0 ;;
    000) return 2 ;;
    404) warn "the key works but the model $GEMINI_MODEL was not found (set TERHM_GEMINI_MODEL)"; return 0 ;;
    *) return 1 ;;
  esac
}
save_key() {
  ( umask 077; printf '%s\n' "$1" > "$KEY_FILE" )
  info "Gemini API key saved in $KEY_FILE (readable only by you)"
}

HAVE_KEY=0
if [ "$NO_KEY" = 1 ]; then
  info "Gemini skipped (--no-gemini)"
elif [ -n "$GEMINI_KEY" ]; then
  rc=0; check_key "$GEMINI_KEY" || rc=$?
  [ "$rc" = 1 ] && die "the Gemini API key was rejected"
  [ "$rc" = 2 ] && warn "could not reach Gemini to check the key: saved anyway"
  save_key "$GEMINI_KEY"; HAVE_KEY=1
elif [ -s "$KEY_FILE" ] && { [ "$YES" = 1 ] || ask "A Gemini API key is already configured. Keep it?"; }; then
  info "Keeping the Gemini API key in $KEY_FILE"; HAVE_KEY=1
elif [ "$YES" = 0 ] && [ -t 0 ]; then
  cat <<TXT

terhm uses Gemini ($GEMINI_MODEL) to turn your requests into commands.
Create a free API key at https://aistudio.google.com/apikey and paste it here
(the text is hidden; leave it empty to skip and use only the offline model).
TXT
  for _ in 1 2 3; do
    read -r -s -p "Gemini API key: " GEMINI_KEY || GEMINI_KEY=""; echo
    GEMINI_KEY="${GEMINI_KEY//[[:space:]]/}"
    [ -n "$GEMINI_KEY" ] || break
    rc=0; check_key "$GEMINI_KEY" || rc=$?
    if [ "$rc" = 0 ]; then info "Key valid"; save_key "$GEMINI_KEY"; HAVE_KEY=1; break; fi
    if [ "$rc" = 2 ]; then warn "could not reach Gemini to check the key (no internet?): saved anyway"; save_key "$GEMINI_KEY"; HAVE_KEY=1; break; fi
    warn "key rejected by Gemini, try again"
    GEMINI_KEY=""
  done
fi
# the old key was declined and no new one given (or --no-gemini): remove it
if [ "$HAVE_KEY" = 0 ] && [ -f "$KEY_FILE" ] && { [ "$NO_KEY" = 1 ] || { [ "$YES" = 0 ] && [ -t 0 ]; }; }; then
  rm -f "$KEY_FILE"
fi

# --- 1. offline backup model: yes or no ------------------------------------
MODEL_NAME="nl2sh-1.5b"
OLD_OFFLINE=$(sed -n 's/^TERHM_OFFLINE=\([01]\).*/\1/p' "$CONF_DIR/config" 2>/dev/null | tail -n1 || true)
if [ -z "$OFFLINE" ]; then
  if [ "$HAVE_KEY" = 0 ]; then
    info "No Gemini API key: terhm will use the offline model $MODEL_NAME"
    OFFLINE=1
  elif [ "$YES" = 1 ]; then
    OFFLINE="${OLD_OFFLINE:-1}"
  else
    cat <<TXT

Offline backup model: $MODEL_NAME (~1 GB download, ~1.5 GB of RAM, runs on the CPU).
It answers when Gemini cannot be reached (no internet, quota exceeded...).
TXT
    if ask "Install the offline backup model?"; then OFFLINE=1; else OFFLINE=0; fi
  fi
fi
if [ "$OFFLINE" = 0 ] && [ "$HAVE_KEY" = 0 ]; then
  die "nothing to use: give a Gemini API key or install the offline model"
fi

if [ "$OFFLINE" = 1 ]; then
DEF_REPO="ThorOdinson246/nl2sh-1.5b-Q4_K_M"; DEF_FILE="nl2sh-1.5b-Q4_K_M.gguf"
DEF_SHA="6f8a17a11129a31074c944f4c2602453fafd9de43bdaeb1630a8f511ec820f71"
MODEL_SIZE="~1 GB"; MODEL_RAM_MB=1500; SERVER_EXTRA=""
MODEL_REPO="${TERHM_MODEL_REPO:-$DEF_REPO}"
MODEL_FILE="${TERHM_MODEL_FILE:-$DEF_FILE}"
MODEL_URL="${TERHM_MODEL_URL:-https://huggingface.co/${MODEL_REPO}/resolve/main/${MODEL_FILE}}"
# checksum of the default file; a different model is not verified unless TERHM_MODEL_SHA256 is set
if [ -z "${TERHM_MODEL_URL:-}${TERHM_MODEL_REPO:-}${TERHM_MODEL_FILE:-}" ]; then
  MODEL_SHA256="${TERHM_MODEL_SHA256:-$DEF_SHA}"
else
  MODEL_SHA256="${TERHM_MODEL_SHA256:-}"
fi
info "Offline model: $MODEL_NAME ($MODEL_FILE)"
avail_mb=$(awk '/^MemAvailable:/ {print int($2 / 1024)}' /proc/meminfo 2>/dev/null || echo 0)
if [ "${avail_mb:-0}" -gt 0 ] && [ "$avail_mb" -lt "$MODEL_RAM_MB" ]; then
  warn "only ${avail_mb} MB of RAM available, $MODEL_NAME needs about ${MODEL_RAM_MB} MB"
fi

# --- 2. llama-server ------------------------------------------------------
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

# --- 3. model -------------------------------------------------------------
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
# the default checksum only applies to the downloaded model, not to --model-file
if [ -n "$LOCAL_MODEL" ] && [ -z "${TERHM_MODEL_SHA256:-}" ]; then MODEL_SHA256=""; fi
if [ -n "$MODEL_SHA256" ] && [ -s "$MODEL_PATH" ]; then
  echo "$MODEL_SHA256  $MODEL_PATH" | sha256sum -c - >/dev/null || die "wrong model checksum"
  info "Model checksum verified"
fi
fi  # offline model

# model of older versions, no longer used
old_model="$DATA_DIR/Qwen3.5-4B-Q4_K_M.gguf"
if [ -f "$old_model" ]; then
  if ask "Delete the old Qwen3.5-4B model (~2.7 GB, no longer used)?"; then rm -f "$old_model"; fi
fi
if [ "$OFFLINE" = 0 ] && [ -f "$DATA_DIR/nl2sh-1.5b-Q4_K_M.gguf" ]; then
  if ask "Delete the offline model files (~1 GB, not used any more)?"; then
    rm -f "$DATA_DIR/nl2sh-1.5b-Q4_K_M.gguf"; rm -rf "$DATA_DIR/llama"
  fi
fi

# --- 4. project files -----------------------------------------------------
install -m 0755 "$REPO_DIR/bin/terhm" "$BIN_DIR/terhm"
install -m 0644 "$REPO_DIR"/shell/terhm.* "$DATA_DIR/shell/"
install -m 0644 "$REPO_DIR/prompts/system.txt" "$DATA_DIR/prompts/"
rm -f "$DATA_DIR/prompts/hints.txt"   # older versions
[ -f "$CONF_DIR/config" ] || install -m 0644 "$REPO_DIR/config/terhm.conf" "$CONF_DIR/config"
# settings of older versions (model choice, Qwen reasoning), then whether the offline model is there
sed -i -e '/^# model chosen at install time/d' -e '/^TERHM_MODEL=/d' -e '/^TERHM_THINK/d' -e '/^TERHM_NO_THINK=/d' \
       -e '/^TERHM_OFFLINE=/d' "$CONF_DIR/config"
echo "TERHM_OFFLINE=$OFFLINE   # set by install.sh: 1 = offline backup model installed" >> "$CONF_DIR/config"
if [ "$GEMINI_MODEL" != gemini-3.5-flash-lite ]; then
  sed -i '/^TERHM_GEMINI_MODEL=/d' "$CONF_DIR/config"; echo "TERHM_GEMINI_MODEL=$GEMINI_MODEL" >> "$CONF_DIR/config"
fi
[ "$PORT" = 11500 ] || { grep -q '^TERHM_PORT=' "$CONF_DIR/config" || echo "TERHM_PORT=$PORT" >> "$CONF_DIR/config"; }
case ":$PATH:" in *":$BIN_DIR:"*) ;; *) warn "$BIN_DIR is not in PATH: add it in your rc file" ;; esac

# --- 5. systemd service for the offline model (start at boot) --------------
if [ "$OFFLINE" = 0 ]; then
  if [ -f "$UNIT_DIR/terhm.service" ]; then
    systemctl --user disable --now terhm.service 2>/dev/null || true
    rm -f "$UNIT_DIR/terhm.service"; systemctl --user daemon-reload 2>/dev/null || true
    info "Offline model service removed"
  fi
elif [ "$NO_SERVICE" = 0 ]; then
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
    info "Service running. Waiting for the offline model to load…"
    ready=0
    for _ in $(seq 1 120); do
      curl -fs "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && { ready=1; info "Server ready"; break; }
      sleep 1
    done
    if [ "$ready" = 0 ]; then
      warn "the server did not answer yet. Logs: journalctl --user -u terhm -e"
    fi
  else
    warn "user systemd not available: skipping the service (use --no-service to hide this warning)"
  fi
fi

# --- 6. shell integration -------------------------------------------------
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

if [ "$HAVE_KEY" = 1 ] && [ "$OFFLINE" = 1 ]; then info "Mode: online (Gemini $GEMINI_MODEL), offline backup $MODEL_NAME"
elif [ "$HAVE_KEY" = 1 ]; then info "Mode: online only (Gemini $GEMINI_MODEL)"
else info "Mode: offline only ($MODEL_NAME)"; fi
info "Done. Open a new terminal, type a request and press Ctrl+G."
info "Diagnostics: terhm doctor"
