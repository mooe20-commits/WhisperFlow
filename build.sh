#!/bin/bash
# WhisperFlow — Build & Setup Script
# Tested on macOS 13+ / Apple Silicon

set -e

SCHEME="WhisperFlow"
BUILD_DIR=".build"
APP_NAME="WhisperFlow.app"

echo "╔═══════════════════════════════════════╗"
echo "║         WhisperFlow Build Tool        ║"
echo "╚═══════════════════════════════════════╝"
echo ""

# ── Prerequisites ────────────────────────────────────────────────────────────

check_xcode() {
    if ! command -v swiftc &> /dev/null; then
        echo "ERROR: Xcode Command Line Tools not found."
        echo "Run: xcode-select --install"
        exit 1
    fi
    echo "✓ Swift: $(swiftc --version | head -1)"
}

# ── Build (SPM) ───────────────────────────────────────────────────────────────

build_spm() {
    echo ""
    echo "Building with Swift Package Manager..."
    swift build -c release 2>&1

    if [ $? -eq 0 ]; then
        echo "✓ Build succeeded"
    else
        echo "✗ Build failed"
        exit 1
    fi
}

# ── Create .app bundle ────────────────────────────────────────────────────────

create_app_bundle() {
    echo ""
    echo "Creating .app bundle..."

    APP_PATH="$BUILD_DIR/$APP_NAME"
    CONTENTS="$APP_PATH/Contents"
    MACOS="$CONTENTS/MacOS"
    RESOURCES="$CONTENTS/Resources"

    rm -rf "$APP_PATH"
    mkdir -p "$MACOS" "$RESOURCES"

    # Copy binary — swift build -c release places output at
    # .build/arm64-apple-macosx/release/ (not .build/release/)
    cp "$BUILD_DIR/arm64-apple-macosx/release/WhisperFlow" "$MACOS/WhisperFlow"

    # Copy Info.plist
    cp "Sources/WhisperFlow/Info.plist" "$CONTENTS/Info.plist"

    # Sign with self-signed cert — stable identity, TCC grant persists across rebuilds
    # Cert "WhisperFlow Dev" was created once via OpenSSL + Keychain import.
    # If codesign fails with "no identity found", re-create the cert:
    #   openssl req -new -x509 -keyout /tmp/wf-key.pem -out /tmp/wf-cert.pem -days 3650 -nodes -subj "/CN=WhisperFlow Dev/C=US/ST=Local/L=Local/O=WhisperFlow"
    #   openssl pkcs12 -export -inkey /tmp/wf-key.pem -in /tmp/wf-cert.pem -out /tmp/wf-dev.p12 -passout pass:temp
    #   security import /tmp/wf-dev.p12 -k ~/Library/Keychains/login.keychain-db -P temp -T /usr/bin/codesign -T /usr/bin/security
    codesign \
        --force \
        --deep \
        --sign "WhisperFlow Dev" \
        --entitlements "WhisperFlow.entitlements" \
        --options runtime \
        "$APP_PATH"

    # Strip quarantine attribute so Gatekeeper doesn't block the self-signed app
    xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true

    echo "✓ App bundle: $APP_PATH"
}

# ── Install to /Applications ──────────────────────────────────────────────────

install_app() {
    local dest="/Applications/$APP_NAME"
    echo ""
    echo "Installing to $dest..."
    # Only replace the binary — nuke-and-replace of the whole .app orphans
    # the TCC permission cache (CDHash mismatch causes AX=0 after every rebuild).
    # Binary path from swift build -c release: .build/arm64-apple-macosx/release/
    cp "$BUILD_DIR/arm64-apple-macosx/release/WhisperFlow" "$dest/Contents/MacOS/WhisperFlow"
    # CRITICAL: re-sign after cp. The cp overwrites the cert-signed binary
    # in /Applications with the linker-signed build output. Without re-signing,
    # TCC CDHash changes and the permission popup returns.
    codesign \
        --force \
        --deep \
        --sign "WhisperFlow Dev" \
        --entitlements "WhisperFlow.entitlements" \
        --options runtime \
        "$dest"
    echo "✓ Binary updated and re-signed at $dest/Contents/MacOS/WhisperFlow"
}

# ── Permissions guide ─────────────────────────────────────────────────────────

print_permissions_guide() {
    echo ""
    echo "══════════════════════════════════════════════════════"
    echo " PERMISSIONS SETUP (required before first launch)"
    echo "══════════════════════════════════════════════════════"
    echo ""
    echo "1. MICROPHONE"
    echo "   System Settings → Privacy & Security → Microphone"
    echo "   → Enable WhisperFlow"
    echo ""
    echo "2. SPEECH RECOGNITION"
    echo "   System Settings → Privacy & Security → Speech Recognition"
    echo "   → Enable WhisperFlow"
    echo ""
    echo "3. ACCESSIBILITY (most important — required for hotkey + injection)"
    echo "   System Settings → Privacy & Security → Accessibility"
    echo "   → Click '+' and add WhisperFlow"
    echo "   NOTE: Without this, the global hotkey won't work."
    echo ""
    echo "After granting permissions, launch the app:"
    echo "   open /Applications/$APP_NAME"
    echo ""
    echo "Usage:"
    echo "   Hold Ctrl+Shift → speak → release → text appears at cursor"
    echo "══════════════════════════════════════════════════════"
}

# ── Xcode project generation (optional) ──────────────────────────────────────

generate_xcodeproj() {
    echo ""
    echo "Generating Xcode project..."
    if command -v xcodegen &> /dev/null; then
        xcodegen
        echo "✓ WhisperFlow.xcodeproj generated"
    else
        swift package generate-xcodeproj 2>/dev/null || true
        echo "✓ Xcode project generated (open WhisperFlow.xcodeproj)"
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────

check_xcode

case "${1:-build}" in
    build)
        build_spm
        create_app_bundle
        echo ""
        echo "Done! Run ./build.sh install to install to /Applications"
        ;;
    install)
        build_spm
        create_app_bundle
        install_app
        print_permissions_guide
        ;;
    xcode)
        generate_xcodeproj
        ;;
    permissions)
        print_permissions_guide
        ;;
    *)
        echo "Usage: $0 [build|install|xcode|permissions]"
        echo "  build       — build release binary + .app bundle (default)"
        echo "  install     — build + copy to /Applications"
        echo "  xcode       — generate Xcode project"
        echo "  permissions — print permissions setup guide"
        ;;
esac
