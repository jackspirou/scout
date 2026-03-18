# ------------------------------------------------------------------
# Scout macOS App – Makefile
# ------------------------------------------------------------------

# Variables
APP_NAME       := Scout
BUILD_DIR      := build
CODESIGN_IDENTITY ?= -
TEAM_ID           ?=

# Paths – source artifacts
INFO_PLIST   := Sources/ScoutLib/Resources/Info.plist
ENTITLEMENTS := Sources/ScoutLib/Resources/Scout.entitlements

# Paths – build artifacts
APP_BUNDLE     := $(BUILD_DIR)/$(APP_NAME).app
DMG_FILE       := $(BUILD_DIR)/$(APP_NAME).dmg

# ------------------------------------------------------------------
# Phony targets
# ------------------------------------------------------------------
.PHONY: build release xcodegen app dmg dmg-only run clean install uninstall lint test version changelog screenshot

# ------------------------------------------------------------------
# build (default) – debug build
# ------------------------------------------------------------------
build:
	swift build

# ------------------------------------------------------------------
# release – optimised release build
# ------------------------------------------------------------------
release:
	swift build -c release

# ------------------------------------------------------------------
# xcodegen – generate the Xcode project from project.yml
# ------------------------------------------------------------------
xcodegen: ## Generate the Xcode project from project.yml
	xcodegen generate

# ------------------------------------------------------------------
# app – build the .app bundle with xcodebuild
# ------------------------------------------------------------------
app: xcodegen ## Build the .app bundle with xcodebuild
	@echo "==> Building $(APP_NAME).app with xcodebuild"
	@rm -rf "$(APP_BUNDLE)"
	@xcodebuild -project Scout.xcodeproj \
		-scheme Scout \
		-configuration Release \
		-destination 'generic/platform=macOS' \
		-derivedDataPath "$(BUILD_DIR)/DerivedData" \
		ARCHS="arm64 x86_64" \
		ONLY_ACTIVE_ARCH=NO \
		CODE_SIGN_IDENTITY="$(CODESIGN_IDENTITY)" \
		DEVELOPMENT_TEAM="$(TEAM_ID)" \
		CODE_SIGN_STYLE=Manual \
		ENABLE_HARDENED_RUNTIME=YES \
		OTHER_CODE_SIGN_FLAGS="--options=runtime --timestamp" \
		CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
		-quiet \
		build
	@cp -R "$(BUILD_DIR)/DerivedData/Build/Products/Release/$(APP_NAME).app" "$(APP_BUNDLE)"
	# Re-sign the entire bundle to ensure consistent team ID across all binaries
	@codesign --force --deep --sign "$(CODESIGN_IDENTITY)" --options=runtime --timestamp --entitlements "$(ENTITLEMENTS)" "$(APP_BUNDLE)"
	@echo "==> $(APP_BUNDLE) is ready"

# ------------------------------------------------------------------
# dmg – create a distributable disk image from the .app bundle
# ------------------------------------------------------------------
dmg: app
	@$(MAKE) dmg-only CODESIGN_IDENTITY="$(CODESIGN_IDENTITY)"

# ------------------------------------------------------------------
# dmg-only – create a DMG from an existing .app (no rebuild)
# ------------------------------------------------------------------
dmg-only:
	@echo "==> Creating $(DMG_FILE)"

	# Clean up any previous DMG artefacts
	@rm -rf "$(BUILD_DIR)/dmg_tmp" "$(DMG_FILE)"

	# Prepare a temporary folder with the .app and an Applications symlink
	@mkdir -p "$(BUILD_DIR)/dmg_tmp"
	@cp -R "$(APP_BUNDLE)" "$(BUILD_DIR)/dmg_tmp/"
	@ln -s /Applications "$(BUILD_DIR)/dmg_tmp/Applications"

	# Build the DMG
	@hdiutil create -volname "$(APP_NAME)" \
		-srcfolder "$(BUILD_DIR)/dmg_tmp" \
		-ov -format UDZO \
		"$(DMG_FILE)"

	# Sign the DMG (skip for ad-hoc identity)
	@if [ "$(CODESIGN_IDENTITY)" != "-" ]; then \
		codesign --force --sign "$(CODESIGN_IDENTITY)" --timestamp "$(DMG_FILE)"; \
	fi

	# Clean up
	@rm -rf "$(BUILD_DIR)/dmg_tmp"

	@echo "==> $(DMG_FILE) is ready"

# ------------------------------------------------------------------
# run – build debug and launch the executable
# ------------------------------------------------------------------
run: build
	"$$(swift build --show-bin-path)/$(APP_NAME)"

# ------------------------------------------------------------------
# clean – remove all build artefacts
# ------------------------------------------------------------------
clean:
	@echo "==> Cleaning build artefacts"
	@rm -rf .build $(BUILD_DIR) Scout.xcodeproj

# ------------------------------------------------------------------
# install – copy the .app bundle to /Applications
# ------------------------------------------------------------------
install: app
	@echo "==> Installing $(APP_NAME).app to /Applications"
	@cp -R "$(APP_BUNDLE)" /Applications/

# ------------------------------------------------------------------
# uninstall – remove the .app bundle from /Applications
# ------------------------------------------------------------------
uninstall:
	@echo "==> Removing $(APP_NAME).app from /Applications"
	@rm -rf "/Applications/$(APP_NAME).app"

# ------------------------------------------------------------------
# lint – check compilation
# ------------------------------------------------------------------
lint:
	swiftformat --lint .
	swift build

# ------------------------------------------------------------------
# test – run the test suite
# ------------------------------------------------------------------
test:
	swift test

# ------------------------------------------------------------------
# version – extract the short version string from Info.plist
# ------------------------------------------------------------------
version:
	@/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$(INFO_PLIST)"

# ------------------------------------------------------------------
# screenshot – capture a screenshot of the app window
# ------------------------------------------------------------------
screenshot: app
	swift Tools/screenshot.swift

# ------------------------------------------------------------------
# changelog – regenerate CHANGELOG.md from conventional commits
# ------------------------------------------------------------------
changelog:
	git-cliff --output CHANGELOG.md
