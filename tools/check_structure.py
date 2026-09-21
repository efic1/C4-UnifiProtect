#!/usr/bin/env python3
"""Gate: structural rules for a DriverWorks driver.xml.

Every rule here exists because breaking it shipped a driver that loaded
without error but did not work:

  * <properties>, <actions>, <script> and <documentation> must sit inside
    <config>. Outside it, Composer silently ignores them: the driver loads with
    no settings, no actions and no documentation.
  * Every writable property needs a handler in driver.lua, or editing it in
    Composer does nothing.
  * Every action's <command> must be dispatched in driver.lua.
  * Every <event> needs an <id> (unique) and a <description>. Missing
    descriptions broke the Programming tab.
  * No empty <states/>. It also broke the Programming tab.

Usage: check_structure.py <driver-directory>
"""
import os, re, sys, xml.dom.minidom as minidom

d = sys.argv[1] if len(sys.argv) > 1 else "."
doc = minidom.parse(os.path.join(d, "driver.xml"))
raw = open(os.path.join(d, "driver.xml")).read()
lua = open(os.path.join(d, "driver.lua")).read()
errors = []

cfg = doc.getElementsByTagName("config")
if not cfg:
    errors.append("no <config> element")
else:
    kids = [c.tagName for c in cfg[0].childNodes if c.nodeType == 1]
    for required in ("properties", "actions", "script", "documentation"):
        if required not in kids:
            errors.append(f"<{required}> must be inside <config> (found {kids})")

handled = set(re.findall(r'name == "([^"]+)"', lua))
for p in doc.getElementsByTagName("property"):
    name = p.getElementsByTagName("name")[0].firstChild.data
    ro = p.getElementsByTagName("readonly")[0].firstChild.data == "true"
    if not ro and name not in handled:
        errors.append(f"writable property '{name}' has no handler")

for a in doc.getElementsByTagName("action"):
    cmd = a.getElementsByTagName("command")[0].firstChild.data
    if f'"{cmd}"' not in lua:
        errors.append(f"action command '{cmd}' is never dispatched")

ids = set()
for e in doc.getElementsByTagName("event"):
    name = e.getElementsByTagName("name")[0].firstChild.data
    idn = e.getElementsByTagName("id")
    if not idn:
        errors.append(f"event '{name}' has no <id>")
    else:
        i = idn[0].firstChild.data
        if i in ids:
            errors.append(f"duplicate event id {i}")
        ids.add(i)
    if not e.getElementsByTagName("description"):
        errors.append(f"event '{name}' has no <description>")

if re.search(r"<states\s*/>|<states>\s*</states>", raw):
    errors.append("empty <states> element")

if errors:
    print(f"{d}: STRUCTURE ERRORS")
    for e in errors:
        print("   " + e)
    sys.exit(1)
print("   structure ok")
