#!/bin/sh
# Builds build/Claude Notch.app
set -e
cd "$(dirname "$0")"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "Necesitás las Command Line Tools de Xcode. Instalalas con:"
  echo "  xcode-select --install"
  echo "y volvé a correr este script."
  exit 1
fi
APP="build/Claude Notch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 Sources/main.swift \
  -framework Cocoa -framework WebKit \
  -target "$(uname -m)-apple-macos13.0" \
  -o "$APP/Contents/MacOS/ClaudeNotch"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/notch.html "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
