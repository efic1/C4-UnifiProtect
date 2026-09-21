#!/usr/bin/env python3
"""Gate: DRIVER_VERSION in driver.lua must equal <version> in driver.xml.

Composer compares the XML <version> integer to decide whether an update is
newer; the Lua constant is what the driver reports in its Driver Version
property. When they drifted apart, the installed driver displayed a number
that matched nothing.

Usage: check_version.py <driver-directory>
"""
import re, sys, os

d = sys.argv[1] if len(sys.argv) > 1 else "."
xml = re.search(r'<version>(\d+)</version>', open(os.path.join(d, "driver.xml")).read())
lua = re.search(r'local DRIVER_VERSION = "([^"]*)"', open(os.path.join(d, "driver.lua")).read())
if not xml or not lua:
    sys.exit(f"{d}: could not find a version in driver.xml or driver.lua")
if xml.group(1) != lua.group(1):
    sys.exit(f"{d}: VERSION MISMATCH driver.xml={xml.group(1)} driver.lua={lua.group(1)}")
print(f"   version {xml.group(1)} consistent")
