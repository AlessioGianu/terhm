#!/usr/bin/env bash
# terhm tests with a fake server (no model needed).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT=$((20000 + RANDOM % 10000))
export TERHM_PORT=$PORT TERHM_HOME=/nonexistent XDG_CONFIG_HOME=/nonexistent
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
check "strips fence" "bash" "$("$TERHM" ask "fence")"
check "strips backticks" "ls -la" "$("$TERHM" ask "wrapped")"
check "strips leading \$" "ls -la" "$("$TERHM" ask "dollar")"

"$TERHM" ask "empty" >/dev/null 2>&1; check "empty output -> exit 1" "1" "$?"
"$TERHM" ask "   " >/dev/null 2>&1; check "empty request -> exit 2" "2" "$?"

# chat format: system prompt + user request
"$TERHM" ask "hello" >/dev/null
check "chat endpoint: system" "system" "$(log '.messages[0].role')"
check "chat endpoint: request" "hello" "$(log '.messages[1].content')"
check "default temperature 0" "0" "$(log .temperature)"
check "repeat penalty" "1.08" "$(log .repeat_penalty)"
check "stop on newline" '["\n"]' "$(log -c .stop)"

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

echo; echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
