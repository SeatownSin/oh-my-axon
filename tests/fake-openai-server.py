#!/usr/bin/env python3
"""A throwaway OpenAI-shaped /v1/models endpoint, for the gen-roles probe tests.

    python3 tests/fake-openai-server.py --id laguna --ctx 262144 [--require-auth TOKEN]

Binds 127.0.0.1 on a free port, prints "PORT <n>" on stdout, then serves until
killed. Port 0 rather than a fixed number so two test runs -- or a developer
and CI on the same box -- never collide.

The response deliberately mimics vLLM, nested modelperm-* "permission" objects
and all: those carry an "id" of their own, and a probe that counted them would
report models nobody is serving. Testing against a flat response would let that
bug through.

Loopback only, no state, no writes. --require-auth makes it answer 401 unless
the request carries a matching bearer token, which is how LM Studio behaves and
is the difference between "your server is down" and "your key is wrong".
"""

import argparse
import json
from http.server import BaseHTTPRequestHandler, HTTPServer


def build_payload(model_ids, ctx):
    data = []
    for mid in model_ids:
        entry = {
            "id": mid,
            "object": "model",
            "created": 1700000000,
            "owned_by": "vllm",
            "root": mid,
            "parent": None,
            "permission": [
                {
                    "id": "modelperm-0000000000000000",
                    "object": "model_permission",
                    "created": 1700000000,
                    "allow_sampling": True,
                }
            ],
        }
        if ctx:
            # Between the id and the nested permission id, matching vLLM: a
            # parser that attaches this to the wrong id shows up here.
            entry["max_model_len"] = ctx
        data.append(entry)
    return {"object": "list", "data": data}


def make_handler(payload, token):
    body = json.dumps(payload).encode("utf-8")

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):  # noqa: N802 - name fixed by BaseHTTPRequestHandler
            if token:
                sent = self.headers.get("Authorization", "")
                if sent != "Bearer " + token:
                    self.send_error(401, "unauthorized")
                    return
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_args):
            pass  # stdout carries the port line and nothing else

    return Handler


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--id", action="append", default=None,
                    help="model id to serve; repeatable")
    ap.add_argument("--ctx", type=int, default=0,
                    help="max_model_len to report; 0 omits the field entirely")
    ap.add_argument("--require-auth", default=None, metavar="TOKEN")
    args = ap.parse_args()

    payload = build_payload(args.id or ["test-model"], args.ctx)
    server = HTTPServer(("127.0.0.1", 0), make_handler(payload, args.require_auth))
    print("PORT %d" % server.server_address[1], flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
