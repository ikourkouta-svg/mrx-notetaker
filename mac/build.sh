#!/bin/bash
# Builds MRXNotetaker.app (universal, ad-hoc signed) and MRXNotetaker.zip. Runs on macOS only.
set -euo pipefail
cd "$(dirname "$0")"
rm -rf build && mkdir -p build/MRXNotetaker.app/Contents/MacOS
# whisper.cpp (Metal) powers the live copilot; static build so the app ships one binary, no dylibs.
git clone --depth 1 https://github.com/ggml-org/whisper.cpp build/whisper.cpp
for arch in arm64 x86_64; do
  cmake -S build/whisper.cpp -B "build/w-$arch" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF \
        -DWHISPER_BUILD_EXAMPLES=ON -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF \
        -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET=14.2
  cmake --build "build/w-$arch" --config Release -j"$(sysctl -n hw.ncpu)" --target whisper-cli
  swiftc -O -target "$arch-apple-macos14.2" main.swift copilot.swift -o "build/MRXNotetaker-$arch"
done
lipo -create build/w-arm64/bin/whisper-cli build/w-x86_64/bin/whisper-cli -output build/whisper-cli
lipo -create build/MRXNotetaker-arm64 build/MRXNotetaker-x86_64 -output build/MRXNotetaker.app/Contents/MacOS/MRXNotetaker
cp Info.plist build/MRXNotetaker.app/Contents/Info.plist
cp build/whisper-cli build/MRXNotetaker.app/Contents/MacOS/whisper-cli
# nested binaries must be signed before the bundle that contains them
codesign --force --sign - build/MRXNotetaker.app/Contents/MacOS/whisper-cli
codesign --force --sign - build/MRXNotetaker.app   # ad-hoc: no Apple developer account needed
(cd build && ditto -c -k --keepParent MRXNotetaker.app MRXNotetaker.zip)
