#!/usr/bin/env python3
# @Name:        TLS Certificate Check (Python)
# @Description: Connects to HTTPS hosts and reports certificate expiry, days left and issuer, flagging invalid or soon-to-expire certificates. Example Python script (needs Python on the PC or in Runtimes\python).
# @Admin:       No
# @Changes:     No
# @Target:      Local
# @Param:       Hosts | list! | | Host names, optionally host:port, one per line
# @Param:       WarnDays | int | 30 | Warn when a certificate expires within this many days
# @Tags:        python, tls, ssl, certificate, expiry, https

import argparse
import datetime
import socket
import ssl
import sys

parser = argparse.ArgumentParser()
parser.add_argument("--Hosts", required=True)
parser.add_argument("--WarnDays", type=int, default=30)
parser.add_argument("--whatif", action="store_true")
args = parser.parse_args()

hosts = [h.strip() for h in args.Hosts.replace(";", ",").split(",") if h.strip()]
ctx = ssl.create_default_context()
now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
problems = 0

print(f"{'Host':<38} {'Days':>5}  {'Expires':<10}  Issuer")
for entry in hosts:
    host, _, port = entry.partition(":")
    port = int(port or 443)
    try:
        with socket.create_connection((host, port), timeout=8) as raw:
            with ctx.wrap_socket(raw, server_hostname=host) as tls:
                cert = tls.getpeercert()
        expires = datetime.datetime.strptime(cert["notAfter"], "%b %d %H:%M:%S %Y %Z")
        days = (expires - now).days
        issuer = dict(item[0] for item in cert.get("issuer", [])).get("organizationName", "?")
        flag = ""
        if days < args.WarnDays:
            flag = "   <-- WARN"
            problems += 1
        print(f"{entry:<38} {days:>5}  {expires:%Y-%m-%d}  {issuer}{flag}")
    except ssl.SSLCertVerificationError as exc:
        problems += 1
        print(f"{entry:<38} INVALID: {exc.verify_message}", file=sys.stderr)
    except OSError as exc:
        problems += 1
        print(f"{entry:<38} ERROR: {exc}", file=sys.stderr)

sys.exit(1 if problems else 0)
