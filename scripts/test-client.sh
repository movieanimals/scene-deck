#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
BUILD="$PWD/.build/local"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$BUILD/module-cache"
FLAGS=(-sdk "$SDK" -target "$(uname -m)-apple-macosx13.0" -module-cache-path "$BUILD/module-cache")
xcrun swiftc "${FLAGS[@]}" -emit-module -emit-library -enable-testing -module-name HueCore Sources/HueCore/*.swift -emit-module-path "$BUILD/HueCore.swiftmodule" -o "$BUILD/libHueCore.dylib" -Xlinker -install_name -Xlinker @rpath/libHueCore.dylib
xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$BUILD" -L "$BUILD" -lHueCore Tests/ClientChecks.swift -o "$BUILD/ClientChecks" -Xlinker -rpath -Xlinker @executable_path
"$BUILD/ClientChecks"
