#!/usr/bin/env bash
# Builds every driver into dist/, but only if every gate passes.
#
#   tools/build.sh           gates + tests + package
#   tools/build.sh --check   gates + tests only, no packaging (used by CI)
#
# Requires: lua5.1 (luac5.1), python3, zip.
set -euo pipefail
cd "$(dirname "$0")/.."

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

fail() { echo; echo "BUILD FAILED: $1" >&2; exit 1; }

# driver directory -> .c4z name. The camera name is load-bearing: the setup
# driver instantiates it by filename with C4:AddDevice.
declare -A ARTIFACT=(
  [drivers/camera]=unifi_protect_camera.c4z
  [drivers/setup]=unifi_protect_setup.c4z
)

for dir in drivers/camera drivers/setup; do
  echo "== $dir =="
  luac5.1 -p "$dir/driver.lua"               || fail "$dir/driver.lua does not compile"
  echo "   lua compiles"
  python3 -c "import xml.dom.minidom,sys; xml.dom.minidom.parse(sys.argv[1])" "$dir/driver.xml" \
                                             || fail "$dir/driver.xml is not well-formed"
  echo "   xml well-formed"
  python3 tools/check_forward_refs.py "$dir/driver.lua" | sed 's/^/   /' \
                                             || fail "$dir: forward reference to a later local"
  python3 tools/check_version.py "$dir"      || fail "$dir: version mismatch"
  python3 tools/check_structure.py "$dir"    || fail "$dir: structure"
done

echo "== cross-driver =="
want="${ARTIFACT[drivers/camera]}"
grep -q "local CAMERA_DRIVER   = \"$want\"" drivers/setup/driver.lua \
  || fail "setup driver's CAMERA_DRIVER must equal the camera artifact name ($want)"
echo "   setup driver targets $want"

echo "== tests =="
lua5.1 test/camera_tests.lua > /tmp/camera_tests.out 2>&1 || { cat /tmp/camera_tests.out; fail "camera tests"; }
grep -E "passed" /tmp/camera_tests.out | sed 's/^/   camera: /'
lua5.1 test/setup_tests.lua  > /tmp/setup_tests.out  2>&1 || { cat /tmp/setup_tests.out;  fail "setup tests"; }
grep -E "passed" /tmp/setup_tests.out  | sed 's/^/   setup:  /'

[ "$CHECK_ONLY" = 1 ] && { echo; echo "CHECKS OK"; exit 0; }

echo "== packaging =="
rm -rf dist && mkdir -p dist
for dir in drivers/camera drivers/setup; do
  out="$PWD/dist/${ARTIFACT[$dir]}"
  # A .c4z is a zip with driver.xml at its root.
  (cd "$dir" && zip -q -r "$out" driver.xml driver.lua www)
  ver=$(grep -o '<version>[0-9]*</version>' "$dir/driver.xml" | tr -dc 0-9)
  echo "   dist/${ARTIFACT[$dir]}  (version $ver)"
done
echo
echo "BUILD OK"
