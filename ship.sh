#!/bin/bash

# GhostWriter Production Build & Ship 🚀
# Using a FRESH Identity to bypass TCC cache

set -e

APP_NAME="GhostWriter"
# FRESH IDENTITY HERE
BUNDLE_ID="com.ghostwriter.dictation"
SIGN_IDENTITY="GhostWriter Dev"  # Self-signed cert from Keychain Access → Certificate Assistant
INSTALL_PATH="/Applications/${APP_NAME}.app"

# ---------------------------------------------------------------------------
# Auto-create a stable self-signed code-signing cert (one time only).
# Using the same cert across builds keeps macOS TCC permissions stable —
# no more "Accessibility permission" or Keychain prompts after every rebuild.
# ---------------------------------------------------------------------------
ensure_signing_cert() {
    if security find-certificate -c "${SIGN_IDENTITY}" \
           ~/Library/Keychains/login.keychain-db &>/dev/null; then
        echo "✅ Signing cert '${SIGN_IDENTITY}' already in keychain"
        return 0
    fi

    echo "🔐 Creating self-signed code-signing cert '${SIGN_IDENTITY}'..."

    local TMPDIR_CERT
    TMPDIR_CERT=$(mktemp -d)
    local KEY="${TMPDIR_CERT}/key.pem"
    local CERT="${TMPDIR_CERT}/cert.pem"
    local CFG="${TMPDIR_CERT}/openssl.cnf"

    cat > "${CFG}" <<OPENSSL_EOF
[ req ]
default_bits        = 2048
prompt              = no
default_md          = sha256
distinguished_name  = dn
x509_extensions     = v3_codesign

[ dn ]
CN = ${SIGN_IDENTITY}

[ v3_codesign ]
subjectKeyIdentifier   = hash
basicConstraints       = critical,CA:false
keyUsage               = critical,digitalSignature
extendedKeyUsage       = codeSigning
OPENSSL_EOF

    openssl genrsa -out "${KEY}" 2048 2>/dev/null
    openssl req -new -x509 -key "${KEY}" -out "${CERT}" \
        -days 3650 -config "${CFG}" 2>/dev/null
    # Import key and cert as separate PEM files — avoids PKCS12 format issues
    security import "${KEY}" \
        -k ~/Library/Keychains/login.keychain-db \
        -T /usr/bin/codesign -A
    security import "${CERT}" \
        -k ~/Library/Keychains/login.keychain-db \
        -T /usr/bin/codesign -A

    # Trust the cert for code signing (best-effort — may prompt for password)
    security add-trusted-cert -p codeSign "${CERT}" 2>/dev/null || true

    rm -rf "${TMPDIR_CERT}"
    echo "✅ Cert created and trusted"
}

ensure_signing_cert

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
    <string>0.23.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>GhostWriter needs microphone access to transcribe your speech into text.</string>
    <key>NSAccessibilityUsageDescription</key>
    <string>GhostWriter needs accessibility access to detect the Right Option key and inject text at your cursor.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>GhostWriter needs system audio recording access to transcribe the other participants in your meetings.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>GhostWriter uses on-device speech recognition as an offline fallback when the transcription service is unreachable.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>GhostWriter reads the active browser tab's address to pick the right writing style (e.g. email style on Gmail). You can disable this in Settings.</string>
    <key>NSRemindersFullAccessUsageDescription</key>
    <string>GhostWriter adds your meeting action items to the Reminders app when you choose to export them.</string>
    <key>NSRemindersUsageDescription</key>
    <string>GhostWriter adds your meeting action items to the Reminders app when you choose to export them.</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
EOF

echo "💾 Copying binary and icon..."
cp ".build/release/${APP_NAME}" "${APP_NAME}.app/Contents/MacOS/${APP_NAME}"
if [ -f "GhostWriter.icns" ]; then
    cp "GhostWriter.icns" "${APP_NAME}.app/Contents/Resources/AppIcon.icns"
fi

echo "🔐 Signing app with FRESH Identity..."
codesign --force --identifier "${BUNDLE_ID}" --entitlements entitlements.plist --deep --sign "${SIGN_IDENTITY}" "${APP_NAME}.app" 2>/dev/null || {
    echo "⚠️  Cert '${SIGN_IDENTITY}' not found — falling back to ad-hoc (permissions will reset on each build)"
    codesign --force --identifier "${BUNDLE_ID}" --entitlements entitlements.plist --deep --sign - "${APP_NAME}.app"
}

echo "🚀 Installing to ${INSTALL_PATH}..."
if [ -d "${INSTALL_PATH}" ]; then
    # Update in-place — preserves the app bundle directory so macOS doesn't invalidate
    # Accessibility/Keychain TCC entries (replacing the whole bundle triggers re-evaluation)
    cp "${APP_NAME}.app/Contents/MacOS/${APP_NAME}" "${INSTALL_PATH}/Contents/MacOS/${APP_NAME}"
    cp "${APP_NAME}.app/Contents/Info.plist"         "${INSTALL_PATH}/Contents/Info.plist"
    [ -f "${APP_NAME}.app/Contents/Resources/AppIcon.icns" ] && \
        cp "${APP_NAME}.app/Contents/Resources/AppIcon.icns" "${INSTALL_PATH}/Contents/Resources/AppIcon.icns"
    codesign --force --identifier "${BUNDLE_ID}" --entitlements entitlements.plist --deep \
        --sign "${SIGN_IDENTITY}" "${INSTALL_PATH}" 2>/dev/null || \
    codesign --force --identifier "${BUNDLE_ID}" --entitlements entitlements.plist --deep \
        --sign - "${INSTALL_PATH}"
    rm -rf "${APP_NAME}.app"
else
    mv "${APP_NAME}.app" "${INSTALL_PATH}"
fi

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
echo ""
echo "👉 Launching: open ${INSTALL_PATH}"
open "${INSTALL_PATH}"
