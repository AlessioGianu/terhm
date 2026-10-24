# terhm - plugin zsh. Default hotkey: Ctrl+G.
[[ -o interactive ]] || return 0
: "${TERHM_KEY:=^G}"
: "${TERHM_AUTOFIX:=1}"        # if the proposed command fails, propose a fix right away
: "${TERHM_AUTOFIX_MAX:=3}"    # max automatic fixes in a row
typeset -g _terhm_orig="" _terhm_out="" _terhm_hn=""
typeset -gi TERHM_LAST_STATUS=0 _terhm_tries=0

_terhm_known() { print -r -- ${(k)aliases} ${(k)functions} ${(k)builtins} ${(k)reswords}; }
_terhm_hist() { fc -ln -5 2>/dev/null | sed 's/^[[:space:]]*//' | paste -sd';' -; }

# After a command: if it was the one proposed by terhm and it failed, ask the model
# for a fix right away and put it on the next command line (it is not executed).
_terhm_precmd() {
  TERHM_LAST_STATUS=$?
  local hn last fix
  hn=${${=$(fc -l -1 2>/dev/null)}[1]}
  [[ $hn == "$_terhm_hn" ]] && return 0            # empty Enter: no new command
  _terhm_hn=$hn
  [[ -n $_terhm_out ]] || return 0
  last=$(fc -ln -1 2>/dev/null)
  if [[ $last != "$_terhm_out" ]]; then _terhm_tries=0; return 0; fi
  if (( TERHM_LAST_STATUS == 0 || TERHM_LAST_STATUS >= 128 )); then _terhm_tries=0; return 0; fi
  [[ $TERHM_AUTOFIX == 1 ]] && (( _terhm_tries < TERHM_AUTOFIX_MAX )) || return 0
  (( _terhm_tries++ ))
  print -nu2 "\e[2mterhm: command failed (exit $TERHM_LAST_STATUS), looking for a fix… [$(command terhm mode 2>/dev/null)]\e[0m"
  fix=$(TERHM_SHELL=zsh TERHM_KNOWN="$(_terhm_known)" TERHM_HISTORY="$(_terhm_hist)" \
        command terhm fix --status "$TERHM_LAST_STATUS" --request "$_terhm_orig" -- "$last" 2>/dev/null)
  print -nu2 "\r\e[K"
  [[ -n $fix ]] || return 0
  _terhm_out="$fix"
  if command terhm danger -- "$fix"; then
    print -u2 "⚠ terhm: potentially dangerous command, check it before pressing Enter"
  fi
  print -z -- "$fix"                               # becomes the next prompt's command line
}
if (( ! ${precmd_functions[(Ie)_terhm_precmd]:-0} )); then
  precmd_functions=(_terhm_precmd $precmd_functions)
fi

terhm-suggest() {
  local req="$BUFFER" alt=0 out rc msg hist="" st=0 errf last="" fix=0
  if [[ -n $_terhm_out && $BUFFER == "$_terhm_out" ]]; then
    req="$_terhm_orig"; alt=1                         # second Ctrl+G: alternative
  elif [[ -z ${BUFFER//[[:space:]]/} ]]; then
    if (( TERHM_LAST_STATUS != 0 )); then
      # history and exit code only when fixing a failed command: otherwise the small
      # model tends to copy recent commands instead of reading the request
      fix=1; last=$(fc -ln -1 2>/dev/null); hist=$(_terhm_hist); st=$TERHM_LAST_STATUS
    else
      zle -M "terhm: type what you want to do, then press Ctrl+G"; return 0
    fi
  fi
  errf=$(mktemp "${TMPDIR:-/tmp}/terhm.XXXXXX")
  zle -R "terhm: thinking… [$(command terhm mode 2>/dev/null)]"
  if (( fix )); then
    [[ $last == "$_terhm_out" ]] && req="$_terhm_orig" || req=""
    out=$(TERHM_SHELL=zsh TERHM_KNOWN="$(_terhm_known)" TERHM_HISTORY="$hist" \
          command terhm fix --status "$st" --request "$req" -- "$last" 2>"$errf")
  else
    out=$(TERHM_SHELL=zsh TERHM_KNOWN="$(_terhm_known)" TERHM_ALT=$alt TERHM_PREV="$_terhm_out" \
          command terhm ask "$req" 2>"$errf")
  fi
  rc=$?
  msg=$(<"$errf"); rm -f "$errf"
  if (( rc != 0 )) || [[ -z $out ]]; then
    zle -M "${msg:-terhm: no response}"; return 0
  fi
  (( alt || fix )) || _terhm_orig="$req"
  _terhm_out="$out"; _terhm_tries=0
  BUFFER="$out"; CURSOR=${#BUFFER}
  if command terhm danger -- "$out"; then
    zle -M "⚠ terhm: potentially dangerous command, check it before pressing Enter${msg:+
$msg}"
  elif [[ -n $msg ]]; then
    zle -M "$msg"                                  # e.g. Gemini not reachable, offline model used
  fi
}
zle -N terhm-suggest
bindkey -M emacs "$TERHM_KEY" terhm-suggest
bindkey -M viins "$TERHM_KEY" terhm-suggest
