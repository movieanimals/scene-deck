#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
BUILD="$PWD/.build/local"
FIX="$BUILD/trust-fixtures"
mkdir -p "$FIX" "$BUILD/module-cache"
trap 'rm -f "$FIX"/*.key "$FIX"/*.csr' EXIT
# Ephemeral synthetic TLS fixtures only; no Bridge credentials or network access.
for name in root wrong-root; do
  openssl ecparam -name prime256v1 -genkey -noout -out "$FIX/$name.key" 2>/dev/null
  openssl req -sha256 -new -x509 -key "$FIX/$name.key" -days 365 -subj "/CN=Scene Deck test $name" -out "$FIX/$name.pem" 2>/dev/null
done
openssl ecparam -name prime256v1 -genkey -noout -out "$FIX/leaf.key" 2>/dev/null
openssl req -new -key "$FIX/leaf.key" -subj /CN=aabbccddeeff7788 -out "$FIX/leaf.csr" 2>/dev/null
for name in leaf matching-san client-only wrong-san wrong-serial; do
  usage=serverAuth
  serial=0xaabbccddeeff7788
  [[ "$name" == client-only ]] && usage=clientAuth
  [[ "$name" == wrong-serial ]] && serial=0xaabbccddeeff7799
  cat > "$FIX/$name.ext" <<EXT
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=$usage
EXT
  if [[ "$name" == wrong-san ]]; then
    print 'subjectAltName=DNS:other-id.invalid' >> "$FIX/$name.ext"
  fi
  if [[ "$name" == matching-san ]]; then
    print 'subjectAltName=DNS:aabbccddeeff7788' >> "$FIX/$name.ext"
  fi
  openssl x509 -sha256 -req -in "$FIX/leaf.csr" -CA "$FIX/root.pem" -CAkey "$FIX/root.key" -set_serial "$serial" -days 3 -extfile "$FIX/$name.ext" -out "$FIX/$name.pem" 2>/dev/null
done
SDK="$(xcrun --sdk macosx --show-sdk-path)"
FLAGS=(-sdk "$SDK" -target "$(uname -m)-apple-macosx13.0" -module-cache-path "$BUILD/module-cache")
xcrun swiftc "${FLAGS[@]}" -emit-module -emit-library -enable-testing -module-name HueCore Sources/HueCore/*.swift -emit-module-path "$BUILD/HueCore.swiftmodule" -o "$BUILD/libHueCore.dylib" -Xlinker -install_name -Xlinker @rpath/libHueCore.dylib
xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$BUILD" -L "$BUILD" -lHueCore Tests/TrustChecks.swift -o "$BUILD/TrustChecks" -Xlinker -rpath -Xlinker @executable_path
"$BUILD/TrustChecks" "$FIX" "$@"
