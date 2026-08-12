#!/usr/bin/env python3
"""Read-only SNMP v2c port/MAC checker for the Dell N2048 (stdlib only).

Usage:
    python3 scripts/network/snmp-port-check.py [community] [switch_ip]
    N2048_SNMP_COMMUNITY=<community> python3 scripts/network/snmp-port-check.py

Community comes from the first argument or the N2048_SNMP_COMMUNITY
environment variable (secrets manager — never hardcode). Prints per-port
link status (ifOperStatus) and the bridge MAC->port table so a crossed
cable can be located without an SSH session. NOTE: the original rw
community from the 2026-07-31 snapshot was removed 2026-08-08 (issue #26);
the switch now carries a read-only community only.
"""

import os
import re
import socket
import sys

COMMUNITY = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("N2048_SNMP_COMMUNITY", "")
HOST = sys.argv[2] if len(sys.argv) > 2 else "10.10.10.2"

if not COMMUNITY:
    sys.exit("Usage: snmp-port-check.py <community> [switch_ip] "
             "(or set N2048_SNMP_COMMUNITY)")

IF_DESCR = (1, 3, 6, 1, 2, 1, 2, 2, 1, 2)      # ifDescr
IF_OPER = (1, 3, 6, 1, 2, 1, 2, 2, 1, 8)       # ifOperStatus 1=up 2=down
FDB_ADDR = (1, 3, 6, 1, 2, 1, 17, 4, 3, 1, 1)  # dot1dTpFdbAddress
FDB_PORT = (1, 3, 6, 1, 2, 1, 17, 4, 3, 1, 2)  # dot1dTpFdbPort


def enc_len(n):
    if n < 0x80:
        return bytes([n])
    out = b""
    while n:
        out = bytes([n & 0xFF]) + out
        n >>= 8
    return bytes([0x80 | len(out)]) + out


def enc_int(v):
    if v == 0:
        return b"\x02\x01\x00"
    out = b""
    n = v
    while n:
        out = bytes([n & 0xFF]) + out
        n >>= 8
    if out[0] & 0x80:
        out = b"\x00" + out
    return bytes([0x02, len(out)]) + out


def enc_oid(oid):
    out = bytes([40 * oid[0] + oid[1]])
    for sub in oid[2:]:
        chunk = b""
        chunk = bytes([sub & 0x7F]) + chunk
        sub >>= 7
        while sub:
            chunk = bytes([0x80 | (sub & 0x7F)]) + chunk
            sub >>= 7
        out += chunk
    return bytes([0x06, len(out)]) + out


def enc_seq(payload, tag=0x30):
    return bytes([tag]) + enc_len(len(payload)) + payload


def getnext(oids, req_id):
    vbs = b"".join(enc_seq(enc_oid(o) + b"\x05\x00") for o in oids)
    pdu = enc_int(req_id) + enc_int(0) + enc_int(0) + enc_seq(vbs)
    msg = enc_seq(enc_int(1) + enc_seq(COMMUNITY.encode(), 0x04) + enc_seq(pdu, 0xA1))
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(5)
    try:
        s.sendto(msg, (HOST, 161))
        data, _ = s.recvfrom(65535)
    finally:
        s.close()
    return parse_varbinds(data)


def parse(data):
    """Yield (tag, value_bytes, rest) TLVs."""
    i = 0
    while i < len(data):
        tag = data[i]
        i += 1
        l = data[i]
        i += 1
        if l & 0x80:
            n = l & 0x7F
            l = int.from_bytes(data[i:i + n], "big")
            i += n
        yield tag, data[i:i + l]
        i += l


def parse_varbinds(data):
    _, outer = next(parse(data))          # message seq
    it = parse(outer)
    next(it)                              # version
    next(it)                              # community
    _, pdu = next(it)
    pit = parse(pdu)
    next(pit)                             # req id
    next(pit)                             # error status
    next(pit)                             # error index
    _, vbs = next(pit)
    out = []
    for _, vb in parse(vbs):
        vit = parse(vb)
        _, oid_b = next(vit)
        vtag, vval = next(vit)
        out.append((dec_oid(oid_b), vtag, vval))
    return out


def dec_oid(b):
    oid = [b[0] // 40, b[0] % 40]
    acc = 0
    for byte in b[1:]:
        acc = (acc << 7) | (byte & 0x7F)
        if not byte & 0x80:
            oid.append(acc)
            acc = 0
    return tuple(oid)


def walk(base):
    results = []
    current = base
    req_id = 1
    while True:
        vbs = getnext([current], req_id)
        req_id += 1
        if not vbs:
            break
        oid, tag, val = vbs[0]
        if tag == 0x05 or oid[:len(base)] != base:
            break
        results.append((oid, tag, val))
        current = oid
    return results


def port_no(descr):
    m = re.search(r"Port:\s*(\d+)", descr)
    return int(m.group(1)) if m else None


def main():
    descs = {oid: val.decode(errors="replace") for oid, tag, val in walk(IF_DESCR)}
    opers = {oid[-1]: int.from_bytes(val, "big") for oid, tag, val in walk(IF_OPER)}
    print("== Port link status (oper: 1=up 2=down) ==")
    for oid in sorted(descs, key=lambda o: port_no(descs[o]) or 999):
        p = port_no(descs[oid])
        if p is not None:
            print(f"  Gi1/0/{p:<2d} oper={opers.get(oid[-1], '?')}")
    print("== Bridge MAC table (vlan.mac -> port) ==")
    ports = {oid: int.from_bytes(val, "big") for oid, tag, val in walk(FDB_PORT)}
    for oid, tag, val in walk(FDB_ADDR):
        if len(val) == 6:
            mac = ":".join(f"{b:02x}" for b in val)
            suffix = oid[len(FDB_ADDR):]
            port_ifidx = ports.get(FDB_PORT + suffix)
            name = next((d for o, d in descs.items() if o[-1] == port_ifidx), f"if{port_ifidx}")
            print(f"  vlan={suffix[0]} mac={mac} -> {name}")


if __name__ == "__main__":
    main()
