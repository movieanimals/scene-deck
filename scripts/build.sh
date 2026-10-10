#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
BUILD="$PWD/.build/local"
APP="$PWD/dist/Scene Deck.app"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"
mkdir -p "$BUILD/module-cache" "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
FLAGS=(-sdk "$SDK" -target "$ARCH-apple-macosx13.0" -module-cache-path "$BUILD/module-cache")
xcrun swiftc "${FLAGS[@]}" -emit-module -emit-library -enable-testing -module-name HueCore Sources/HueCore/*.swift -emit-module-path "$BUILD/HueCore.swiftmodule" -o "$BUILD/libHueCore.dylib" -Xlinker -install_name -Xlinker @rpath/libHueCore.dylib
cp "$BUILD/libHueCore.dylib" "$APP/Contents/Frameworks/"
xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$BUILD" -L "$BUILD" -lHueCore Sources/HueScenes/*.swift -o "$APP/Contents/MacOS/SceneDeck" -Xlinker -rpath -Xlinker @executable_path/../Frameworks
xcrun swiftc "${FLAGS[@]}" scripts/Icon.swift -o "$BUILD/IconBuilder"
"$BUILD/IconBuilder" "$BUILD/AppIcon.iconset"
python3 scripts/package-icon.py "$BUILD/AppIcon.iconset" "$APP/Contents/Resources/AppIcon.icns"
cp scripts/Info.plist "$APP/Contents/Info.plist"
# Local ad-hoc signature only. No identity, developer account, or notarization.
codesign --force --sign - "$APP/Contents/Frameworks/libHueCore.dylib"
if xattr -p com.apple.FinderInfo "$APP" >/dev/null 2>&1; then xattr -d com.apple.FinderInfo "$APP"; fi
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
ditto -c -k --keepParent --norsrc --noextattr "$APP" "$PWD/dist/Scene-Deck-macOS-$ARCH.zip"
printf 'Built %s\n' "$APP"
