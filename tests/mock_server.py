#!/usr/bin/env python3
"""Fake servers for the tests: llama-server (/health, /v1/chat/completions) and the
Gemini OpenAI-compatible API (/gemini/chat/completions, /gemini/models/<model>).
Gemini accepts the key "goodkey"; the model "down" answers 503."""
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
    if "reasonfence" in req: return "Okay, the user wants the status.\n</think>\n\nUse this command:\n```bash\ngit status\n```\nIt shows the changes."
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
    def _err(self, code, msg):
        b = json.dumps([{"error": {"code": code, "message": msg}}]).encode()
        self.send_response(code); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def _gemini_auth(self):
        if self.headers.get("Authorization") != "Bearer goodkey":
            self._err(400, "API key not valid. Please pass a valid API key."); return False
        return True
    def do_GET(self):
        if self.path.startswith("/gemini/"):
            if not self._gemini_auth(): return
            if self.path != "/gemini/models/gemini-test": return self._err(404, "model not found")
        self._send({"status": "ok"})
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        body["_path"] = self.path
        with open(LOG, "w") as f: json.dump(body, f)
        if self.path.startswith("/gemini/"):
            if not self._gemini_auth(): return
            if body.get("model") == "down": return self._err(503, "overloaded")
        out = answer(body)
        # alternative at 0.7
        if body.get("temperature", 0) > 0.65 and out and "</think>" not in out: out += " # alt"
        self._send({"choices": [{"finish_reason": "stop", "message": {"role": "assistant", "content": out}}]})

HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
