.PHONY: build check test clean

build:   ## gates + tests + package into dist/
	tools/build.sh

check:   ## gates + tests, no packaging
	tools/build.sh --check

test:    ## tests only
	lua5.1 test/camera_tests.lua
	lua5.1 test/setup_tests.lua

clean:
	rm -rf dist
