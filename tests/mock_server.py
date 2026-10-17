#!/usr/bin/env python3
"""Fake llama-server for the tests: answers /health and /v1/chat/completions."""
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

LOG = os.environ.get("MOCK_LOG", "/tmp/terhm_mock.log")

def answer(body):
    users = [m["content"] for m in body["messages"] if m["role"] == "user"]
    req, last = users[0].lower(), users[-1].lower()
    if "same command that failed" in last: return "echo different"
    if "i ran it" in last or last.startswith("fix this command"):
        return "ls /nonexistent-terhm" if "stubborn" in req else "echo fixed"
    if "does not work here" in last: return "ls -la"
    if "100mb" in req: return " find . -type f -size +100M -exec ls -lh {} +"
    if "multifence" in req: return "```bash\nls -la\n```"
    if "think" in req: return "<think>\n\n</think>\n\ngit status"
    if "fence" in req: return " ```bash"
    if "wrapped" in req: return " `ls -la`"
    if "dollar" in req: return " $ ls -la"
    if "danger" in req: return " rm -rf build/"
    if "empty" in req: return ""
    if "clipboard" in req: return " nosuchprogram123 -x"
    if "syntax" in req: return " echo 'unterminated"
    if "failing" in req or "stubborn" in req: return " ls /nonexistent-terhm"
    return " ls"

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, obj):
        b = json.dumps(obj).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        self._send({"status": "ok"})
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with open(LOG, "w") as f: json.dump(body, f)
        out = answer(body)
        if body.get("temperature", 0) > 0.5 and out: out += " # alt"
        self._send({"choices": [{"message": {"role": "assistant", "content": out}}]})

HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
