#!/bin/sh
# Builds the detector helper into the plugin bundle. Requires only Xcode
# Command Line Tools (swiftc). Produces a native arm64 binary with no
# dependencies beyond macOS itself.
set -e
cd "$(dirname "$0")"
swiftc -O detect/main.swift -o frameline.lrplugin/frameline-detect
chmod +x frameline.lrplugin/frameline-detect
echo "built frameline.lrplugin/frameline-detect"
