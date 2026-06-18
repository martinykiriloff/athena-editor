# Athena — build, bundle, and package targets
# Usage:
#   make          → release .app bundle (default)
#   make run      → debug build + launch immediately
#   make dmg      → release .app wrapped in a distributable DMG
#   make dmg-pretty → DMG with drag-to-Applications window (needs create-dmg)
#   make test     → run Swift test suite
#   make clean    → remove all build artefacts

# ── Config ─────────────────────────────────────────────────────────────────────

APP_NAME    := Athena
VERSION     := $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" \
                   XcodeConfig/Info.plist 2>/dev/null || echo "1.0")
BUILD_DIR   := .build
RELEASE_BIN := $(BUILD_DIR)/release/$(APP_NAME)
DEBUG_BIN   := $(BUILD_DIR)/debug/$(APP_NAME)
APP_BUNDLE  := $(APP_NAME).app
DMG_NAME    := $(APP_NAME)-$(VERSION).dmg

# Ad-hoc sign by default (no Apple ID required).
# For a notarised release build override on the command line:
#   make dmg SIGN_ID="Developer ID Application: Your Name (TEAMID)"
SIGN_ID     := -

# SPM uses git internally; unset the env vars the shell hook injects.
SWIFT_ENV   := unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0;

# ── Phony targets ──────────────────────────────────────────────────────────────

.PHONY: all run build-debug build-release bundle dmg dmg-pretty test clean open help

all: bundle

# ── Run (debug build, launch app directly) ────────────────────────────────────

run: build-debug
	@echo "▶  Launching $(APP_NAME) (debug)…"
	$(DEBUG_BIN)

# ── Builds ────────────────────────────────────────────────────────────────────

build-debug:
	@echo "🔨 Building debug…"
	$(SWIFT_ENV) swift build

build-release:
	@echo "🔨 Building release…"
	$(SWIFT_ENV) swift build -c release

# ── .app bundle ───────────────────────────────────────────────────────────────

bundle: build-release
	@echo "📦 Assembling $(APP_BUNDLE)…"
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	@mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	@cp "$(RELEASE_BIN)"                      "$(APP_BUNDLE)/Contents/MacOS/"
	@cp XcodeConfig/Info.plist                "$(APP_BUNDLE)/Contents/"
	@cp XcodeConfig/AppIcon.icns              "$(APP_BUNDLE)/Contents/Resources/"
	@cp XcodeConfig/Athena.entitlements       "$(APP_BUNDLE)/Contents/Resources/"
	@printf 'APPL????'                      > "$(APP_BUNDLE)/Contents/PkgInfo"
	@echo "✍️  Code-signing ($(SIGN_ID))…"
	@codesign --force --deep --sign "$(SIGN_ID)" \
	    --entitlements XcodeConfig/Athena.entitlements \
	    "$(APP_BUNDLE)"
	@echo "✅ $(APP_BUNDLE) ready"

# ── DMG (plain hdiutil) ───────────────────────────────────────────────────────

dmg: bundle
	@echo "💿 Creating $(DMG_NAME)…"
	@rm -f "$(DMG_NAME)"
	@hdiutil create \
	    -volname "$(APP_NAME)" \
	    -srcfolder "$(APP_BUNDLE)" \
	    -ov -format UDZO \
	    "$(DMG_NAME)"
	@echo "✅ $(DMG_NAME) ready"

# ── DMG (polished drag-to-Applications window) ────────────────────────────────

dmg-pretty: bundle
	@command -v create-dmg >/dev/null 2>&1 || \
	    { echo "❌ create-dmg not found — run: brew install create-dmg"; exit 1; }
	@echo "💿 Creating polished $(DMG_NAME)…"
	@rm -f "$(DMG_NAME)"
	@create-dmg \
	    --volname "$(APP_NAME)" \
	    --window-size 600 380 \
	    --background-color "#1E1E1E" \
	    --icon-size 128 \
	    --icon "$(APP_BUNDLE)" 150 175 \
	    --app-drop-link 450 175 \
	    "$(DMG_NAME)" \
	    "$(APP_BUNDLE)"
	@echo "✅ $(DMG_NAME) ready"

# ── Tests ─────────────────────────────────────────────────────────────────────

test:
	@echo "🧪 Running tests…"
	$(SWIFT_ENV) swift test

# ── Open in Xcode (for GUI archive / notarisation) ────────────────────────────

open:
	open Package.swift

# ── Clean ─────────────────────────────────────────────────────────────────────

clean:
	@echo "🧹 Cleaning…"
	@rm -rf "$(BUILD_DIR)" "$(APP_BUNDLE)" "$(APP_NAME)"-*.dmg
	@echo "✅ Clean"

# ── Help ──────────────────────────────────────────────────────────────────────

help:
	@echo ""
	@echo "  make              build release .app bundle"
	@echo "  make run          debug build + launch app"
	@echo "  make dmg          release DMG  →  $(APP_NAME)-<version>.dmg"
	@echo "  make dmg-pretty   polished DMG (needs: brew install create-dmg)"
	@echo "  make test         run Swift test suite"
	@echo "  make open         open Package.swift in Xcode"
	@echo "  make clean        remove .build/, .app, .dmg files"
	@echo ""
	@echo "  Signed build:  make dmg SIGN_ID='Developer ID Application: Name (TEAMID)'"
	@echo ""
