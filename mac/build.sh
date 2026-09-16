#!/bin/bash
# Builds MRXNotetaker.app (universal, ad-hoc signed) and MRXNotetaker.zip. Runs on macOS only.
set -euo pipefail
cd "$(dirname "$0")"
rm -rf build && mkdir -p build/MRXNotetaker.app/Contents/MacOS
for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos14.2" main.swift -o "build/MRXNotetaker-$arch"
done
lipo -create build/MRXNotetaker-arm64 build/MRXNotetaker-x86_64 -output build/MRXNotetaker.app/Contents/MacOS/MRXNotetaker
cp Info.plist build/MRXNotetaker.app/Contents/Info.plist
codesign --force --sign - build/MRXNotetaker.app   # ad-hoc: no Apple developer account needed
(cd build && ditto -c -k --keepParent MRXNotetaker.app MRXNotetaker.zip)
