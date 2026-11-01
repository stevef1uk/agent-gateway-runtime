#!/usr/bin/env python3
"""Constrained HTTP front door. The unexposed PEP is the sole upstream.

Reject override headers, alternate paths, batches and ambiguous JSON BEFORE
gateway authorization. This prevents tool/action relabeling by an agent.
"""
import json
import os
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from connector import MAX_BODY, ToolError, strict_json, validate_send


def validate_rpc(value):
    if not isinstance(value, dict) or value.get("jsonrpc") != "2.0":
        raise ValueError("single JSON-RPC object required; batches disabled")
    if set(value) - {"jsonrpc", "id", "method", "params"}:
        raise ValueError("unknown JSON-RPC fields")
    if "id" in value and type(value["id"]) not in (int, str):
        raise ValueError("invalid request ID")
    method, params = value.get("method"), value.get("params", {})
    if not isinstance(params, dict):
        raise ValueError("params must be an object")
    if method == "notifications/initialized" and "id" not in value:
        return
    if "id" not in value:
        raise ValueError("request ID required")
    if method not in ("initialize", "tools/list", "tools/call", "ping"):
        raise ValueError("unsupported MCP method")
    if method == "tools/call":
        if set(params) != {"name", "arguments"}:
            raise ValueError("tool name and arguments required")
        name, args = params["name"], params["arguments"]
        if name not in ("search_email", "get_email", "send_email") or not isinstance(args, dict):
            raise ValueError("unsupported tool")
        if name == "send_email":
            validate_send(args)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *_):
        return None


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def respond(self, code, data, content_type="application/json"):
        if not isinstance(data, bytes):
            data = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(data)

    def proxy(self):
        if any(key.lower().startswith("x-agent-") for key in self.headers):
            return self.respond(400, {"error": "caller-supplied X-Agent-* headers forbidden"})
        if self.headers.get("Transfer-Encoding") or self.headers.get("Content-Encoding"):
            return self.respond(400, {"error": "encoded/streamed request bodies forbidden"})
        path = self.path
        management = path == "/v1/approvals/" or path.startswith("/v1/audit/?")
        if not (path in ("/healthz", "/mcp-gmail") or management):
            return self.respond(404, {"error": "path not exposed"})
        if management and self.headers.get("X-Admin-Token") != os.environ["GATEWAY_ADMIN_TOKEN"]:
            return self.respond(401, {"error": "operator credential required"})
        if self.command == "GET" and path == "/mcp-gmail":
            return self.respond(405, {"error": "stateless MCP; SSE GET not supported"})
        if self.command == "POST" and path not in ("/mcp-gmail", "/v1/approvals/"):
            return self.respond(405, {"error": "method not exposed"})
        body = None
        if self.command == "POST":
            try:
                lengths = self.headers.get_all("Content-Length", [])
                if len(lengths) != 1 or not lengths[0].isdigit():
                    raise ValueError("one Content-Length required")
                length = int(lengths[0])
                if not 0 < length <= MAX_BODY:
                    raise ValueError("body too large or empty")
                if self.headers.get_content_type() != "application/json":
                    raise ValueError("application/json required")
                body = self.rfile.read(length)
                if len(body) != length:
                    raise ValueError("incomplete request")
                value = strict_json(body)
                if path == "/mcp-gmail":
                    validate_rpc(value)
            except (ValueError, UnicodeError, ToolError) as error:
                return self.respond(400, {"error": str(error)})
        headers = {key: self.headers[key] for key in
                   ("Authorization", "X-Admin-Token", "MCP-Protocol-Version") if key in self.headers}
        headers.update({"Content-Type": "application/json", "Accept": "application/json, text/event-stream"})
        req = urllib.request.Request(os.environ.get("GMAIL_PEP_URL", "http://gateway-gmail:8080") + path,
                                     data=body, headers=headers, method=self.command)
        try:
            opener = urllib.request.build_opener(NoRedirect())
            try:
                response = opener.open(req, timeout=35)
            except urllib.error.HTTPError as error:
                response = error
            with response:
                data = response.read(1048577)
                if len(data) > 1048576:
                    raise ValueError("upstream response too large")
                if path == "/healthz" and response.status == 200:
                    mode = os.environ.get("GMAIL_MODE", "fake")
                    data = json.dumps({"ok": True, "mode": mode,
                                       "mailbox": os.environ.get("GMAIL_MAILBOX") if mode == "live" else "owner@example.com"}).encode()
                self.respond(response.status, data, response.headers.get("Content-Type", "application/json"))
        except (OSError, ValueError):
            self.respond(502, {"error": "gateway unavailable; do not assume an email was sent"})

    do_GET = proxy
    do_POST = proxy


class Server(ThreadingHTTPServer):
    def get_request(self):
        sock, addr = super().get_request()
        sock.settimeout(40)
        return sock, addr


if __name__ == "__main__":
    if not os.environ.get("GATEWAY_ADMIN_TOKEN"):
        raise SystemExit("GATEWAY_ADMIN_TOKEN required")
    Server(("0.0.0.0", 8093), Handler).serve_forever()
