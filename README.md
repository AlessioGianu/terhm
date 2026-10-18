# terhm

A terminal that works as usual until you press **Ctrl+G**: describe what you want to do in plain language and a small **offline** model proposes the command, based on the current directory, the project in it (make, docker, npm, python, ROS 2…), git, the tools you have installed and recent commands.

Two models to choose from at install time (both Q4 quantized, CPU only):

| Model | Download | RAM | Notes |
|---|---|---|---|
| [nl2sh-1.5b](https://huggingface.co/ThorOdinson246/nl2sh-1.5b-Q4_K_M) (default) | ~1 GB | ~1.5 GB | Qwen2.5-Coder-1.5B fine-tuned to write shell commands. Fast. |
| [Qwen3.5-4B](https://huggingface.co/Qwen/Qwen3.5-4B) ([GGUF](https://huggingface.co/unsloth/Qwen3.5-4B-GGUF)) | ~2.7 GB | ~4 GB | General model, slower but smarter; makes better use of the project context. Thinking mode is turned off. |

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

The script asks which model to use, downloads `llama-server` (llama.cpp) and the model (checksum verified), installs a **systemd user service** that starts at boot (with `loginctl enable-linger`) and adds the plugin to bash, zsh and fish (asking first).

Requirements: Linux (x86_64 or arm64), `systemd`, `curl`, `jq`, `tar`, ~1.5 GB of free RAM (~4 GB for Qwen3.5-4B).

Useful options: `--model nl2sh` or `--model qwen3.5-4b` (skips the question), `--yes`, `--model-file ./file.gguf`, `--update-llama` (Qwen3.5 needs a recent llama.cpp), `--llama-server /path`, `--no-service`, `--no-shell-rc`. For another GGUF model with a chat template: `TERHM_MODEL_URL=... ./install.sh`. To switch model later, run `./install.sh` again and pick the other one.

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

Commands: `terhm ask "..."`, `terhm fix --status N -- "command"`, `terhm context` (shows what is sent to the model from the current directory), `terhm doctor`, `terhm status`, `terhm ssh host` (see below).

## Over SSH

```bash
terhm ssh user@server          # same arguments as ssh
```

Opens a normal SSH session with Ctrl+G working on the remote host. The model keeps running on **your** machine: terhm adds a reverse tunnel (`ssh -R`) so the remote can reach it, and sends a small bundle (the `terhm` script, the prompt and the shell plugins, ~30 KB) inside the ssh command. It is unpacked in `~/.cache/terhm/ssh/` on the remote, and your usual login shell (bash, zsh or fish) starts with your own config plus the plugin. Nothing is installed on the remote and no model is downloaded there; the context (directory, project, installed tools) is the remote's.

- The remote needs `bash`, `curl` and `jq`, and must allow port forwarding (`AllowTcpForwarding`, on by default). If something is missing, you get a normal shell and a message saying why.
- With a remote command (`terhm ssh host uptime`) or `-N`/`-T`/`-W`, it is just `ssh`.
- To always use it: `alias ssh='terhm ssh'`.
- It nests: `terhm ssh` from inside a `terhm ssh` session forwards the tunnel one more hop.

## Configuration

`~/.config/terhm/config` (see `config/terhm.conf`): model profile (`TERHM_MODEL`), port, timeout, number of context files, temperature, retries, regex of dangerous commands. To change the hotkey set `TERHM_KEY` before the plugin's `source` (zsh `'^X'`, bash `'\C-x'`, fish `\cx`).

## How it works

```
Ctrl+G → shell plugin → terhm ask → HTTP localhost:11500/v1/chat/completions → llama-server (nl2sh-1.5b or Qwen3.5-4B) → command in the buffer
```

- System prompt in `prompts/system.txt` (the one recommended for nl2sh, plus OS, shell and how to use the context), temperature 0. nl2sh uses `repeat_penalty` 1.08 as its model card suggests; Qwen3.5 uses the model card's non-thinking settings (`top_k` 20, `top_p` 0.8) with `enable_thinking: false`.
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

Small models make mistakes (Qwen3.5-4B fewer than nl2sh-1.5b, which was trained mostly on English requests): always read the command before pressing Enter. The default GGUF file is `nl2sh-1.5b-Q4_K_M.gguf` from the `ThorOdinson246/nl2sh-1.5b-Q4_K_M` repo (Apache-2.0); Qwen3.5-4B is `Qwen3.5-4B-Q4_K_M.gguf` from `unsloth/Qwen3.5-4B-GGUF` (Apache-2.0). If a name changes use `TERHM_MODEL_URL`.

License: MIT
