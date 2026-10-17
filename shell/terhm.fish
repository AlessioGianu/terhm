# terhm - plugin fish. Default hotkey: Ctrl+G.
status is-interactive; or return 0
set -q TERHM_KEY; or set -g TERHM_KEY \cg
set -q TERHM_AUTOFIX; or set -g TERHM_AUTOFIX 1          # if the proposed command fails, propose a fix
set -q TERHM_AUTOFIX_MAX; or set -g TERHM_AUTOFIX_MAX 3  # max automatic fixes in a row
set -g _terhm_last_status 0
set -g _terhm_orig ""
set -g _terhm_out ""
set -g _terhm_fix ""
set -g _terhm_tries 0

function _terhm_known
    string join ' ' -- (builtin -n) (functions -a -n | string split ,) (abbr --list)
end

# After a command: if it was the one proposed by terhm and it failed, ask the model
# for a fix right away; _terhm_prefill puts it on the command line (it is not executed).
function _terhm_postexec --on-event fish_postexec
    set -l st $status
    set -g _terhm_last_status $st
    test -n "$_terhm_out"; or return
    if test "$argv[1]" != "$_terhm_out"; or test $st -eq 0; or test $st -ge 128
        set -g _terhm_tries 0
        return
    end
    test "$TERHM_AUTOFIX" = 1; and test $_terhm_tries -lt $TERHM_AUTOFIX_MAX; or return
    set -g _terhm_tries (math $_terhm_tries + 1)
    printf '\e[2mterhm: command failed (exit %s), looking for a fix…\e[0m' $st >&2
    set -l fix (env TERHM_SHELL=fish TERHM_KNOWN=(_terhm_known) \
        TERHM_HISTORY=(string join '; ' (history --max=5)) \
        terhm fix --status $st --request "$_terhm_orig" -- "$argv[1]" 2>/dev/null)
    printf '\r\e[K' >&2
    set fix (string join ' ' -- $fix)
    test -n "$fix"; or return
    set -g _terhm_out "$fix"
    set -g _terhm_fix "$fix"
end

function _terhm_prefill --on-event fish_prompt
    test -n "$_terhm_fix"; or return
    commandline -r -- "$_terhm_fix"
    commandline -f end-of-line
    if terhm danger -- "$_terhm_fix"
        echo "⚠ terhm: potentially dangerous command, check it before pressing Enter" >&2
    end
    set -g _terhm_fix ""
end

function terhm_suggest
    set -l req (commandline)
    set -l alt 0
    set -l fix 0
    set -l last ""
    set -l hist ""
    set -l st 0
    if test -n "$_terhm_out"; and test "$req" = "$_terhm_out"
        set req $_terhm_orig                           # second Ctrl+G: alternative
        set alt 1
    else if test -z (string trim -- "$req")
        if test $_terhm_last_status -ne 0
            # history and exit code only when fixing a failed command: otherwise the small
            # model tends to copy recent commands instead of reading the request
            set fix 1
            set last $history[1]
            set hist (string join '; ' (history --max=5))
            set st $_terhm_last_status
        else
            echo; echo "terhm: type what you want to do, then press Ctrl+G" >&2
            commandline -f repaint; return
        end
    end
    set -l errf (mktemp)
    set -l out
    if test $fix -eq 1
        set -l orig ""
        test "$last" = "$_terhm_out"; and set orig $_terhm_orig
        set out (env TERHM_SHELL=fish TERHM_KNOWN=(_terhm_known) TERHM_HISTORY="$hist" \
            terhm fix --status $st --request "$orig" -- "$last" 2>$errf)
    else
        set out (env TERHM_SHELL=fish TERHM_KNOWN=(_terhm_known) TERHM_ALT=$alt \
            TERHM_PREV="$_terhm_out" terhm ask "$req" 2>$errf)
    end
    set -l rc $status
    set out (string join ' ' -- $out)
    if test $rc -ne 0; or test -z "$out"
        echo; cat $errf >&2; rm -f $errf
        commandline -f repaint; return
    end
    rm -f $errf
    test $alt -eq 0; and test $fix -eq 0; and set -g _terhm_orig "$req"
    set -g _terhm_out "$out"
    set -g _terhm_tries 0
    commandline -r -- "$out"
    commandline -f end-of-line
    if terhm danger -- "$out"
        echo; echo "⚠ terhm: potentially dangerous command, check it before pressing Enter" >&2
    end
    commandline -f repaint
end

bind $TERHM_KEY terhm_suggest
bind -M insert $TERHM_KEY terhm_suggest 2>/dev/null
