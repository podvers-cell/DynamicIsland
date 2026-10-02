#!/bin/sh
set -e
cd "$(dirname "$0")"
APP=DynamicIsland.app
MRA=vendor/mediaremote-adapter
RES=$APP/Contents/Resources
VERSION=1.2
MIN_OS=14.2  # Core Audio process taps need 14.2
mkdir -p $APP/Contents/MacOS $RES/MediaRemoteAdapter.framework
cat > $APP/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.dynamicisland</string>
  <key>CFBundleName</key><string>DynamicIsland</string>
  <key>CFBundleExecutable</key><string>DynamicIsland</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Show and control Spotify or Music when another app holds Now Playing.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Animate the visualizer to the music that is playing.</string>
</dict></plist>
EOF

# mediaremote-adapter framework (loaded by /usr/bin/perl, not linked)
clang -dynamiclib -O2 -arch arm64 -arch x86_64 -mmacosx-version-min=$MIN_OS -fobjc-arc -fvisibility=default -I$MRA/include -I$MRA/src \
  $MRA/src/adapter/*.m $MRA/src/private/MediaRemote.m $MRA/src/utility/*.m \
  -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
  -o $RES/MediaRemoteAdapter.framework/MediaRemoteAdapter
cp $MRA/bin/mediaremote-adapter.pl $RES/
[ -f AppIcon.icns ] || swift make-icon.swift
cp AppIcon.icns $RES/
codesign --force -s - $RES/MediaRemoteAdapter.framework/MediaRemoteAdapter

# Universal binary so it runs on any Mac with macOS 14.2+
for ARCH in arm64 x86_64; do
  swiftc -O -target $ARCH-apple-macos$MIN_OS main.swift -o /tmp/DynamicIsland-$ARCH
done
lipo -create /tmp/DynamicIsland-arm64 /tmp/DynamicIsland-x86_64 -output $APP/Contents/MacOS/DynamicIsland
codesign --force -s - $APP
echo "Built $APP"

# ./build.sh dmg  ->  DynamicIsland.dmg (drag app into Applications)
if [ "$1" = dmg ]; then
  STAGE=$(mktemp -d)
  cp -R $APP "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  rm -f DynamicIsland.dmg
  hdiutil create -volname DynamicIsland -srcfolder "$STAGE" -format UDZO -ov DynamicIsland.dmg >/dev/null
  rm -rf "$STAGE"
  echo "Built DynamicIsland.dmg"
fi
