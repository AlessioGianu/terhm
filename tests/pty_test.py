#!/usr/bin/env python3
"""Interactive test: opens a real shell in a pty, types a request, presses Ctrl+G."""
import os, pty, re, select, shutil, subprocess, sys, tempfile, time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
port = str(20000 + os.getpid() % 10000)
srv = subprocess.Popen([sys.executable, f"{ROOT}/tests/mock_server.py", port])
time.sleep(0.7)
home = tempfile.mkdtemp()
env = dict(os.environ, HOME=home, TERHM_PORT=port, TERHM_HOME=ROOT, TERM="xterm",
           PATH=f"{ROOT}/bin:" + os.environ["PATH"], XDG_CONFIG_HOME=home + "/.config",
           MOCK_LOG=home + "/mock.log")

def read_for(fd, secs):
    out = b""; end = time.time() + secs
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try: b = os.read(fd, 4096)
            except OSError: break
            out += b
            # act as a terminal: answer status (DSR), cursor position and device queries
            if b"\x1b[5n" in b: os.write(fd, b"\x1b[0n")
            if b"\x1b[6n" in b: os.write(fd, b"\x1b[1;1R")
            if b"\x1b[0c" in b or b"\x1b[c" in b: os.write(fd, b"\x1b[?62;22c")
    return re.sub(rb"\x1b\[[0-9;?>=]*[a-zA-Z~]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)|\x1b[=>]", b"", out).decode(errors="ignore")

def run(name, argv):
    if not shutil.which(argv[0]):
        print(f"skip - {name}: not installed"); return True
    pid, fd = pty.fork()
    if pid == 0:
        open(home + "/terhm_ls_ok", "w").close()
        os.chdir(home); os.execvpe(argv[0], argv, env)
    read_for(fd, 2)
    def step(text, wait=2.5):
        os.write(fd, text.encode()); return read_for(fd, wait)
    def clear():
        os.write(fd, b"\x03"); read_for(fd, 0.7)
    res = {}
    step("find files bigger than 100MB")
    res["suggest"] = step("\x07", 4)
    if name == "bash":                      # Ctrl+G on the proposed command, empty Enter = alternative
        step("\x07", 1); res["alt"] = step("\r", 4)
    else:                                   # second Ctrl+G: alternative
        res["alt"] = step("\x07", 4)
    clear()
    if name == "bash":                      # Ctrl+G on an empty line: waits for a new request
        res["prompt"] = step("\x07", 1)
        res["new"] = step("danger\r", 4)
        clear()
        res["cancel"] = step("\x07", 1) + step("\x03", 1) + step("echo alive\r", 1.5)
        # bracketed paste and cursor editing in the request: "dnger" -> "danger"
        step("\x07", 1); step("\x1b[200~dnger\x1b[201~", 0.5); step("\x1b[D" * 4 + "a", 0.5)
        res["edit"] = step("\r", 4)
        clear()
    # bash 5.2 regression: after Ctrl+G the executed line must be exactly the one shown
    step("list"); step("\x07", 4)
    res["exec"] = step("\r", 2)
    # automatic retry: the proposed command fails, the fix shows up by itself
    step("failing"); step("\x07", 4)
    res["autofix"] = step("\r", 5)
    res["autofix_run"] = step("\r", 2)
    step("danger")
    res["danger"] = step("\x07", 4)
    os.write(fd, b"\x03"); os.write(fd, b"exit\r"); read_for(fd, 0.5)
    checks = [
        ("Ctrl+G inserts the command", "-size +100M -exec ls -lh {} +" in res["suggest"]),
        ("Ctrl+G on the proposed command regenerates", "# alt" in res["alt"]),
        ("automatic retry after an error", "echo fixed" in res["autofix"]),
        ("the fix runs with Enter", re.search(r"[\r\n]fixed\r?\n", res["autofix_run"]) is not None),
        ("dangerous command warning", "rm -rf build/" in res["danger"] and "dangerous" in res["danger"]),
        ("the proposed command runs correctly", "not found" not in res["exec"] and "terhm_ls_ok" in res["exec"]),
    ]
    if name == "bash":
        checks += [
            ("Ctrl+G on an empty line asks for a new request", "terhm ›" in res["prompt"] and "rm -rf build/" in res["new"]),
            ("paste and arrow keys in the request", "rm -rf build/" in res["edit"] and "00~" not in res["edit"]),
            ("Ctrl+C cancels and the terminal stays normal", "alive" in res["cancel"] and "echo alive\r\necho alive" not in res["cancel"]),
        ]
    for label, ok in checks:
        print(f"{'ok  ' if ok else 'FAIL'} - {name}: {label}")
    if not all(ok for _, ok in checks):
        for k, v in res.items(): print(f"   {k}: {v!r}")
    return all(ok for _, ok in checks)

results = []
open(home + "/.bashrc", "w").write(f"PS1='bash$ '\nalias ls='ls --color=never'\nsource {ROOT}/shell/terhm.bash\n")
results.append(run("bash", ["bash", "--noprofile", "--rcfile", home + "/.bashrc", "-i"]))
open(home + "/.zshrc", "w").write(f"PS1='zsh%% '\nsource {ROOT}/shell/terhm.zsh\n")
results.append(run("zsh", ["zsh", "-i"]))
os.makedirs(home + "/.config/fish", exist_ok=True)
open(home + "/.config/fish/config.fish", "w").write(f"function fish_prompt; echo -n 'fish> '; end\nsource {ROOT}/shell/terhm.fish\n")
results.append(run("fish", ["fish", "-i"]))
srv.kill()
sys.exit(0 if all(results) else 1)
