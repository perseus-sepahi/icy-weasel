#!/usr/bin/env python3
"""A tiny OpenAI-style model server, shaped like llama.cpp's (what Bonsai's
start_llama_server.sh runs): GET /v1/models and streamed POST /v1/chat/completions.

Used by AIProviderTests, which can't host a server inside the app sandbox:
    python3 scripts/fake-ai-server.py 18431 &
    TEST_RUNNER_IW_FAKE_AI_PORT=18431 xcodebuild ... -only-testing:IcyWeaselTests/AIProviderTests
Requests are kept in memory; GET /debug/requests returns them so the sandboxed
test can check what was sent.
GET /login and /done are two plain pages for PasswordTests, which needs real
history entries that WebKit can restore from its back/forward cache.
"""
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEL = "Ternary-Bonsai-2-27B-PQ2_0.gguf"
REPLY = ["The last ferry ", "leaves at 21:47."]
REQUESTS = []
PAGES = {
    "/login": '<form><input type="email" id="u" autocomplete="username"><input type="password" id="p">'
              '<button type="submit">Sign in</button></form>',
    "/done": "<p>Signed in</p>",
}

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass

    def record(self, body):
        REQUESTS.append({"path": self.path, "authorization": self.headers.get("Authorization"), "body": body})

    def do_GET(self):
        if self.path == "/debug/requests":
            data = json.dumps(REQUESTS).encode()
            self.send_response(200); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
            REQUESTS.clear()
        elif self.path in PAGES:
            data = ("<!doctype html><html><body>" + PAGES[self.path] + "</body></html>").encode()
            self.send_response(200); self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
        elif self.path.rstrip("/") == "/v1/models":
            self.record("")
            data = json.dumps({"object": "list", "data": [{"id": MODEL, "object": "model"}]}).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
        else:
            self.send_response(404); self.end_headers()

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        self.record(body)
        if self.path.rstrip("/") != "/v1/chat/completions":
            self.send_response(404); self.end_headers(); return
        events = "".join("data: " + json.dumps({"choices": [{"delta": {"content": p}}]}) + "\n\n" for p in REPLY)
        events += "data: [DONE]\n\n"
        data = events.encode()
        self.send_response(200); self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 18431
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
