# terhm

A terminal that works as usual until you press **Ctrl+G**: describe what you want to do in plain language and a model proposes the command, based on the current directory, the project in it (make, docker, npm, python, ROS 2…), git, the tools you have installed and recent commands.

- **Online**: [Gemini](https://ai.google.dev/) (`gemini-3.5-flash-lite` by default) with your API key.
- **Offline backup** (optional): [nl2sh-1.5b](https://huggingface.co/ThorOdinson246/nl2sh-1.5b-Q4_K_M) (Q4 GGUF, CPU only, ~1 GB download, ~1.5 GB of RAM) on a local llama-server. It answers when Gemini cannot be reached (no internet, quota exceeded, key rejected…).

While it waits, terhm shows which one is answering: `terhm: thinking… [online · gemini-3.5-flash-lite]`, `[offline · nl2sh-1.5b — Gemini: not reachable]`, or over SSH `[online · gemini-3.5-flash-lite, via your machine]`.

```
$ find files bigger than 100MB      ← type, then press Ctrl+G
terhm: thinking… [online · gemini-3.5-flash-lite]
$ find . -type f -size +100M -exec ls -lh {} +      ← the line becomes the command
```

The command lands on your command line: **it is never run by itself**, you press Enter.

## Installation

```bash
git clone https://github.com/YOUR-USER/terhm && cd terhm
./install.sh
```

The installer asks two things:

1. **Your Gemini API key** (create one for free at <https://aistudio.google.com/apikey>). It is checked right away and saved in `~/.config/terhm/gemini.key`, readable only by you. Leave it empty to use only the offline model.
2. **Whether to install the offline backup model** nl2sh-1.5b. If yes, it downloads `llama-server` (llama.cpp) and the model (checksum verified), installs a **systemd user service** that starts at boot (with `loginctl enable-linger`).

Then it adds the plugin to bash, zsh and fish (asking first). Rerun `./install.sh` to change the key or add/remove the offline model.

Requirements: Linux (x86_64 or arm64), `curl`, `jq`, `tar`; for the offline model also `systemd` and ~1.5 GB of free RAM; for `terhm ssh` also `python3`.

Useful options: `--yes`, `--gemini-key KEY` (or `GEMINI_API_KEY=... ./install.sh --yes`), `--no-gemini`, `--offline` / `--no-offline`, `--model-file ./file.gguf`, `--update-llama`, `--llama-server /path`, `--no-service`, `--no-shell-rc`. Another Gemini model: `TERHM_GEMINI_MODEL=... ./install.sh`.

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

Commands: `terhm ask "..."`, `terhm fix --status N -- "command"`, `terhm context` (shows what is sent to the model from the current directory), `terhm doctor` (checks the key, Gemini and the offline model), `terhm status`, `terhm mode` (which model will answer), `terhm ssh host` (see below).

## Over SSH

```bash
terhm ssh user@server          # same arguments as ssh
```

Opens a normal SSH session with Ctrl+G working on the remote host. The models are used from **your** machine: terhm starts a small local proxy for the session (needs `python3` locally) and a reverse tunnel (`ssh -R`) to it, and sends a small bundle (the `terhm` script, the prompt and the shell plugins) inside the ssh command. It is unpacked in `~/.cache/terhm/ssh/` on the remote, and your usual login shell (bash, zsh or fish) starts with your own config plus the plugin. Nothing is installed on the remote, no model is downloaded there and **your Gemini API key never leaves your machine**; the context (directory, project, installed tools) is the remote's. Gemini → offline fallback works the same way.

- The remote needs only `bash` and `curl` (no `jq`), and must allow port forwarding (`AllowTcpForwarding`, on by default). If something is missing, you get a normal shell and a message saying why.
- With a remote command (`terhm ssh host uptime`) or `-N`/`-T`/`-W`, it is just `ssh`.
- To always use it: `alias ssh='terhm ssh'`.
- It nests: `terhm ssh` from inside a `terhm ssh` session forwards the tunnel one more hop.

## Configuration

`~/.config/terhm/config` (see `config/terhm.conf`): mode (`TERHM_MODE=auto|online|offline`), Gemini model and timeout (`TERHM_GEMINI_MODEL`, `TERHM_GEMINI_TIMEOUT`, default 15 s before falling back), offline model port, timeout and sampling, number of context files, retries, regex of dangerous commands. To change the hotkey set `TERHM_KEY` before the plugin's `source` (zsh `'^X'`, bash `'\C-x'`, fish `\cx`).

## How it works

```
Ctrl+G → shell plugin → terhm ask → Gemini (OpenAI-compatible API) ──fails?──▶ llama-server 127.0.0.1:11500 (nl2sh-1.5b) → command in the buffer
```

- System prompt in `prompts/system.txt` (OS, shell and how to use the context). Gemini answers with minimal reasoning (`reasoning_effort: minimal`) and reasons a little more (`low`) for the alternative, the fix of a failed command and a command that fails the checks. The offline model uses the nl2sh model card's settings (temperature 0, `top_k` 40, `top_p` 0.9, one line). The API key is sent in a header read from a pipe, so it never shows up in the process list.
- Context sent (see it with `terhm context`):
  - directory, git branch and number of changed files, first 40 entries of the directory (directories first, then files, hidden ones last);
  - **project**, in the current directory and at the git root: make targets, docker compose services, Dockerfiles, npm/pnpm/yarn/bun scripts, python tool (pip, uv, poetry, pipenv) and virtualenv, cmake, cargo, go, maven, gradle, helm, terraform…;
  - **ROS 2**: the nearest colcon workspace (built or not, sourced or not), its packages with build type and executables (`console_scripts` of `ament_python` packages, `add_executable` of `ament_cmake` ones) and launch files;
  - **session**: active virtualenv/conda env, `ROS_DISTRO`, Wayland/X11, SSH, container, tmux, root;
  - **installed tools**: docker (and whether `docker compose` v2 is there and docker needs sudo), make, python, node, cargo, ros2, colcon, xclip/wl-copy, rg/fd…;
  - recent commands and exit code only when you ask to fix a failed command.

  Only file names and a few small build files (Makefile, package.json, compose file, package.xml, setup.py) are read; no other file contents and no environment variable values except the names above. `.env` files are never read. Turn parts off with `TERHM_PROJECT_CONTEXT=0` and `TERHM_TOOLS_CONTEXT=0`.
- No hand-written rules for specific commands: everything that ends up on the line is decided by the model.
- **Check without running**: before proposing it, terhm checks the command's syntax (`bash -n`, `zsh -n` or `fish -n`) and that the programs it uses exist (including your shell's aliases and functions). If something is wrong, it sends the problem back to the model and retries (up to `TERHM_RETRIES`, default 2). Turn it off with `TERHM_CHECK=0`.
- Online mode sends the request and this context to Google (Gemini API); offline mode sends nothing out. The offline server and the ssh proxy listen on `127.0.0.1` only. No telemetry.

## A "pretty" terminal

`terminal/` has ready-made configs for **WezTerm** and **Kitty** (Catppuccin theme, JetBrains Mono). The plugin works in any terminal.

## Development

```bash
bash tests/run.sh          # tests with fake Gemini and llama servers, no model or key needed
python3 tests/pty_test.py  # interactive Ctrl+G tests in bash, zsh and fish (needs zsh and fish)
shellcheck -S warning bin/terhm install.sh shell/terhm.bash
```

## Limitations

Models make mistakes: always read the command before pressing Enter. The offline GGUF file is `nl2sh-1.5b-Q4_K_M.gguf` from `ThorOdinson246/nl2sh-1.5b-Q4_K_M`. If a name changes use `TERHM_MODEL_URL`.

License: MIT
