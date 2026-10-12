#!/bin/zsh
# Builds LockWave.app into build/. Needs Xcode or Command Line Tools with Swift 6.
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${1:-0.1.0}"
TARGET="arm64-apple-macosx14.0"
SDK="$(xcrun --show-sdk-path)"
APP="build/LockWave.app"
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"

echo "▸ Now Playing adapter"
swiftc -O -target "$TARGET" -sdk "$SDK" -emit-library -module-name LockWaveNowPlaying \
    Sources/NowPlayingAdapter/*.swift Sources/Shared/*.swift \
    -o "$APP/Contents/Frameworks/libLockWaveNowPlaying.dylib"

echo "▸ App"
swiftc -O -target "$TARGET" -sdk "$SDK" -module-name LockWave \
    Sources/LockWave/*.swift Sources/Shared/*.swift \
    -o "$APP/Contents/MacOS/LockWave"

cp Resources/now-playing.pl "$APP/Contents/Resources/"
sed "s/VERSION/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"

echo "▸ Signing (ad hoc)"
codesign --force --sign - "$APP/Contents/Frameworks/libLockWaveNowPlaying.dylib"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "✓ $APP"
