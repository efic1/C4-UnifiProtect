#!/usr/bin/env python3
"""Build gate: a top-level function must not call a top-level LOCAL function
defined later in the file. Lua resolves that name as a global at runtime,
finds nil, and throws - but only when the call path actually runs, so it
compiles cleanly and passes any test that doesn't exercise that path."""
import re, sys
src = open(sys.argv[1] if len(sys.argv) > 1 else 'driver.lua').read()
lines = src.split('\n')

forward = set(re.findall(r'^local\s+([A-Za-z_]\w*)\s*(?:--.*)?$', src, re.M))
top_locals = {}
for i, l in enumerate(lines, 1):
    m = re.match(r'local\s+function\s+([A-Za-z_]\w*)\s*\(', l)   # column 0 only
    if m: top_locals[m.group(1)] = i

# top-level function spans
spans, cur = [], None
for i, l in enumerate(lines, 1):
    if re.match(r'(local\s+)?function\s+[A-Za-z_][\w.:]*\s*\(', l):
        cur = i
    elif cur and l == 'end':
        spans.append((cur, i)); cur = None

problems = []
for a, b in spans:
    body = '\n'.join(lines[a:b])       # exclude the signature line itself
    for name in set(re.findall(r'\b([A-Za-z_]\w*)\s*\(', body)):
        if name in top_locals and top_locals[name] > a and name not in forward:
            problems.append(f"line {a}: calls local '{name}' defined later at line {top_locals[name]}")
if problems:
    print("FORWARD REFERENCE ERRORS:"); [print("  " + p) for p in problems]; sys.exit(1)
print(f"forward references ok ({len(spans)} functions checked)")
