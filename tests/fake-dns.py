#!/usr/bin/env python3
"""A DNS server for the suite: binds ADDR:53, answers every A query with 10.9.9.9 and
every other type with no records, and appends each queried name to LOG. Prints `ready`
once it listens."""

import socket
import struct
import sys

addr, log = sys.argv[1], sys.argv[2]
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind((addr, 53))
print("ready", flush=True)
while True:
    data, peer = sock.recvfrom(512)
    ident = struct.unpack(">H", data[:2])[0]
    i, labels = 12, []
    while data[i]:
        labels.append(data[i + 1 : i + 1 + data[i]].decode())
        i += data[i] + 1
    question = data[12 : i + 5]
    qtype = struct.unpack(">H", data[i + 1 : i + 3])[0]
    with open(log, "a") as f:
        f.write(".".join(labels) + "\n")
    answer, count = b"", 0
    if qtype == 1:
        answer = b"\xc0\x0c" + struct.pack(">HHIH", 1, 1, 60, 4) + bytes([10, 9, 9, 9])
        count = 1
    header = struct.pack(">HHHHHH", ident, 0x8180, 1, count, 0, 0)
    sock.sendto(header + question + answer, peer)
