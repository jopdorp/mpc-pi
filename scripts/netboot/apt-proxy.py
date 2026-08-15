#!/usr/bin/env python3
"""A forward proxy so the netbooted Pi can reach apt.

The Pi's only route is the netboot cable, and the far end of that cable
is a workstation, not a router. Giving the board real internet means NAT
plus forwarding plus a firewall policy change - three privileged changes
to someone's machine so that one appliance can run `apt install`.

A proxy needs none of them. It binds to the netboot address only, so it
is reachable from the Pi and from nothing else, and it runs as an
ordinary user because it listens above 1024. When the appliance is
finished it needs no internet at all, so the temporary thing should be
the one that leaves no trace on the host.

    apt-proxy.py [--bind 192.168.7.1] [--port 3142]

On the Pi:
    Acquire::http::Proxy "http://192.168.7.1:3142";
"""
import argparse
import select
import socket
import socketserver
import sys
import threading
import urllib.parse

TIMEOUT = 30
CHUNK = 65536


def pump(a, b):
    """Relay until either side closes. Both directions, one loop, so a
    half-closed connection cannot wedge a thread."""
    socks = [a, b]
    try:
        while True:
            r, _, x = select.select(socks, [], socks, TIMEOUT)
            if x or not r:
                return
            for s in r:
                data = s.recv(CHUNK)
                if not data:
                    return
                (b if s is a else a).sendall(data)
    except (OSError, ValueError):
        return


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(TIMEOUT)
        try:
            head = self._read_head()
        except (OSError, ValueError):
            return
        if not head:
            return
        line = head.split(b"\r\n", 1)[0].decode("latin-1")
        parts = line.split()
        if len(parts) != 3:
            return
        method, target, _ = parts
        if method == "CONNECT":
            self._connect(target)
        else:
            self._forward(method, target, head)

    def _read_head(self):
        """Read up to the end of the request headers, and no further.

        Anything after the blank line is the body, which belongs to the
        upstream connection - reading it here would swallow it.
        """
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = self.request.recv(CHUNK)
            if not chunk:
                return buf
            buf += chunk
            if len(buf) > 65536:
                raise ValueError("request head too large")
        return buf

    def _connect(self, target):
        host, _, port = target.partition(":")
        try:
            up = socket.create_connection((host, int(port or 443)), TIMEOUT)
        except OSError:
            self.request.sendall(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
            return
        self.request.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
        with up:
            pump(self.request, up)

    def _forward(self, method, target, head):
        u = urllib.parse.urlsplit(target)
        if not u.hostname:
            self.request.sendall(b"HTTP/1.1 400 Bad Request\r\n\r\n")
            return
        path = u.path or "/"
        if u.query:
            path += "?" + u.query

        rest = head.split(b"\r\n", 1)[1]
        lines = [l for l in rest.split(b"\r\n")
                 if not l.lower().startswith(b"proxy-connection:")
                 and not l.lower().startswith(b"connection:")]
        # Keep-alive across a proxy means tracking message framing for
        # both directions. Closing instead costs a handshake per file and
        # removes every way to desynchronise the stream.
        out = ("%s %s HTTP/1.1\r\n" % (method, path)).encode("latin-1")
        out += b"\r\n".join(lines).rstrip(b"\r\n")
        out += b"\r\nConnection: close\r\n\r\n"

        try:
            up = socket.create_connection((u.hostname, u.port or 80), TIMEOUT)
        except OSError:
            self.request.sendall(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
            return
        with up:
            up.sendall(out)
            pump(self.request, up)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bind", default="192.168.7.1")
    ap.add_argument("--port", type=int, default=3142)
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    srv = Server((args.bind, args.port), Handler)
    print("apt proxy on %s:%d" % (args.bind, args.port), flush=True)
    srv.serve_forever()


def self_test():
    """Proxy a real request through a loopback instance."""
    srv = Server(("127.0.0.1", 0), Handler)
    port = srv.server_address[1]
    threading.Thread(target=srv.serve_forever, daemon=True).start()

    # A plain HTTP origin server to fetch through the proxy.
    class Origin(socketserver.BaseRequestHandler):
        def handle(self):
            self.request.recv(4096)
            self.request.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n"
                                 b"Connection: close\r\n\r\nhi")

    osrv = Server(("127.0.0.1", 0), Origin)
    oport = osrv.server_address[1]
    threading.Thread(target=osrv.serve_forever, daemon=True).start()

    c = socket.create_connection(("127.0.0.1", port), 5)
    c.sendall(("GET http://127.0.0.1:%d/x HTTP/1.1\r\nHost: 127.0.0.1\r\n"
               "\r\n" % oport).encode())
    got = b""
    c.settimeout(5)
    try:
        while True:
            b = c.recv(4096)
            if not b:
                break
            got += b
    except OSError:
        pass
    assert got.startswith(b"HTTP/1.1 200"), got[:60]
    assert got.endswith(b"hi"), got[-20:]
    print("apt-proxy self-test PASS: absolute-URI request proxied end to end")
    return 0


if __name__ == "__main__":
    sys.exit(main())
