# terhm - plugin bash (readline). Default hotkey: Ctrl+G.
# Note: inside functions called from "bind -x" do NOT use $(<file): in bash 5.2 it
# corrupts the parser buffer and the next line is executed incorrectly.
[[ $- == *i* ]] || return 0
: "${TERHM_KEY:=\\C-g}"
: "${TERHM_AUTOFIX:=1}"        # if the proposed command fails, propose a fix right away
: "${TERHM_AUTOFIX_MAX:=3}"    # max automatic fixes in a row
_terhm_orig=""; _terhm_out=""; _terhm_fix=""; _terhm_tries=0; _terhm_hn=""; TERHM_LAST_STATUS=0

_terhm_last_cmd() { HISTTIMEFORMAT='' history 1 | sed 's/^[[:space:]]*[0-9]*[[:space:]]*//'; }
_terhm_known() { compgen -A function -a -b -k | sort -u | tr '\n' ' '; }

# After a command: if it was the one proposed by terhm and it failed, ask the model
# for a fix right away and put it on the next command line (it is not executed).
_terhm_pc() {
  TERHM_LAST_STATUS=$?
  local hn last fix tty
  _terhm_fix=""
  hn=$(HISTTIMEFORMAT='' history 1 | awk '{print $1}')
  [[ $hn == "$_terhm_hn" ]] && return 0            # empty Enter: no new command
  _terhm_hn=$hn
  [[ -n $_terhm_out ]] || return 0
  last=$(_terhm_last_cmd)
  if [[ $last != "$_terhm_out" ]]; then _terhm_tries=0; return 0; fi
  if (( TERHM_LAST_STATUS == 0 || TERHM_LAST_STATUS >= 128 )); then _terhm_tries=0; return 0; fi  # success, or Ctrl+C
  [[ $TERHM_AUTOFIX == 1 ]] && (( _terhm_tries < TERHM_AUTOFIX_MAX )) || return 0
  _terhm_tries=$((_terhm_tries + 1))
  printf '\e[2mterhm: command failed (exit %s), looking for a fix…\e[0m' "$TERHM_LAST_STATUS" >&2
  fix=$(TERHM_SHELL=bash TERHM_KNOWN="$(_terhm_known)" \
        TERHM_HISTORY="$(HISTTIMEFORMAT='' history 5 | sed 's/^[[:space:]]*[0-9]*[[:space:]]*//' | paste -sd';' -)" \
        command terhm fix --status "$TERHM_LAST_STATUS" --request "$_terhm_orig" -- "$last" 2>/dev/null)
  printf '\r\e[K' >&2
  [[ -n $fix ]] || return 0
  _terhm_out="$fix"; _terhm_fix="$fix"
  # Writing into the readline buffer needs a keypress: ask the terminal for its
  # status (DSR, \e[5n); the \e[0n reply arrives as input and calls _terhm_inject.
  # Echo is off while waiting, so the reply does not show up on screen.
  tty=$(stty -g </dev/tty 2>/dev/null) || return 0
  stty -echo -icanon min 0 time 0 </dev/tty 2>/dev/null
  printf '\e[5n' >/dev/tty
  for _ in 1 2 3 4 5 6 7 8 9 10; do read -t 0 </dev/tty && break; sleep 0.02; done
  stty "$tty" </dev/tty 2>/dev/null
}
if [[ $(declare -p PROMPT_COMMAND 2>/dev/null) == "declare -a"* ]]; then
  [[ " ${PROMPT_COMMAND[*]} " == *" _terhm_pc "* ]] || PROMPT_COMMAND=(_terhm_pc "${PROMPT_COMMAND[@]}")
else
  # shellcheck disable=SC2178,SC2128
  case ";${PROMPT_COMMAND-};" in
    *";_terhm_pc;"*) ;;
    *) PROMPT_COMMAND="_terhm_pc${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
  esac
fi

# Redraws the request line: $1 = prompt, $2 = cursor position in REPLY.
_terhm_draw() {
  local w=$(( ${COLUMNS:-80} - ${#1} - 1 )) s=0 vis
  (( w < 10 )) && w=10
  (( $2 > w )) && s=$(( $2 - w ))                     # long line: scroll horizontally
  vis=${REPLY:s:w}
  printf '\r\e[K%s%s' "$1" "$vis" >&2
  (( ${#vis} > $2 - s )) && printf '\e[%dD' $(( ${#vis} - $2 + s )) >&2
  return 0
}

# Small line editor (read -e and canonical-mode read do not work well inside bind -x):
# arrows, Home/End, Delete, Ctrl+A/E/B/F/D/K/U/W, Alt+B/F, bracketed paste.
# Result in REPLY; exit 1 if cancelled (Ctrl+C, Esc).
_terhm_read() {
  local c seq tty pos=0 p paste=0 ok=1 sp=$' \t'
  REPLY=""
  tty=$(stty -g </dev/tty 2>/dev/null)
  stty -icanon -echo -isig min 1 time 0 </dev/tty 2>/dev/null
  printf '%s' "$1" >&2
  while IFS= read -rsn1 c </dev/tty; do
    if [[ $c == $'\e' ]]; then
      # escape sequence: CSI/SS3 up to the final byte (\e[D, \e[3~, \e[200~...)
      seq=""
      if IFS= read -rsn1 -t 0.05 c </dev/tty; then
        seq=$c
        if [[ $c == '[' || $c == O ]]; then
          while IFS= read -rsn1 -t 0.05 c </dev/tty; do
            seq+=$c; [[ $c == [@-~] ]] && break
          done
        fi
      fi
      case $seq in
        "") (( paste )) && continue                     # Esc alone cancels
            printf '\n' >&2; REPLY=""; ok=0; break ;;
        '[200~') paste=1; continue ;;
        '[201~') paste=0 ;;
        '[D'|OD) (( pos > 0 )) && pos=$((pos - 1)) ;;
        '[C'|OC) (( pos < ${#REPLY} )) && pos=$((pos + 1)) ;;
        '[H'|OH|'[1~'|'[7~') pos=0 ;;
        '[F'|OF|'[4~'|'[8~') pos=${#REPLY} ;;
        '[3~') REPLY=${REPLY:0:pos}${REPLY:pos+1} ;;
        '[1;5D'|'[1;3D'|b|B)                            # word left
          while (( pos > 0 )) && [[ $sp == *"${REPLY:pos-1:1}"* ]]; do pos=$((pos - 1)); done
          while (( pos > 0 )) && [[ $sp != *"${REPLY:pos-1:1}"* ]]; do pos=$((pos - 1)); done ;;
        '[1;5C'|'[1;3C'|f|F)                            # word right
          while (( pos < ${#REPLY} )) && [[ $sp == *"${REPLY:pos:1}"* ]]; do pos=$((pos + 1)); done
          while (( pos < ${#REPLY} )) && [[ $sp != *"${REPLY:pos:1}"* ]]; do pos=$((pos + 1)); done ;;
        *) continue ;;                                  # up/down, F keys...: ignored
      esac
      _terhm_draw "$1" "$pos"; continue
    fi
    if (( paste )); then                                # pasted text: newlines become spaces
      [[ $c == $'\r' || $c == $'\n' || $c == $'\t' || $c == "" ]] && c=" "
      [[ $c == [[:cntrl:]] ]] || { REPLY=${REPLY:0:pos}$c${REPLY:pos}; pos=$((pos + 1)); }
      continue
    fi
    case $c in
      ""|$'\r'|$'\n') printf '\n' >&2; break ;;
      $'\x03') printf '^C\n' >&2; REPLY=""; ok=0; break ;;
      $'\x7f'|$'\b') (( pos > 0 )) && { REPLY=${REPLY:0:pos-1}${REPLY:pos}; pos=$((pos - 1)); } ;;
      $'\x04') REPLY=${REPLY:0:pos}${REPLY:pos+1} ;;     # Ctrl+D
      $'\x01') pos=0 ;;                                  # Ctrl+A
      $'\x05') pos=${#REPLY} ;;                          # Ctrl+E
      $'\x02') (( pos > 0 )) && pos=$((pos - 1)) ;;      # Ctrl+B
      $'\x06') (( pos < ${#REPLY} )) && pos=$((pos + 1)) ;;  # Ctrl+F
      $'\x0b') REPLY=${REPLY:0:pos} ;;                   # Ctrl+K
      $'\x15') REPLY=${REPLY:pos}; pos=0 ;;              # Ctrl+U
      $'\x17') p=$pos                                    # Ctrl+W
        while (( p > 0 )) && [[ $sp == *"${REPLY:p-1:1}"* ]]; do p=$((p - 1)); done
        while (( p > 0 )) && [[ $sp != *"${REPLY:p-1:1}"* ]]; do p=$((p - 1)); done
        REPLY=${REPLY:0:p}${REPLY:pos}; pos=$p ;;
      [[:cntrl:]]) continue ;;
      *) REPLY=${REPLY:0:pos}$c${REPLY:pos}; pos=$((pos + 1)) ;;
    esac
    _terhm_draw "$1" "$pos"
  done
  [[ -n $tty ]] && stty "$tty" </dev/tty 2>/dev/null
  (( ok ))
}

_terhm_set() { # puts the command on the line, warning if it is dangerous
  READLINE_LINE="$1"; READLINE_POINT=${#READLINE_LINE}
  if command terhm danger -- "$1"; then
    printf '\r\e[K⚠ terhm: potentially dangerous command, check it before pressing Enter\n' >&2
  fi
}

_terhm_inject() {
  [[ -n $_terhm_fix && -z $READLINE_LINE ]] || return 0
  _terhm_set "$_terhm_fix"; _terhm_fix=""
}

_terhm_suggest() {
  local req="$READLINE_LINE" alt=0 out rc msg hist="" st=0 errf hint="" last="" fix=0
  # No new request on the line (empty, or the command just proposed): ask for the
  # request. Empty Enter = alternative / fix for the failed command.
  if [[ -z "${READLINE_LINE//[[:space:]]/}" || ( -n $_terhm_out && $READLINE_LINE == "$_terhm_out" ) ]]; then
    if [[ -n $_terhm_fix && -z "${READLINE_LINE//[[:space:]]/}" ]]; then
      _terhm_set "$_terhm_fix"; _terhm_fix=""; return 0  # automatic fix not inserted yet
    fi
    if [[ -n $_terhm_out && $READLINE_LINE == "$_terhm_out" ]]; then
      hint="empty Enter = alternative"
    elif (( TERHM_LAST_STATUS != 0 )); then
      hint="empty Enter = fix the last failed command"
    fi
    printf '\r\e[K' >&2
    [[ -n $hint ]] && printf '\e[2m(%s)\e[0m\n' "$hint" >&2
    _terhm_read "terhm › " || return 0                  # Ctrl+C / Esc: cancel
    req="$REPLY"
    if [[ -n "${req//[[:space:]]/}" ]]; then
      :                                                  # new request
    elif [[ -n $_terhm_out && $READLINE_LINE == "$_terhm_out" ]]; then
      req="$_terhm_orig"; alt=1
    elif (( TERHM_LAST_STATUS != 0 )); then
      fix=1; last=$(_terhm_last_cmd)
      # history and exit code only when fixing a failed command: otherwise the small
      # model tends to copy recent commands instead of reading the request
      hist=$(HISTTIMEFORMAT='' history 5 | sed 's/^[[:space:]]*[0-9]*[[:space:]]*//' | paste -sd';' -)
      st=$TERHM_LAST_STATUS
    else
      return 0
    fi
  fi
  errf=$(mktemp "${TMPDIR:-/tmp}/terhm.XXXXXX")
  printf '\r\e[K\e[2mterhm: thinking…\e[0m' >&2   # readline redraws the line afterwards
  if (( fix )); then
    [[ $last == "$_terhm_out" ]] && req="$_terhm_orig" || req=""
    out=$(TERHM_SHELL=bash TERHM_KNOWN="$(_terhm_known)" TERHM_HISTORY="$hist" \
          command terhm fix --status "$st" --request "$req" -- "$last" 2>"$errf")
  else
    out=$(TERHM_SHELL=bash TERHM_KNOWN="$(_terhm_known)" TERHM_ALT=$alt TERHM_PREV="$_terhm_out" \
          command terhm ask "$req" 2>"$errf")
  fi
  rc=$?
  msg=""; IFS= read -r -d '' msg <"$errf"; rm -f "$errf"; msg="${msg%$'\n'}"
  printf '\r\e[K' >&2
  if (( rc != 0 )) || [[ -z $out ]]; then
    printf '%s\n' "${msg:-terhm: no response}" >&2; return 0
  fi
  (( alt || fix )) || _terhm_orig="$req"
  _terhm_out="$out"; _terhm_tries=0
  _terhm_set "$out"
}
bind -x "\"$TERHM_KEY\": _terhm_suggest"
bind -x '"\e[0n": _terhm_inject'
