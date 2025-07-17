#!/usr/bin/env python3

from http.server import BaseHTTPRequestHandler, HTTPServer
from sys import argv


def factory(file):
    h = handler
    h.file = file
    return h


class handler(BaseHTTPRequestHandler):
    def do_POST(self):
        self.send_response(200)
        self.send_header('Content-type', 'application/json')
        with open(self.file, 'w+') as f:
            f.write(f"{self.path}\n")
            length = int(self.headers.get('content-length', 0))
            body = str(self.rfile.read(length).decode("utf-8"))

            f.write(f"{body}")
        self.end_headers()

        message = "{}"
        self.wfile.write(bytes(message, "utf8"))


if __name__ == '__main__':
    try:
        assert len(argv) > 1
        with HTTPServer(('localhost', 8282), factory(argv[1])) as server:
            server.serve_forever()
    except KeyboardInterrupt:
        pass
