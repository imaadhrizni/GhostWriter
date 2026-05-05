#!/bin/bash

# GhostWriter Production Build & Ship 🚀
# Using a FRESH Identity to bypass TCC cache

set -e

APP_NAME="GhostWriter"
# FRESH IDENTITY HERE
BUNDLE_ID="com.ghostwriter.dictation"
INSTALL_PATH="$HOME/Applications/${APP_NAME}.app"

echo "🧹 Cleaning up old builds..."
rm -rf ".build"
rm -rf "${APP_NAME}.app"
pkill "${APP_NAME}" || true

echo "🔨 Building ${APP_NAME} in release mode..."
swift build -c release

echo "📦 Creating App Bundle..."
mkdir -p "${APP_NAME}.app/Contents/MacOS"
mkdir -p "${APP_NAME}.app/Contents/Resources"

echo "📄 Injecting Info.plist with new ID..."
cat <<EOF > "${APP_NAME}.app/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>GhostWriter</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>GhostWriter</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.1</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>GhostWriter needs microphone access to transcribe your speech into text.</string>
    <key>NSAccessibilityUsageDescription</key>
    <string>GhostWriter needs accessibility access to detect the Right Option key and inject text at your cursor.</string>
</dict>
</plist>
EOF

echo "💾 Copying binary..."
cp ".build/release/${APP_NAME}" "${APP_NAME}.app/Contents/MacOS/${APP_NAME}"

echo "🔐 Signing app with FRESH Identity..."
codesign --force --identifier "${BUNDLE_ID}" --entitlements entitlements.plist --deep --sign - "${APP_NAME}.app"

echo "🚀 Installing to ${INSTALL_PATH} (Local Testing)..."
rm -rf "${INSTALL_PATH}"
mv "${APP_NAME}.app" "${INSTALL_PATH}"

echo "📦 Packaging for Distribution..."
mkdir -p .release
rm -rf .release/GhostWriter.app
rm -f .release/GhostWriter.zip

# Copy the fresh app into release folder for zipping
cp -R "${INSTALL_PATH}" .release/GhostWriter.app

# Create the installer script inside release folder
cat <<EOF > ".release/install.command"
#!/bin/bash
DIR="\$( cd "\$( dirname "\${BASH_SOURCE[0]}" )" && pwd )"
echo "Installing GhostWriter..."
echo "Moving GhostWriter.app to Applications folder..."
sudo cp -R "\$DIR/GhostWriter.app" /Applications/
echo "Fixing file ownership..."
sudo chown -R \$USER /Applications/GhostWriter.app
echo "Removing macOS Quarantine flag..."
sudo xattr -cr /Applications/GhostWriter.app
echo "Opening GhostWriter..."
open /Applications/GhostWriter.app
echo "Installation Complete! You can close this terminal."
sleep 2
EOF
chmod +x .release/install.command

# Zip it up cleanly from within the directory
cd .release
zip -qr "GhostWriter.zip" "install.command" "GhostWriter.app"
rm -rf "GhostWriter.app" "install.command"
cd ..

echo "✨ Installed LOCALLY at: ${INSTALL_PATH}"
echo "🎁 Redistributable package ready at: .release/GhostWriter.zip"
echo "👉 Run: open ${INSTALL_PATH}"
