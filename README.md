# terhm

A terminal that works as usual until you press **Ctrl+G**: describe what you want to do in plain language and a small **offline** model ([nl2sh-1.5b](https://huggingface.co/ThorOdinson246/nl2sh-1.5b-Q4_K_M), Qwen2.5-Coder-1.5B fine-tuned to write shell commands, Q4 quantized) proposes the command, based on the current directory, git and recent commands.

```
$ find files bigger than 100MB      ← type, then press Ctrl+G
$ find . -type f -size +100M -exec ls -lh {} +      ← the line becomes the command
```

The command lands on your command line: **it is never run by itself**, you press Enter.

## Installation

```bash
git clone https://github.com/YOUR-USER/terhm && cd terhm
./install.sh
```

The script downloads `llama-server` (llama.cpp) and the model (~1 GB, checksum verified), installs a **systemd user service** that starts at boot (with `loginctl enable-linger`) and adds the plugin to bash, zsh and fish (asking first).

Requirements: Linux (x86_64 or arm64), `systemd`, `curl`, `jq`, `tar`, ~1.5 GB of free RAM.

Useful options: `--yes`, `--model-file ./file.gguf`, `--llama-server /path`, `--no-service`, `--no-shell-rc`. For another GGUF model with a chat template: `TERHM_MODEL_URL=... ./install.sh`.

## Usage

| Action | Result |
|---|---|
| Type a request + `Ctrl+G` | The line becomes the proposed command |
| `Ctrl+G` on an empty line | `terhm ›` appears: type the request and press Enter |
| `Ctrl+G` on the command just proposed | `terhm ›` appears: a new request, or empty Enter for an alternative |
| `Ctrl+G` on an empty line after an error, then empty Enter | Proposes a fix for the last failed command |
| Run a proposed command and it **fails** | The fix appears by itself on the next line (up to 3 times in a row) |
| `Ctrl+C` or `Esc` at `terhm ›` | Cancel |
| Undo | Your shell's undo (`Ctrl+_` in zsh/bash, `Ctrl+Z` in fish) |

The `terhm ›` prompt is bash-only for now; in zsh and fish `Ctrl+G` on an empty line fixes the last failed command, and on the proposed command it immediately generates an alternative.

**Automatic retry**: if you press Enter on a command proposed by terhm and it ends with an error (non-zero exit code, Ctrl+C excluded), terhm sends the original request, the command and the exit code to the model, and puts the fix on the next prompt's command line. The fix is never run by itself either. Turn it off with `TERHM_AUTOFIX=0`; `TERHM_AUTOFIX_MAX` limits attempts in a row. In bash the line is filled in through the terminal's reply to a status request (`ESC [5n`), which all common terminals support; if yours does not reply, press `Ctrl+G` on an empty line to insert it.

If the command looks dangerous (`rm -rf`, `sudo`, `dd`, `mkfs`, `curl | sh`…) a warning is shown.

Commands: `terhm ask "..."`, `terhm fix --status N -- "command"`, `terhm doctor`, `terhm status`.

## Configuration

`~/.config/terhm/config` (see `config/terhm.conf`): port, timeout, number of context files, temperature, retries, regex of dangerous commands. To change the hotkey set `TERHM_KEY` before the plugin's `source` (zsh `'^X'`, bash `'\C-x'`, fish `\cx`).

## How it works

```
Ctrl+G → shell plugin → terhm ask → HTTP localhost:11500/v1/chat/completions → llama-server (nl2sh-1.5b) → command in the buffer
```

- System prompt in `prompts/system.txt` (the one recommended for nl2sh, plus OS and shell), temperature 0 and `repeat_penalty` 1.08 as the model card suggests.
- Context sent: directory, git branch, first 40 entries of the directory (directories first, then files, hidden ones last); recent commands and exit code only when you ask to fix a failed command. No file contents, no environment variables.
- No hand-written rules for specific commands: everything that ends up on the line is decided by the model.
- **Check without running**: before proposing it, terhm checks the command's syntax (`bash -n`, `zsh -n` or `fish -n`) and that the programs it uses exist (including your shell's aliases and functions). If something is wrong, it sends the problem back to the model and retries (up to `TERHM_RETRIES`, default 2). Turn it off with `TERHM_CHECK=0`.
- The server listens on `127.0.0.1` only. No telemetry.

## A "pretty" terminal

`terminal/` has ready-made configs for **WezTerm** and **Kitty** (Catppuccin theme, JetBrains Mono). The plugin works in any terminal.

## Development

```bash
bash tests/run.sh          # tests with a fake server, no model needed
python3 tests/pty_test.py  # interactive Ctrl+G tests in bash, zsh and fish (needs zsh and fish)
shellcheck -S warning bin/terhm install.sh shell/terhm.bash
```

## Limitations

A 1.5B model makes mistakes and was trained mostly on English requests: always read the command before pressing Enter. The default GGUF file is `nl2sh-1.5b-Q4_K_M.gguf` from the `ThorOdinson246/nl2sh-1.5b-Q4_K_M` repo (Apache-2.0); if the name changes use `TERHM_MODEL_URL`.

License: MIT
