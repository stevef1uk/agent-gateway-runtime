import base64
import copy
import argparse
import json
import os
import tempfile
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from email import policy
from email.parser import BytesParser
from pathlib import Path
from unittest.mock import patch

from connector import (Connector, FakeGmail, Handler, Ledger, LiveGmail,
                       ToolError, strict_json, validate_send)
from http.server import ThreadingHTTPServer
from ingress import Handler as IngressHandler, Server, validate_rpc
from demo import Demo, approval_snapshot, http


def message():
    return {"operation_id": "test-operation-001", "to": ["recipient@example.com"],
            "cc": [], "bcc": [], "subject": "Meeting", "body_text": "Tuesday at 10?",
            "reply_to_message_id": ""}


class LedgerTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name)
        self.ledger = Ledger(self.path / "ledger.sqlite")

    def test_concurrent_claims_only_send_once_and_replay_survives_restart(self):
        entered, release = threading.Event(), threading.Event()
        calls = []

        def send():
            calls.append(1)
            entered.set()
            release.wait(5)
            return {"id": "gmail-1"}

        with ThreadPoolExecutor(max_workers=2) as pool:
            first = pool.submit(self.ledger.send, "owner@example.com", message(), send)
            self.assertTrue(entered.wait(5))
            with self.assertRaisesRegex(ToolError, "uncertain"):
                self.ledger.send("owner@example.com", message(), send)
            release.set()
            result = first.result()
        restarted = Ledger(self.path / "ledger.sqlite")
        self.assertEqual(restarted.send("owner@example.com", message(), send), result)
        self.assertEqual(len(calls), 1)

    def test_lost_response_is_never_automatically_retried(self):
        def timeout():
            raise TimeoutError("response lost after Gmail accepted the message")
        with self.assertRaises(TimeoutError):
            self.ledger.send("owner@example.com", message(), timeout)
        restarted = Ledger(self.path / "ledger.sqlite")
        with self.assertRaisesRegex(ToolError, "uncertain"):
            restarted.send("owner@example.com", message(), lambda: self.fail("duplicate send"))
        self.assertEqual(restarted.evidence()[0]["state"], "uncertain")

    def test_each_content_change_conflicts_with_used_operation_id(self):
        original = message()
        self.ledger.send("owner@example.com", original, lambda: {"id": "gmail-1"})
        mutations = {"to": ["other@example.com"], "cc": ["c@example.com"], "bcc": ["b@example.com"],
                     "subject": "Changed", "body_text": "Changed", "reply_to_message_id": "source-2"}
        for key, value in mutations.items():
            changed = copy.deepcopy(original)
            changed[key] = value
            with self.subTest(field=key), self.assertRaisesRegex(ToolError, "different content"):
                self.ledger.send("owner@example.com", changed, lambda: self.fail("must not send"))

    def test_missing_gmail_id_stays_uncertain(self):
        with self.assertRaisesRegex(ToolError, "no message ID"):
            self.ledger.send("owner@example.com", message(), lambda: {})
        self.assertEqual(self.ledger.evidence()[0]["state"], "uncertain")


class ValidationTests(unittest.TestCase):
    def test_approval_preview_requires_complete_snapshot(self):
        summary = "send_email /mcp-gmail " + json.dumps(message())
        self.assertEqual(approval_snapshot({"summary": summary}), message())
        for invalid in (summary[:-5], "send_email /other {}", "digest-only-preview"):
            with self.assertRaises(RuntimeError):
                approval_snapshot({"summary": invalid})

    def test_dangerous_or_unreviewable_message_inputs_rejected(self):
        for key, value in (("subject", "Hi\r\nBcc: hidden@example.com"), ("to", ["Name <a@example.com>"]),
                           ("body_text", "a" * 4001), ("bcc", ["a@example.com\n"]),
                           ("operation_id", "../other"), ("reply_to_message_id", "a/b"),
                           ("to", []), ("cc", "hidden@example.com")):
            args = message()
            args[key] = value
            with self.subTest(field=key, value=str(value)[:40]), self.assertRaises(ToolError):
                validate_send(args)
        extra = message()
        extra["from"] = "attacker@example.com"
        with self.assertRaises(ToolError):
            validate_send(extra)

    def test_ambiguous_json_and_json_rpc_rejected(self):
        for data in ('{"method":"tools/list","method":"tools/call"}', '{"value":NaN}'):
            with self.assertRaises(ValueError):
                strict_json(data)
        valid = {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                 "params": {"name": "send_email", "arguments": message()}}
        validate_rpc(valid)
        for value in ([valid], {**valid, "id": None}, {**valid, "extra": "x"},
                      {**valid, "params": {"name": "drafts_send", "arguments": {}}}):
            with self.assertRaises(ValueError):
                validate_rpc(value)

    def test_mime_contains_only_snapshot_and_connected_sender(self):
        # Exercise the actual live Gmail MIME builder without Google credentials.
        backend = LiveGmail.__new__(LiveGmail)
        backend.mailbox = "owner@example.com"
        captured = []
        backend.api = lambda method, path, data: captured.append((method, path, data)) or {"id": "gmail-1"}
        args = message()
        args["cc"], args["bcc"] = ["copy@example.com"], ["blind@example.com"]
        backend.send(args)
        method, path, data = captured[0]
        self.assertEqual((method, path), ("POST", "/messages/send"))
        mime = BytesParser(policy=policy.default).parsebytes(base64.urlsafe_b64decode(data["raw"]))
        self.assertEqual(mime["From"], backend.mailbox)
        self.assertEqual(mime["To"], args["to"][0])
        self.assertEqual(mime["Cc"], args["cc"][0])
        self.assertEqual(mime["Bcc"], args["bcc"][0])
        self.assertEqual(mime.get_content().strip(), args["body_text"])
        first_id = mime["Message-ID"]
        backend.send(args)
        second = BytesParser(policy=policy.default).parsebytes(base64.urlsafe_b64decode(captured[1][2]["raw"]))
        self.assertEqual(first_id, second["Message-ID"])

    def test_reply_headers_come_from_source_not_agent(self):
        backend = LiveGmail.__new__(LiveGmail)
        backend.mailbox = "owner@example.com"
        captured = []
        backend.api = lambda method, path, data: captured.append(data) or {"id": "gmail-1"}
        backend.get = lambda _: {"thread_id": "thread-1", "message_id": "<source@example.com>", "references": ""}
        args = message()
        args["reply_to_message_id"] = "source-1"
        backend.send(args)
        self.assertEqual(captured[0]["threadId"], "thread-1")
        mime = BytesParser(policy=policy.default).parsebytes(base64.urlsafe_b64decode(captured[0]["raw"]))
        self.assertEqual(mime["In-Reply-To"], "<source@example.com>")


class HTTPTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        path = Path(self.directory.name)
        self.backend = FakeGmail(path / "fake.sqlite")
        self.connector = Connector(self.backend, Ledger(path / "ledger.sqlite"))
        self.upstream = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.upstream.connector = self.connector
        self.server = Server(("127.0.0.1", 0), IngressHandler)
        self.env = patch.dict("os.environ", {"GMAIL_PEP_URL": f"http://127.0.0.1:{self.upstream.server_port}",
                                            "GATEWAY_ADMIN_TOKEN": "operator-test-secret"})
        self.env.start()
        self.addCleanup(self.env.stop)
        for server in (self.upstream, self.server):
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            self.addCleanup(server.server_close)
            self.addCleanup(server.shutdown)
        self.url = f"http://127.0.0.1:{self.server.server_port}"

    def test_protocol_discovery_read_and_notification(self):
        for method, params in (("initialize", {"protocolVersion": "2025-03-26"}), ("tools/list", {}),
                               ("tools/call", {"name": "get_email", "arguments": {"message_id": "meeting-request"}})):
            _, result = http("POST", self.url + "/mcp-gmail", {"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
            self.assertIn("result", result)
        http("POST", self.url + "/mcp-gmail", {"jsonrpc": "2.0", "method": "notifications/initialized"}, expected=(202,))

    def test_ingress_rejects_spoofing_alternate_paths_and_batches(self):
        value = {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                 "params": {"name": "send_email", "arguments": message()}}
        for headers in ({"X-Agent-Action": "get_email"}, {"x-agent-resource": "/mcp"},
                        {"X-Agent-Tool": "search_email"}, {"Content-Encoding": "gzip"}):
            http("POST", self.url + "/mcp-gmail", value, headers, (400,))
        for path in ("/mcp", "/mcp-gmail/", "/mcp-gmail?other=1", "/gmail/v1/users/me/messages/send"):
            http("POST", self.url + path, value, expected=(404,))
        http("POST", self.url + "/mcp-gmail", [value], expected=(400,))
        http("POST", self.url + "/v1/approvals/", {}, expected=(401,))
        self.assertEqual(self.backend.evidence()["send_attempt_count"], 0)

    def test_unknown_or_malformed_tool_never_sends(self):
        for params in ({"name": "unknown", "arguments": {}}, {"name": "send_email", "arguments": {}}):
            http("POST", self.url + "/mcp-gmail", {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": params}, expected=(400,))
        self.assertEqual(self.backend.evidence()["send_attempt_count"], 0)


@unittest.skipUnless(os.environ.get("GMAIL_GATEWAY_TESTS") == "1", "requires running fake Gmail Compose stack")
class GatewayTests(unittest.TestCase):
    def setUp(self):
        self.demo = Demo(argparse.Namespace(yes=True, recipient=None, agent_config=None, expiry_check=False))
        self.addCleanup(self.demo.cleanup)
        self.demo.setup()
        self.assertEqual(self.demo.mode, "fake")

    def test_full_gateway_preview_and_real_agent_approval_desk(self):
        # Exercise the actual operator desk over a real pending MCP tool call,
        # not just the scripted walkthrough's locally-held message object.
        args = message()
        args["operation_id"] = "desk-" + self.demo.run_id
        args["body_text"] = "Preview line\n" + "x" * 3500
        _, approval = self.demo.call("send_email", args, (202,))
        _, rows = self.demo.request("GET", "/v1/approvals/", admin=True)
        row = next(r for r in rows if r["id"] == approval)
        self.assertEqual(approval_snapshot(row), args)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "agent.json"
            self.demo.args.agent_config = path
            with patch("builtins.input", return_value="SEND"), patch("demo.time.sleep", side_effect=KeyboardInterrupt), patch("builtins.print"):
                with self.assertRaises(KeyboardInterrupt):
                    self.demo.agent_session()
            self.assertFalse(path.exists())
        _, sent = self.demo.call("send_email", args)
        self.assertEqual(sent["status"], "sent")

    def test_initialized_notification(self):
        self.demo.mint()
        http("POST", self.demo.gw + "/mcp-gmail", {"jsonrpc": "2.0", "method": "notifications/initialized"},
             {"Authorization": "Bearer " + self.demo.token}, expected=(202, 204))


if __name__ == "__main__":
    unittest.main()
