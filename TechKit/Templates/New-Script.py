#!/usr/bin/env python3
# @Name:        My New Python Script
# @Description: One sentence about what this script does.
# @Admin:       No
# @Changes:     No
# @Target:      Local
# @Param:       Host | string! | example.com | Host name to check
# @Param:       Count | int | 4 | How many attempts
# @Param:       Verbose | switch | | Show extra detail

# Tech Kit passes inputs as --Name value arguments. A What-If run adds --whatif.
# Print normally for output; print to stderr for errors (shown in red).
# Exit with a non-zero code to report failure.

import argparse
import platform
import socket
import sys

parser = argparse.ArgumentParser()
parser.add_argument("--Host", required=True)
parser.add_argument("--Count", type=int, default=4)
parser.add_argument("--Verbose", action="store_true")
parser.add_argument("--whatif", action="store_true")
args = parser.parse_args()

print(f"Running on {platform.node()} with Python {platform.python_version()}")
try:
    for i in range(args.Count):
        ip = socket.gethostbyname(args.Host)
        print(f"{args.Host} -> {ip}")
except OSError as exc:
    print(f"Lookup failed: {exc}", file=sys.stderr)
    sys.exit(1)
