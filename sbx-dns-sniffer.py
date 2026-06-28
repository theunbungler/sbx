#!/usr/bin/env python3
"""
sbx-dns-sniffer — a tiny DNS forwarding proxy that programs an nftables set.

Why this exists
---------------
sbx enforces network egress with nftables: the output chain defaults to DROP
and only permits connections to IPs held in the `allowed4` set (plus a few
fixed rules for loopback and the upstream resolver). Something has to put the
*right* IPs into that set — namely, the IPs that were actually resolved for the
profile's allowed domains, and nothing else.

dnsmasq can do this (its `nftset=` option), but it unconditionally calls
setgroups() on startup, which is denied inside the unprivileged user namespace
that pasta creates (the kernel forbids re-enabling setgroups in a child userns
once a parent has set it to "deny"). So dnsmasq cannot run here at all.

This proxy does the one extra thing dnsmasq gave us, without dropping
privileges: it sits on 127.0.0.1:53, forwards every query to the real resolver
(dnscrypt-proxy, which already enforces the domain allow-list), parses the A
records out of the reply, adds them to the nftables set, and returns the reply
unchanged. A name the resolver refuses yields no usable address, so nothing is
added and nftables still blocks the connection. A process that dials a raw IP
the resolver never returned is dropped, closing the IP-literal / direct-to-DNS
bypass.

It runs as root and never calls setgroups/setgid/setuid.
"""

import argparse
import socket
import struct
import subprocess
import sys
import threading

BUFSIZE = 4096


def skip_name(msg: bytes, off: int) -> int:
    """Return the offset just past the DNS name starting at `off`."""
    while True:
        if off >= len(msg):
            raise ValueError("truncated name")
        length = msg[off]
        if length == 0:
            return off + 1
        if length & 0xC0 == 0xC0:  # compression pointer terminates the name
            return off + 2
        off += 1 + length


def extract_a_records(msg: bytes):
    """Yield dotted-quad IPv4 strings from the answer section of a DNS reply."""
    if len(msg) < 12:
        return
    qd = struct.unpack("!H", msg[4:6])[0]
    an = struct.unpack("!H", msg[6:8])[0]
    off = 12
    try:
        for _ in range(qd):
            off = skip_name(msg, off) + 4  # QTYPE + QCLASS
        for _ in range(an):
            off = skip_name(msg, off)
            rtype, rclass = struct.unpack("!HH", msg[off:off + 4])
            rdlen = struct.unpack("!H", msg[off + 8:off + 10])[0]
            rdata = msg[off + 10:off + 10 + rdlen]
            off += 10 + rdlen
            if rtype == 1 and rclass == 1 and rdlen == 4:  # A / IN
                yield "%d.%d.%d.%d" % tuple(rdata)
    except (struct.error, ValueError, IndexError):
        return  # malformed packet: forward it anyway, just don't add IPs


class SetUpdater:
    """Adds IPv4 addresses to an nftables set (de-duplicated, best effort)."""

    def __init__(self, family: str, table: str, name: str):
        self.spec = (family, table, name)
        self._seen = set()
        self._lock = threading.Lock()

    def add(self, ips):
        with self._lock:
            fresh = [ip for ip in ips if ip not in self._seen and ip != "0.0.0.0"]
            self._seen.update(fresh)
        if not fresh:
            return
        family, table, name = self.spec
        element = "{ %s }" % ", ".join(fresh)
        try:
            subprocess.run(
                ["nft", "add", "element", family, table, name, element],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except OSError:
            pass


def handle_payload(query: bytes, upstream, use_tcp: bool, updater: SetUpdater) -> bytes:
    """Forward one DNS message to the upstream resolver and return the reply."""
    if use_tcp:
        with socket.create_connection(upstream, timeout=5) as s:
            s.sendall(struct.pack("!H", len(query)) + query)
            hdr = _recv_exact(s, 2)
            reply = _recv_exact(s, struct.unpack("!H", hdr)[0])
    else:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.settimeout(5)
            s.sendto(query, upstream)
            reply, _ = s.recvfrom(BUFSIZE)
    updater.add(list(extract_a_records(reply)))
    return reply


def _recv_exact(sock: socket.socket, n: int) -> bytes:
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("short read from upstream")
        buf += chunk
    return buf


def bind_udp(listen):
    srv = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(listen)
    return srv


def serve_udp(srv, upstream, updater: SetUpdater):
    def worker(data, addr):
        try:
            srv.sendto(handle_payload(data, upstream, False, updater), addr)
        except OSError:
            pass

    while True:
        try:
            data, addr = srv.recvfrom(BUFSIZE)
        except OSError:
            continue
        threading.Thread(target=worker, args=(data, addr), daemon=True).start()


def serve_tcp(listen, upstream, updater: SetUpdater):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(listen)
    srv.listen(64)

    def worker(conn):
        with conn:
            try:
                hdr = _recv_exact(conn, 2)
                query = _recv_exact(conn, struct.unpack("!H", hdr)[0])
                reply = handle_payload(query, upstream, True, updater)
                conn.sendall(struct.pack("!H", len(reply)) + reply)
            except OSError:
                pass

    while True:
        try:
            conn, _ = srv.accept()
        except OSError:
            continue
        threading.Thread(target=worker, args=(conn,), daemon=True).start()


def parse_hostport(value: str, default_port: int):
    host, _, port = value.partition(":")
    return (host, int(port) if port else default_port)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--listen", default="127.0.0.1:53")
    ap.add_argument("--upstream", default="127.0.0.1:5300")
    ap.add_argument("--nft-family", default="inet")
    ap.add_argument("--nft-table", default="sbx_filter")
    ap.add_argument("--nft-set", default="allowed4")
    args = ap.parse_args()

    listen = parse_hostport(args.listen, 53)
    upstream = parse_hostport(args.upstream, 5300)
    updater = SetUpdater(args.nft_family, args.nft_table, args.nft_set)

    udp = bind_udp(listen)
    threading.Thread(target=serve_tcp, args=(listen, upstream, updater), daemon=True).start()
    # Announce readiness only once the listening socket is actually bound.
    print("sbx-dns-sniffer listening on %s:%d -> %s:%d" % (listen + upstream),
          flush=True)
    serve_udp(udp, upstream, updater)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
