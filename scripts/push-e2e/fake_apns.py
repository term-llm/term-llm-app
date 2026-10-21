"""Capturing stand-in for APNs used by run.sh: records each request and
serves the latest payload at GET /last. Usage: fake_apns.py <port> <capture.jsonl>"""
import json, sys, uuid
from http.server import BaseHTTPRequestHandler, HTTPServer

OUT = sys.argv[2]

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        record = {"path": self.path, "headers": {k.lower(): v for k, v in self.headers.items()}, "payload": json.loads(body)}
        with open(OUT, "a") as f:
            f.write(json.dumps(record) + "\n")
        self.send_response(200)
        self.send_header("apns-id", self.headers.get("apns-id") or str(uuid.uuid4()))
        self.end_headers()

    def do_GET(self):
        try:
            lines = open(OUT).read().strip().splitlines()
        except FileNotFoundError:
            lines = []
        if not lines:
            self.send_response(404); self.end_headers(); return
        body = json.dumps(json.loads(lines[-1])["payload"]).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass

HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
