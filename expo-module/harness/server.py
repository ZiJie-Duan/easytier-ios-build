#!/usr/bin/env python3
"""Host-side helpers for the Expo module e2e test (the simulator shares host loopback).

  127.0.0.1:8080   the "service behind the hub": GET -> 200 "hello-from-hub ..."
                   (the no_tun hub dials 127.0.0.1:8080 for traffic to 10.144.144.50:8080)
  127.0.0.1:18999  result collector: POST /result -> written to argv[1]
"""
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

RESULT_PATH = sys.argv[1]


class Service(BaseHTTPRequestHandler):
    def do_GET(self):
        body = f"hello-from-hub path={self.path}\n".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        print(f"[service] GET {self.path} from {self.client_address}", flush=True)


class Collector(BaseHTTPRequestHandler):
    def do_POST(self):
        data = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        with open(RESULT_PATH + ".tmp", "wb") as f:
            f.write(data)
        import os
        os.replace(RESULT_PATH + ".tmp", RESULT_PATH)
        self.send_response(204)
        self.end_headers()
        print(f"[collector] got {len(data)} bytes", flush=True)


def serve(port, handler):
    ThreadingHTTPServer(("127.0.0.1", port), handler).serve_forever()


threading.Thread(target=serve, args=(8080, Service), daemon=True).start()
print("[server] listening on 127.0.0.1:8080 and 127.0.0.1:18999", flush=True)
serve(18999, Collector)
