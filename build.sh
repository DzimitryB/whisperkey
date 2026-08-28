#!/bin/bash
# Builds WhisperKey.app and installs it into /Applications.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/WhisperKey.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/WhisperKey "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
codesign --force --sign - "$APP"

pkill -x WhisperKey 2>/dev/null || true
sleep 0.5
rm -rf /Applications/WhisperKey.app
cp -R "$APP" /Applications/

echo "Установлено: /Applications/WhisperKey.app"
echo "Запуск: open /Applications/WhisperKey.app"
