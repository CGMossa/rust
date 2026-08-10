#!/usr/bin/env python3
"""Run a mingw-gcc link but execute the final ld step with rust-lld (MinGW driver).
Usage: lldgcc.py <gcc-args...>   (same args you would pass to x86_64-w64-mingw32-gcc)"""
import shlex, subprocess, sys, os

GCC = "x86_64-w64-mingw32-gcc"
SHIM = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ld.lld")

r = subprocess.run([GCC, "-###"] + sys.argv[1:], capture_output=True, text=True)
cand = [l for l in r.stderr.splitlines() if "collect2" in l and "COLLECT" not in l]
if not cand:
    sys.stderr.write(r.stderr)
    sys.exit("no ld line found in gcc -### output")
args = shlex.split(cand[-1])
out = [SHIM]
skip = False
for a in args[1:]:
    if skip: skip = False; continue
    if a == "-plugin": skip = True; continue
    if a.startswith("-plugin-opt="): continue
    out.append(a)
os.execv(SHIM, out)
