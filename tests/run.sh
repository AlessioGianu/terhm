#!/usr/bin/env bash
# terhm tests with a fake server (no model needed).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT=$((20000 + RANDOM % 10000))
export TERHM_PORT=$PORT TERHM_HOME=/nonexistent XDG_CONFIG_HOME=/nonexistent
# Gemini is the mock too; without a key (the default here) only the offline model is used
export TERHM_GEMINI_URL="http://127.0.0.1:$PORT/gemini" TERHM_GEMINI_MODEL=gemini-test
unset GEMINI_API_KEY TERHM_GEMINI_KEY TERHM_MODE TERHM_OFFLINE
export MOCK_LOG; MOCK_LOG=$(mktemp)
TERHM="$ROOT/bin/terhm"
pass=0; fail=0

python3 "$ROOT/tests/mock_server.py" "$PORT" & SRV=$!
trap 'kill $SRV 2>/dev/null; rm -f "$MOCK_LOG"' EXIT
for _ in $(seq 1 50); do curl -fs "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break; sleep 0.1; done

check() { # name, expected, actual
  if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   - $1"
  else fail=$((fail+1)); echo "FAIL - $1"; echo "       expected: $2"; echo "       actual:   $3"; fi
}
# jq reads from stdin: the snap jq cannot see the host's /tmp
log() { jq -r "$@" < "$MOCK_LOG"; }
sys_prompt() { log '.messages[0].content'; }

check "simple ask" "find . -type f -size +100M -exec ls -lh {} +" "$("$TERHM" ask "find files bigger than 100MB")"
"$TERHM" ask "fence" >/dev/null 2>&1; check "fence line only -> no command" "1" "$?"
check "command inside a fenced block" "ls -la" "$("$TERHM" ask "multifence")"
check "strips think block" "git status" "$("$TERHM" ask "think")"
check "strips backticks" "ls -la" "$("$TERHM" ask "wrapped")"
check "strips leading \$" "ls -la" "$("$TERHM" ask "dollar")"

"$TERHM" ask "empty" >/dev/null 2>&1; check "empty output -> exit 1" "1" "$?"
"$TERHM" ask "   " >/dev/null 2>&1; check "empty request -> exit 2" "2" "$?"

# chat format: system prompt + user request
"$TERHM" ask "hello" >/dev/null
check "chat endpoint: system" "system" "$(log '.messages[0].role')"
check "chat endpoint: request" "hello" "$(log '.messages[1].content')"
check "default temperature 0" "0" "$(log .temperature)"
check "offline: endpoint" "/v1/chat/completions" "$(log ._path)"
check "offline: nl2sh repeat penalty" "1.08" "$(log .repeat_penalty)"
check "offline: nl2sh top_k" "40" "$(log .top_k)"
check "offline: one line" '["\n"]' "$(log -c .stop)"

# context: directory, git branch, exit code, history
T=$(mktemp -d); (cd "$T" && git init -q -b trunk . && touch alpha.txt beta.txt)
(cd "$T" && TERHM_LAST_STATUS=127 TERHM_HISTORY="cd x; nmp i" "$TERHM" ask "hello" >/dev/null)
for needle in "cwd: $T" "git branch: trunk" "alpha.txt" "last exit code: 127" "recent commands: cd x; nmp i"; do
  sys_prompt | grep -qF -- "$needle"; check "context contains: $needle" "0" "$?"
done
rm -rf "$T"
T=$(mktemp -d); mkdir -p "$T/Downloads" "$T/.hidden"; touch "$T/.a" "$T/z.txt"
(cd "$T" && "$TERHM" ask "hello" >/dev/null)
sys_prompt | grep -qF "files: Downloads/ z.txt .a .hidden/"; check "context: directories, files, hidden" "0" "$?"
rm -rf "$T"

# project and session context
T=$(mktemp -d)
mkdir -p "$T/ws/src/bot/bot" "$T/ws/src/bot/launch" "$T/ws/install" "$T/app/.venv/bin"
touch "$T/ws/install/setup.bash" "$T/ws/src/bot/launch/bringup.launch.py" "$T/app/.venv/bin/activate" "$T/app/uv.lock" "$T/app/pyproject.toml"
printf '<package><name>bot</name><export><build_type>ament_python</build_type></export></package>\n' > "$T/ws/src/bot/package.xml"
printf "entry_points={'console_scripts': ['talker = bot.talker:main']}\n" > "$T/ws/src/bot/setup.py"
printf '.PHONY: build\nbuild: deps\n\tcc x.c\ntest:\n\t./t\nVAR := 1\n' > "$T/ws/Makefile"
printf 'services:\n  db:\n    image: postgres\n  web:\n    build: .\nvolumes:\n  data:\n' > "$T/ws/compose.yaml"
printf '{"scripts":{"dev":"vite"}}' > "$T/ws/package.json"; touch "$T/ws/pnpm-lock.yaml"
(cd "$T/ws" && ROS_DISTRO=jazzy "$TERHM" ask "hello" >/dev/null)
for needle in "make: Makefile, targets: build test" "docker compose: compose.yaml, services: db web" \
              "package manager pnpm, scripts: dev" "packages: bot (ament_python: talker)" \
              "built (install/setup.bash exists), not sourced" "ros2 launch files: bringup.launch.py" \
              "ROS 2 jazzy sourced"; do
  sys_prompt | grep -qF -- "$needle"; check "project context: $needle" "0" "$?"
done
(cd "$T/ws/src/bot/bot" && "$TERHM" context) | grep -qF "ros2 package: bot (ament_python) in .., executables: talker"
check "ros2 package from a subdirectory" "0" "$?"
(cd "$T/app" && VIRTUAL_ENV="$T/app/.venv" "$TERHM" context) | grep -qF "tool uv, virtualenv .venv/"
check "python project with uv and virtualenv" "0" "$?"
(cd "$T/app" && VIRTUAL_ENV="$T/app/.venv" "$TERHM" context) | grep -qF "python virtualenv active"
check "active virtualenv in the session" "0" "$?"
(cd "$T/ws" && TERHM_PROJECT_CONTEXT=0 TERHM_TOOLS_CONTEXT=0 "$TERHM" context) | grep -qE "^(make|installed tools):"
check "project and tools context can be turned off" "1" "$?"
rm -rf "$T"
"$TERHM" context | grep -q "^installed tools: .*git\|^installed tools: .*jq"; check "installed tools listed" "0" "$?"

# online (Gemini) and fallback to the offline model
G="env TERHM_GEMINI_KEY=goodkey $TERHM"
check "online: answer" "find . -type f -size +100M -exec ls -lh {} +" "$($G ask "find files bigger than 100MB" 2>/dev/null)"
check "online: endpoint" "/gemini/chat/completions" "$(log ._path)"
check "online: model" "gemini-test" "$(log .model)"
check "online: minimal reasoning for the first answer" "minimal" "$(log .reasoning_effort)"
check "online: system prompt sent" "system" "$(log '.messages[0].role')"
TERHM_ALT=1 TERHM_PREV="ls" $G ask "hello" >/dev/null
check "online: alternative reasons a little" "low" "$(log .reasoning_effort)"
$G fix --status 2 -- "ls /nope" >/dev/null
check "online: fix reasons a little" "low" "$(log .reasoning_effort)"
check "online: key from file" "/gemini/chat/completions" \
  "$(K=$(mktemp); echo goodkey > "$K"; TERHM_GEMINI_KEY_FILE="$K" "$TERHM" ask hello >/dev/null; rm -f "$K"; log ._path)"
check "online: GEMINI_API_KEY works too" "/gemini/chat/completions" "$(GEMINI_API_KEY=goodkey "$TERHM" ask hello >/dev/null; log ._path)"
err=$(TERHM_GEMINI_KEY=badkey "$TERHM" ask hello 2>&1 >/dev/null)
check "bad key -> offline model used" "/v1/chat/completions" "$(log ._path)"
check "bad key -> says why" "0" "$(grep -qF 'offline model used (Gemini: API key or model rejected' <<< "$err"; echo $?)"
TERHM_GEMINI_MODEL=down $G ask hello >/dev/null 2>&1
check "Gemini error 503 -> offline model" "/v1/chat/completions" "$(log ._path)"
err=$(TERHM_GEMINI_URL=http://127.0.0.1:1 $G ask hello 2>&1 >/dev/null)
check "no internet -> offline model" "0" "$(grep -qF 'Gemini: not reachable' <<< "$err"; echo $?)"
TERHM_GEMINI_URL=http://127.0.0.1:1 TERHM_OFFLINE=0 $G ask hello >/dev/null 2>&1
check "no internet, no offline model -> exit 1" "1" "$?"
err=$(TERHM_GEMINI_URL=http://127.0.0.1:1 TERHM_OFFLINE=0 $G ask hello 2>&1)
check "no internet, no offline model -> says to install it" "0" "$(grep -qF 'no offline model installed' <<< "$err"; echo $?)"
TERHM_MODE=offline $G ask hello >/dev/null
check "TERHM_MODE=offline skips Gemini" "/v1/chat/completions" "$(log ._path)"
TERHM_MODE=online TERHM_GEMINI_URL=http://127.0.0.1:1 $G ask hello >/dev/null 2>&1
check "TERHM_MODE=online: no fallback" "1" "$?"
TERHM_OFFLINE=0 "$TERHM" ask hello >/dev/null 2>&1; check "nothing configured -> exit 1" "1" "$?"
check "mode: online" "online · gemini-test" "$($G mode)"
check "mode: offline" "offline · nl2sh-1.5b" "$("$TERHM" mode)"
check "status: online ok even with the offline model down" "0" "$(TERHM_PORT=1 $G status; echo $?)"
check "status: bad key and offline down" "1" "$(TERHM_PORT=1 TERHM_GEMINI_KEY=badkey "$TERHM" status; echo $?)"
$G doctor >/dev/null; check "doctor ok" "0" "$?"
$G doctor | grep -qF "[ok]   online: Gemini gemini-test, API key valid"; check "doctor: key checked" "0" "$?"
TERHM_GEMINI_KEY=badkey "$TERHM" doctor | grep -qF "API key rejected"; check "doctor: bad key" "0" "$?"
check "json: quotes, backslashes, newlines, tabs, control chars" '"a\"b\\c\nd\te"' \
  "$(printf '%s' 'source "$TERHM"' >/dev/null; bash -c '. <(sed -n "/^json_str()/,/^}/p" "$1"); json_str "$(printf "a\"b\\\\c\nd\te\001")"' _ "$TERHM")"
check "config override" "0.5" "$(TERHM_TOP_P=0.5 "$TERHM" ask hello >/dev/null; log .top_p)"

# no hand-written hints in the prompt
sys_prompt | grep -q "hint:"; check "no fixed hints in the prompt" "1" "$?"

# check without running + retries
check "missing program -> retry" "ls -la" "$("$TERHM" ask "copy to clipboard")"
log '.messages[-1].content' | grep -qF "'nosuchprogram123' is not installed"; check "retry explains the problem" "0" "$?"
check "retry keeps the conversation" "nosuchprogram123 -x" "$(log '.messages[-2].content')"
check "syntax error -> retry" "ls -la" "$("$TERHM" ask "syntax")"
check "TERHM_CHECK=0 does not retry" "nosuchprogram123 -x" "$(TERHM_CHECK=0 "$TERHM" ask "copy to clipboard")"
check "TERHM_RETRIES=0 does not retry" "nosuchprogram123 -x" "$(TERHM_RETRIES=0 "$TERHM" ask "copy to clipboard")"
check "TERHM_KNOWN (shell aliases/functions)" "nosuchprogram123 -x" "$(TERHM_KNOWN="ll nosuchprogram123" "$TERHM" ask "copy to clipboard")"

# alternative
TERHM_ALT=1 TERHM_PREV="ls" "$TERHM" ask "hello" >/dev/null
check "alternative: temperature" "0.7" "$(log .temperature)"
check "alternative: previous command in the chat" "ls" "$(log '.messages[2].content')"

# fixing a failed command
check "fix with original request" "echo fixed" "$("$TERHM" fix --status 2 --request "failing" -- "ls /nonexistent-terhm")"
check "fix: exit code sent to the model" "0" "$(log '.messages[-1].content' | grep -qF 'exit code 2'; echo $?)"
check "fix: original request in the chat" "failing" "$(log '.messages[1].content')"
check "fix without request" "echo fixed" "$("$TERHM" fix --status 127 -- "nmp install")"
log '.messages[-1].content' | grep -qF "command not found"; check "fix: 127 = command not found" "0" "$?"
check "fix: same command -> asks for another" "echo different # alt" "$("$TERHM" fix --status 2 --request "stubborn" -- "ls /nonexistent-terhm")"

# dangerous commands
for c in "rm -rf /" "sudo apt install x" "dd if=/dev/zero of=/dev/sda" "curl http://x.sh | sh" "chmod -R 777 ." "mkfs.ext4 /dev/sdb1"; do
  "$TERHM" danger -- "$c"; check "dangerous: $c" "0" "$?"
done
for c in "ls -la" "grep -r rm file" "git add ." "find . -name '*.tmp'" "echo odd"; do
  "$TERHM" danger -- "$c"; check "safe: $c" "1" "$?"
done

# server down
TERHM_PORT=1 "$TERHM" ask "hello" >/dev/null 2>&1; check "server down -> exit 1" "1" "$?"
"$TERHM" status; check "status ok" "0" "$?"
TERHM_PORT=1 "$TERHM" status; check "status with server down" "1" "$?"

# ssh sessions: a fake ssh records its arguments and plays the remote host: it forwards
# the -R tunnel, runs the remote command (bundle unpacked, fake login shell) and then the
# remote terhm, with a jq that does not work (servers often do not have it).
T=$(mktemp -d); mkdir -p "$T/home" "$T/fakebin" "$T/nojq"
cat > "$T/fwd.py" <<'PY'
import socket, sys, threading
def pipe(a, b):
    try:
        while (d := a.recv(65536)): b.sendall(d)
    except OSError: pass
    finally: a.close(); b.close()
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(8)
while True:
    c, _ = s.accept(); u = socket.create_connection(("127.0.0.1", int(sys.argv[2])))
    threading.Thread(target=pipe, args=(c, u), daemon=True).start()
    threading.Thread(target=pipe, args=(u, c), daemon=True).start()
PY
cat > "$T/ssh" <<SH
#!/bin/bash
for a in "\$@"; do printf '%s\n' "\$a"; done > "$T/args"
[ "\$1" = -t ] || exit 0
r=\${3%%:*}; l=\${3##*:}
python3 "$T/fwd.py" "\$r" "\$l" & f=\$!; sleep 0.3
HOME="$T/home" SHELL="$T/fakebin/bash" XDG_CACHE_HOME="" sh -c "\${@: -1}" 2>"$T/remote_err"
D=\$(sed -n 's/^TERHM_HOME=//p' "$T/shell_env")
cd "$T/home"
env -i PATH="$T/nojq:\$PATH" HOME="$T/home" TERHM_HOME="\$D" TERHM_CONFIG="\$D/config" TERHM_SSH_PORT=\$r \
  "\$D/bin/terhm" \${TEST_REMOTE_CMD:-ask "find files bigger than 100MB"} > "$T/remote_out" 2>"$T/remote_cmd_err"
kill \$f
SH
# fake login shell named bash: records how it was started instead of opening a prompt
printf '#!/bin/sh\necho "$@" > "%s/shell_args"; env > "%s/shell_env"\n' "$T" "$T" > "$T/fakebin/bash"
printf '#!/bin/sh\nexit 127\n' > "$T/nojq/jq"
chmod +x "$T/ssh" "$T/fakebin/bash" "$T/nojq/jq"
RP=$((PORT + 1))
TERHM_SSH_BIN="$T/ssh" TERHM_SSH_REMOTE_PORT=$RP "$TERHM" ssh -vp 2200 -o X=y myhost 2>/dev/null
check "ssh: tty and reverse tunnel to the proxy" "-t|-R|$RP:127.0.0.1:" "$(head -3 "$T/args" | paste -sd'|' - | sed 's/[0-9]*$//')"
check "ssh: user options kept, host last" "-vp|2200|-o|X=y|myhost" "$(sed -n 4,8p "$T/args" | paste -sd'|' -)"
check "ssh remote: tunnel check ok" "0" "$(grep -qF 'uses the model on your local machine (offline · nl2sh-1.5b)' "$T/remote_err"; echo $?)"
check "ssh remote: no jq needed" "1|" "$(grep -q 'missing' "$T/remote_err"; echo $?)|$(cat "$T/remote_cmd_err")"
check "ssh remote: bash started with the plugin rcfile" "0" "$(grep -qE -- '--rcfile .*/terhm/ssh/[^/]+/bashrc -i' "$T/shell_args"; echo $?)"
D=$(sed -n 's/^TERHM_HOME=//p' "$T/shell_env")
ok=1; [ -x "$D/bin/terhm" ] && [ -f "$D/shell/terhm.bash" ] && [ -f "$D/prompts/system.txt" ] && [ -f "$D/zsh/.zshrc" ] && ok=0
check "ssh remote: bundle unpacked" "0" "$ok"
check "ssh remote: answer through the tunnel, without jq" "find . -type f -size +100M -exec ls -lh {} +" "$(cat "$T/remote_out")"
sys_prompt | grep -qF "cwd: $T/home"; check "ssh remote: context is the remote one" "0" "$?"
# online: the key stays here, the remote gets the answer of Gemini
K="$T/key"; echo goodkey > "$K"
TERHM_GEMINI_KEY_FILE="$K" TERHM_SSH_BIN="$T/ssh" TERHM_SSH_REMOTE_PORT=$RP "$TERHM" ssh myhost 2>/dev/null
check "ssh online: answer from Gemini" "find . -type f -size +100M -exec ls -lh {} +|/gemini/chat/completions" "$(cat "$T/remote_out")|$(log ._path)"
check "ssh online: mode shown on the remote" "0" "$(grep -qF '(online · gemini-test)' "$T/remote_err"; echo $?)"
check "ssh online: API key not sent to the remote" "1" "$(grep -rqF goodkey "$D" "$T/args"; echo $?)"
TERHM_GEMINI_KEY=badkey TEST_REMOTE_CMD="ask hello" TERHM_SSH_BIN="$T/ssh" TERHM_SSH_REMOTE_PORT=$RP "$TERHM" ssh myhost 2>/dev/null
check "ssh: Gemini fails -> offline model, note on the remote" "ls|0" \
  "$(cat "$T/remote_out")|$(grep -qF 'offline model used (Gemini: API key or model rejected' "$T/remote_cmd_err"; echo $?)"
TERHM_OFFLINE=0 TEST_REMOTE_CMD="ask hello" TERHM_SSH_BIN="$T/ssh" TERHM_SSH_REMOTE_PORT=$RP "$TERHM" ssh myhost 2>/dev/null
check "ssh: no model -> error shown on the remote" "0" "$(grep -qF 'no model configured' "$T/remote_cmd_err"; echo $?)"
TERHM_SSH_BIN="$T/ssh" "$TERHM" ssh myhost uptime
check "ssh: remote command -> plain ssh" "myhost|uptime" "$(paste -sd'|' - < "$T/args")"
TERHM_SSH_BIN="$T/ssh" "$TERHM" ssh -N -L 1:a:2 myhost
check "ssh: -N -> plain ssh" "-N|-L|1:a:2|myhost" "$(paste -sd'|' - < "$T/args")"
# tunnel down: the remote command run with nothing listening on the port
TERHM_SSH_BIN="$T/ssh" TERHM_SSH_REMOTE_PORT=$RP "$TERHM" ssh myhost 2>/dev/null
HOME="$T/home" SHELL="$T/fakebin/bash" XDG_CACHE_HOME="" sh -c "$(tail -n1 "$T/args")" 2>"$T/remote_err"
check "ssh remote: tunnel down -> warning, shell still starts" "0|0" \
  "$(grep -qF 'cannot reach your machine' "$T/remote_err"; echo $?)|$(grep -qF -- '--rcfile' "$T/shell_args"; echo $?)"
sleep 2.5; check "ssh: proxy stopped with the session" "0" "$(pgrep -a -x python3 | grep -c ThreadingHTTPServer)"
rm -rf "$T"

echo; echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
