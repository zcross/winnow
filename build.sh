#!/bin/sh
# Builds build/Winnow.app with just the Command Line Tools. `./build.sh install` copies it to ~/Applications.
set -eu
cd "$(dirname "$0")"
swift build -c release --product Winnow
APP=build/Winnow.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Winnow" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Ad-hoc sign with an identifier-only requirement so the Photos permission survives rebuilds.
codesign --force --sign - -r='designated => identifier "dev.zcross.winnow"' "$APP"
if [ "${1:-}" = install ]; then
    mkdir -p ~/Applications
    rm -rf ~/Applications/Winnow.app
    cp -R "$APP" ~/Applications/
    echo "Installed ~/Applications/Winnow.app"
fi
