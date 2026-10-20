#!/usr/bin/env python3
"""Stands in for the Moat API on loopback: every POST body is appended to BODIES, one
line each, and answered with the file ANSWER; the port goes to stdout once it listens"""

import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

bodies, answer = Path(sys.argv[1]), Path(sys.argv[2])


class Moat(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with bodies.open("a") as log:
            log.write(f"{self.headers.get('Content-Type')} {body.decode()}\n")
        reply = answer.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "application/vnd.api+json")
        self.send_header("Content-Length", str(len(reply)))
        self.end_headers()
        self.wfile.write(reply)

    def log_message(self, format, *args):
        pass


server = HTTPServer(("127.0.0.1", 0), Moat)
print(server.server_address[1], flush=True)
server.serve_forever()
