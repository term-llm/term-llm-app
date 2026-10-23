#!/usr/bin/env python3
"""LOOPBACK DEMO FIXTURE, not a real Hub, tunnel, pairing or credential service.

Wire shapes transcribed from core 2496b5fddebdc9369642d062fa87b98cd649d415:
internal/app/serve/serve_hub_{nodes,attention,index,registration,passkey}.go
and internal/hub/probe.go. No dependency downloads or production credentials.
"""
import argparse
from datetime import datetime, timezone
import html
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import threading
from urllib.parse import urlsplit

CORE_COMMIT = "2496b5fddebdc9369642d062fa87b98cd649d415"
LABEL = "DEMO FIXTURE · LOCAL"
STAMP = "2026-10-23T06:00:00Z"


def session(identifier, number, title, node="dev", **extra):
    return dict(id=identifier, number=number, short_title=title,
                last_message_at=1792735200, message_count=4,
                resume_path=f"/node/{node}/chat/{number}", **extra)


def node(identifier, name, reachable=True):
    base = f"/node/{identifier}/"
    status = dict(reachable=reachable, state="ok" if reachable else "disconnected",
                  latency_ms=12 if reachable else 0)
    if reachable:
        status.update(version="fixture-core-2496b5fd", agent=name,
                      capabilities=["attention"])
    else:
        status["error"] = "Demo fixture: waiting for reverse connection"
    return dict(id=identifier, name=name, source="local", connection="direct" if reachable else "reverse",
                url="http://localhost:8766" if reachable else "", base_path="",
                proxy_path=base, new_session_path=base + "?new=1", has_token=False,
                status=status, diagnostics=[])


def responses():
    dev = node("dev", "Demo Dev")
    dev["sessions"] = dict(count_label="2 sessions", active_count=1, input_required_count=1,
                           unseen_count=1, attention_capability="supported",
                           active=[session("demo-active", 1, "Review the demo patch", active_run=True)],
                           recent=[session("demo-ready", 2, "Demo result ready")],
                           resume_path="/node/dev/chat/2")
    stalled = node("stalled", "Demo Stalled")
    stalled["sessions"] = dict(count_label="1 session", recent=[session("demo-stalled", 3, "Stalled demo chat", node="stalled")])
    return {
        "/healthz": dict(status="ok", role="hub", attention_diagnostics={"stale_nodes": 1}),
        "/api/nodes": {"nodes": [dev, stalled, node("offline", "Demo Offline", False)]},
        "/api/attention": dict(total_running=1, total_input_required=1, total_unseen=1,
            nodes=[dict(node_id="dev", node_name="Demo Dev", capability_state="supported", stale=False,
                        last_success_at=STAMP, running_count=1, input_required_count=1,
                        unseen_count=1, has_green_indicator=True)],
            input_required=[dict(node_id="dev", node_name="Demo Dev", session_id="demo-active", session_number=1,
                        title="Review the demo patch", pending_interaction_count=1,
                        pending_interaction_kinds=["approval"], required_since=STAMP,
                        resume_path="/node/dev/chat/1", stale=False)],
            inbox=[dict(node_id="dev", node_name="Demo Dev", session_id="demo-ready", session_number=2,
                        store_instance_id="demo-store", title="Demo result ready", outcome="completed",
                        terminal_at=STAMP, attention_seq=1, resume_path="/node/dev/chat/2")],
            has_more=False),
        "/api/delegations": {"delegations": []},
        "/api/registration-info": dict(enabled=False, token_configured=False, can_persist_nodes=True),
        # Read-only synthetic authenticated session; NOT a passkey ceremony.
        "/api/auth/session": dict(administrator="Demo operator", active_sessions=1, recently_authenticated=False,
            session=dict(created_at=STAMP, last_seen_at=STAMP, idle_expires_at="2099-01-01T00:00:00Z",
                         absolute_expires_at="2099-01-01T00:00:00Z")),
        "/api/auth/credentials": {"credentials": [dict(record_id="demo-credential", display_name="Demo passkey (not real)",
                          transports=["internal"], created_at=STAMP, last_used_at=STAMP)]},
    }


def page(body, config=None):
    root = ""
    if config:
        root = '<div id="root" data-hub-config="' + html.escape(json.dumps(config), quote=True) + '"></div>'
    return (f'<!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">'
            f'<title>Local demo fixture</title><style>body{{font:20px -apple-system;padding:24px;background:#101824;color:#fff}}'
            f'aside{{color:#ffd36b}}p{{line-height:1.5}}</style></head><body><aside>{LABEL}</aside>{root}{body}</body></html>').encode()


class FixtureServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, request_log=None, stall_seconds=90):
        super().__init__(address, Handler)
        self.request_log = Path(request_log) if request_log else None
        self.log_lock = threading.Lock()
        self.stall_seconds = stall_seconds
        self.stopping = threading.Event()

    def server_close(self):
        self.stopping.set()
        super().server_close()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        # Never record request headers, cookies, query strings, or bodies.
        pass

    def record(self, path, status):
        if self.server.request_log:
            entry = dict(time=datetime.now(timezone.utc).isoformat(), method=self.command, path=path, status=status)
            with self.server.log_lock:
                with self.server.request_log.open("a", encoding="utf-8") as stream:
                    stream.write(json.dumps(entry) + "\n")

    def send(self, status, body, content_type="application/json"):
        self.record(urlsplit(self.path).path, status)
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

    def do_GET(self):
        path = urlsplit(self.path).path
        data = responses()
        if path == "/__health":
            self.send(200, json.dumps(dict(fixture=True, core_commit=CORE_COMMIT)).encode())
        elif path in data:
            self.send(200, json.dumps(data[path]).encode())
        elif path == "/":
            config = dict(page="dashboard", authMode="passkey", basePath="", canAddNodes=True,
                          passkeyAuth=True, invalidToken=False, formAction="/", cacheDisplayAllowed=False)
            self.send(200, page("<h1>Local Hub protocol fixture</h1><p>Connect using the native Hub. No tunnel or real sign-in is provided.</p>", config), "text/html; charset=utf-8")
        elif path.startswith("/node/stalled/"):
            # A genuine pending HTTP request, not an artificial native spinner.
            self.record(path, "stalled")
            self.server.stopping.wait(self.server.stall_seconds)
            if not self.server.stopping.is_set():
                self.send(504, page("<h1>Demo node timed out</h1>"), "text/html; charset=utf-8")
        elif path.startswith("/node/dev/"):
            self.send(200, page("<h1>Demo fixture chat</h1><p>Demo result ready</p><p>This is static local chat HTML, not the real chat frontend or an LLM response.</p>"), "text/html; charset=utf-8")
        elif path.startswith("/node/offline/"):
            self.send(503, page("<h1>Demo node offline</h1>"), "text/html; charset=utf-8")
        else:
            self.send(404, b'{"error":"unknown fixture route"}')

    def do_HEAD(self):
        self.do_GET()

    def do_POST(self):
        # Read-only capture: no fake success for mutations/authentication.
        self.send(405, b'{"error":"read-only demo fixture"}')

    do_DELETE = do_POST
    do_PATCH = do_POST


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8766)
    parser.add_argument("--request-log", required=True)
    args = parser.parse_args()
    # Fixed loopback bind. Never expose this synthetic-auth server to a LAN.
    with FixtureServer(("127.0.0.1", args.port), args.request_log) as server:
        print(f"{LABEL}: http://localhost:{args.port}/ (core {CORE_COMMIT})", flush=True)
        server.serve_forever()


if __name__ == "__main__":
    main()
