# terhm: project specification

> A normal terminal with a superpower: press a key combination, type in plain language and a small **offline** model (quantized nl2sh-1.5b) proposes the right command, based on the current directory and session.

**Status:** draft v0.1 · **Proposed license:** MIT · **Platform:** Linux

---

## 1. Goals

- Translate natural-language requests into shell commands, **100% offline**.
- Don't change habits: the terminal works normally until the hotkey is pressed.
- Model always ready: automatic start at boot, low latency.
- Run on modest hardware (CPU only, 4 GB of free RAM).
- Open source repository, easy to install and extend.

## 2. Non-goals

- Writing a terminal emulator from scratch.
- Running commands automatically: **the user always presses Enter**.
- General chat or an autonomous agent. The project does one thing: propose commands.
- Sending data to cloud services or collecting telemetry.

## 3. Architecture

```
┌──────────────────────┐   hotkey    ┌────────────────────┐   HTTP localhost   ┌──────────────────────┐
│ Terminal (any)       │────────────▶│ Shell plugin       │───────────────────▶│ llama-server         │
│ WezTerm / Kitty / …  │◀────────────│ zsh / bash / fish  │◀───────────────────│ nl2sh-1.5b GGUF Q4   │
└──────────────────────┘  command    └────────────────────┘     JSON           │ (systemd service)    │
                          in buffer                                            └──────────────────────┘
```

| Component | Role | Technology |
|---|---|---|
| LLM daemon | Local inference, always on | `llama.cpp` (`llama-server`) + systemd user |
| Shell plugin | Hotkey, context gathering, daemon call | zsh (ZLE), bash (readline), fish |
| Terminal | Modern look | Ready-made configs for WezTerm and Kitty |
| Installer | One-command setup | `install.sh` |

## 4. Functional requirements

| ID | Requirement |
|---|---|
| F1 | A configurable hotkey (default `Ctrl+G`) reads the text typed at the prompt and sends it to the model. |
| F2 | The generated command **replaces the command-line buffer**, without being executed. |
| F3 | The context sent includes: current directory, file list (max 20), OS, last 5 commands, exit code of the last command, git branch if present. |
| F4 | If the buffer is empty, use the last failed command as context and propose a fix. |
| F5 | Output limited to **a single line** of shell (GBNF grammar or post-processing). |
| F6 | Dangerous commands (`rm -rf`, `dd`, `mkfs`, `sudo`, `chmod -R`, `> /dev/`) are highlighted or preceded by a warning. |
| F7 | A second `Ctrl+G` on the same text generates an alternative proposal. |
| F8 | `Esc` or `Ctrl+C` restore the original natural-language text. |
| F9 | The service starts automatically at boot (even without a graphical login). |
| F10 | If the daemon does not respond, the plugin shows a clear message and does not block the shell (5 s timeout). |

## 5. Non-functional requirements

- **Latency:** response in under 2 s on a modern CPU with a Q4-quantized 0.5B–1B model.
- **RAM:** under 1.5 GB at steady state.
- **Privacy:** no external connections after the model download. The server listens on `127.0.0.1` only.
- **Minimal dependencies:** `curl`, `jq`, `systemd`. No mandatory Python.
- **Compatibility:** zsh ≥ 5.8, bash ≥ 4.4, fish ≥ 3.4. Target distros: Ubuntu/Debian, Fedora, Arch.
- **Reversibility:** `uninstall.sh` removes the service, plugins and model.

## 6. User experience

1. The user types in the terminal: `find files bigger than 100MB`
2. Presses `Ctrl+G`. A short indicator appears (e.g. `⏳ thinking…`).
3. The line becomes: `find . -type f -size +100M -exec ls -lh {} +`
4. The user reads it, edits it if they want, and presses **Enter** to run it.

Principles: no extra windows, no interruption of the flow; the model suggests, it does not execute.

## 7. Model and inference

- **Model:** nl2sh-1.5b (Qwen2.5-Coder-1.5B fine-tuned for NL→shell) in GGUF format, Q4_K_M.
- **Default parameters:** `temperature 0.1`, `n_predict 128`, `ctx 2048`, `threads = nproc/2`.
- **System prompt** in `prompts/system.txt`, with 3–5 few-shot examples in the user's language.
- Optional **GBNF grammar** to force a single line with no markdown or explanations.
- **Post-processing:** strip backticks, prefixes like `$ ` or `bash`, newlines.
- **Prefix cache:** the system prompt stays fixed to take advantage of llama.cpp's prompt cache.

## 8. Context gathered

The context must stay **small** to keep things fast:

```
cwd: /home/user/projects/site
os: Linux 6.8
git: branch main, 3 files modified
last exit code: 1
recent commands: npm run build; ls; cd site
files: package.json src/ public/ README.md …
```

Rules: no file contents, no environment variables, no passwords. Sensitive directories can be excluded through configuration.

## 9. Security

- No automatic execution, ever.
- Configurable list of dangerous patterns (`~/.config/terhm/config.toml`).
- The service runs as a **normal user** (systemd `--user`), never root.
- Binds to localhost only; optional Unix socket instead of TCP.
- The model can be wrong: the README must say so clearly.

## 10. Configuration

File: `~/.config/terhm/config.toml`

```toml
hotkey = "ctrl-g"
language = "en"          # language of the requests
port = 11500
max_files_in_context = 20
history_lines = 5
timeout_seconds = 5
dangerous_patterns = ["rm -rf", "dd ", "mkfs", "sudo", "chmod -R"]
```

## 11. Repository layout

```
terhm/
├── README.md
├── SPEC.md
├── LICENSE
├── install.sh
├── uninstall.sh
├── systemd/
│   └── terhm.service
├── shell/
│   ├── terhm.zsh
│   ├── terhm.bash
│   └── terhm.fish
├── terminal/
│   ├── wezterm.lua
│   └── kitty.conf
├── prompts/
│   ├── system.txt
│   └── oneline.gbnf
├── tests/
│   └── prompts.yaml        # requests → expected commands
├── packaging/
│   ├── deb/
│   └── aur/PKGBUILD
└── .github/workflows/
    ├── ci.yml              # shellcheck + tests
    └── release.yml
```

## 12. Installation (`install.sh` flow)

1. Detect distro and architecture (x86_64, aarch64).
2. Download or build `llama-server` (llama.cpp binary releases).
3. Download the nl2sh-1.5b GGUF into `~/.local/share/terhm/` and verify its SHA256.
4. Install the systemd user unit and enable it: `systemctl --user enable --now terhm`.
5. Run `loginctl enable-linger $USER` for start at boot.
6. Add the plugin's `source` line to the current shell's rc file (after confirmation).
7. Copy the chosen terminal's config (optional).
8. Run a final test: a sample request to the daemon.

## 13. Testing and quality

- **shellcheck** on all scripts.
- **Prompt regression tests:** `tests/prompts.yaml` holds request/expected-command pairs; the output is checked to be one line and to contain the right commands.
- **Benchmarks:** time to first response and RAM on 2–3 reference machines.
- **CI:** GitHub Actions on Ubuntu for script linting and tests.

## 14. Roadmap

| Version | Content |
|---|---|
| **v0.1** | systemd daemon + zsh plugin + basic installer |
| **v0.2** | bash and fish plugins, TOML config, dangerous-command warnings |
| **v0.3** | GBNF grammar, few-shot, prompt tests, WezTerm/Kitty configs |
| **v0.4** | .deb and AUR packages, automated releases |
| **v1.0** | Complete documentation, benchmarks, selectable alternative models |

Future ideas: command explanation (`Ctrl+E`), proposal history, choosing among several alternatives, GPU support (Vulkan/CUDA), adapting to the system language.

## 15. Known risks

| Risk | Mitigation |
|---|---|
| The small model generates wrong commands | Few-shot, grammar, low temperature, manual confirmation |
| High latency on old hardware | 0.5B model, more aggressive quantization, prefix cache |
| Differences between distros (packages, paths) | Pass `os` and distro in the context, test on several distros |
| Conflicts with existing keybindings | Configurable hotkey, check at install time |

## 16. Contributing

1. Fork and create a branch.
2. Add new cases to `tests/prompts.yaml` when you improve the prompt.
3. Run `shellcheck` before opening the PR.
4. Describe the hardware and model used if you report performance data.
