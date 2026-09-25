#!/usr/bin/env bash
# Builds ClaudeUsageWidget as a real, double-clickable .app bundle instead of
# a bare command-line binary launched from Terminal.
#
#   ./scripts/build-app.sh            # build build/ClaudeUsageWidget.app
#   ./scripts/build-app.sh --install  # also copy to ~/Applications and open it
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="ClaudeUsageWidget"
BUNDLE_ID="io.github.bqt1089.UsagePet"
DISPLAY_NAME="UsagePet"
SHORT_VERSION="0.1.0"
BUILD_NUMBER="1"

BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

INSTALL=false
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=true ;;
    *)
      echo "warning: ignoring unknown argument '$arg'" >&2
      ;;
  esac
done

log() { echo "==> $*"; }

log "Building $APP_NAME (release)…"
BUILD_LOG="$(mktemp)"
BIN_PATH=""
if swift build -c release --arch arm64 --arch x86_64 >"$BUILD_LOG" 2>&1; then
  BIN_PATH=".build/apple/Products/Release/$APP_NAME"
else
  log "Universal (arm64 + x86_64) build failed; falling back to a native-arch build."
  cat "$BUILD_LOG" >&2 || true
  swift build -c release
  BIN_PATH=".build/release/$APP_NAME"
fi
rm -f "$BUILD_LOG"

if [ ! -f "$BIN_PATH" ]; then
  echo "error: built binary not found at $BIN_PATH" >&2
  exit 1
fi

log "Assembling app bundle at $APP_DIR"
if [ -d "$APP_DIR" ]; then
  rm -rf "$APP_DIR"
fi
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

# --- SwiftPM resource bundle (fonts, etc.) ---------------------------------
# `swift build` emits ClaudeUsageWidget_ClaudeUsageWidget.bundle next to the
# built binary (Sources/ClaudeUsageWidget's `resources: [.process("Resources")]`
# in Package.swift); Bundle.module looks for it next to the executable, so it
# has to land in Contents/Resources alongside the app binary.
BIN_DIR="$(dirname "$BIN_PATH")"
RESOURCE_BUNDLE=""
for candidate in   "$BIN_DIR/ClaudeUsageWidget_ClaudeUsageWidget.bundle"   ".build/apple/Products/Release/ClaudeUsageWidget_ClaudeUsageWidget.bundle"   ".build/release/ClaudeUsageWidget_ClaudeUsageWidget.bundle"; do
  if [ -d "$candidate" ]; then
    RESOURCE_BUNDLE="$candidate"
    break
  fi
done
if [ -z "$RESOURCE_BUNDLE" ]; then
  RESOURCE_BUNDLE="$(find .build -maxdepth 4 -iname 'ClaudeUsageWidget_ClaudeUsageWidget.bundle' -print -quit 2>/dev/null || true)"
fi
if [ -n "$RESOURCE_BUNDLE" ] && [ -d "$RESOURCE_BUNDLE" ]; then
  log "Copying resource bundle from $RESOURCE_BUNDLE"
  cp -R "$RESOURCE_BUNDLE" "$RESOURCES_DIR/"
else
  log "warning: ClaudeUsageWidget_ClaudeUsageWidget.bundle not found — pixel-pet theme will fall back to system fonts."
fi

# --- App icon (best effort; safe to skip entirely) -------------------------
ICON_ADDED=false
if command -v iconutil >/dev/null 2>&1 && command -v sips >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  log "Generating app icon (best effort)…"
  ICONSET_DIR="$BUILD_DIR/AppIcon.iconset"
  mkdir -p "$ICONSET_DIR"
  BASE_PNG="$BUILD_DIR/.appicon_base.png"

  if python3 - "$BASE_PNG" <<'PY'
import sys
try:
    from PIL import Image, ImageDraw
except Exception:
    sys.exit(1)

size = 1024
img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
draw = ImageDraw.Draw(img)
draw.rounded_rectangle([40, 40, size - 40, size - 40], radius=210, fill=(28, 28, 32, 255))
draw.arc([170, 170, size - 170, size - 170], start=150, end=390, fill=(126, 217, 87, 255), width=70)
r = 46
draw.ellipse([size / 2 - r, size / 2 - r, size / 2 + r, size / 2 + r], fill=(255, 255, 255, 255))
img.save(sys.argv[1])
PY
  then
    for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
                "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" \
                "512 icon_256x256@2x" "512 icon_512x512" "1024 icon_512x512@2x"; do
      set -- $spec
      px="$1"; name="$2"
      sips -z "$px" "$px" "$BASE_PNG" --out "$ICONSET_DIR/$name.png" >/dev/null 2>&1 || true
    done
    if iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns" >/dev/null 2>&1; then
      ICON_ADDED=true
    fi
  fi
  rm -rf "$ICONSET_DIR" "$BASE_PNG" 2>/dev/null || true
fi
if [ "$ICON_ADDED" = false ]; then
  log "Skipping app icon (Pillow/iconutil/sips not available) — app will use the default icon."
fi

# --- Info.plist --------------------------------------------------------
log "Writing Info.plist"
{
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$DISPLAY_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$DISPLAY_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$SHORT_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Opens Terminal to run "claude /login" so you can sign in to Claude Code.</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
PLIST
  if [ "$ICON_ADDED" = true ]; then
    cat <<'PLIST'
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
PLIST
  fi
  cat <<'PLIST'
</dict>
</plist>
PLIST
} > "$CONTENTS_DIR/Info.plist"

# --- Code signing (ad-hoc, so Gatekeeper/Keychain treat it as one stable
# app identity across rebuilds; not notarized) --------------------------
log "Ad-hoc code signing…"
codesign --force --deep --sign - "$APP_DIR"

if [ "$INSTALL" = true ]; then
  DEST_DIR="$HOME/Applications"
  DEST_APP="$DEST_DIR/$APP_NAME.app"
  mkdir -p "$DEST_DIR"
  log "Installing to $DEST_APP"
  # Quit any running copy (installed app or `swift run`), otherwise `open`
  # just re-focuses the old process and the new build never starts.
  pkill -x ClaudeUsageWidget 2>/dev/null && echo "==> Quit running ClaudeUsageWidget" && sleep 1 || true
  ditto "$APP_DIR" "$DEST_APP"
  open "$DEST_APP"
  log "Done: $DEST_APP"
else
  log "Done: $APP_DIR"
fi
