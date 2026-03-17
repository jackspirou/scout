# ------------------------------------------------------------------
# Scout macOS App – Makefile
# ------------------------------------------------------------------

# Variables
APP_NAME   := Scout
BUNDLE_ID  := com.jackspirou.scout
BUILD_DIR  := build

# Paths – source artifacts
INFO_PLIST   := Sources/ScoutLib/Resources/Info.plist
ENTITLEMENTS := Sources/ScoutLib/Resources/Scout.entitlements
ICONSET_DIR  := Sources/ScoutLib/Resources/AppIcon.iconset

# Paths – build artifacts
APP_BUNDLE     := $(BUILD_DIR)/$(APP_NAME).app
APP_CONTENTS   := $(APP_BUNDLE)/Contents
APP_MACOS      := $(APP_CONTENTS)/MacOS
APP_RESOURCES  := $(APP_CONTENTS)/Resources
RELEASE_BIN    := $(shell swift build -c release --show-bin-path 2>/dev/null)/$(APP_NAME)
DEBUG_BIN      := $(shell swift build --show-bin-path 2>/dev/null)/$(APP_NAME)
DMG_FILE       := $(BUILD_DIR)/$(APP_NAME).dmg

# ------------------------------------------------------------------
# Phony targets
# ------------------------------------------------------------------
.PHONY: build release app dmg run clean install uninstall lint test version changelog screenshot

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
# app – assemble a proper macOS .app bundle from the release binary
# ------------------------------------------------------------------
app: release
	@echo "==> Assembling $(APP_BUNDLE)"

	# Remove previous bundle to avoid codesign permission issues on overwrite
	@rm -rf "$(APP_BUNDLE)"

	# Create bundle directory structure
	@mkdir -p "$(APP_MACOS)"
	@mkdir -p "$(APP_RESOURCES)"

	# Copy the release binary
	@cp "$(RELEASE_BIN)" "$(APP_MACOS)/$(APP_NAME)"

	# Copy Info.plist into Contents/ and create PkgInfo
	@cp "$(INFO_PLIST)" "$(APP_CONTENTS)/Info.plist"
	@printf 'APPL????' > "$(APP_CONTENTS)/PkgInfo"

	# Copy entitlements into Resources/
	@cp "$(ENTITLEMENTS)" "$(APP_RESOURCES)/$(APP_NAME).entitlements"

	# Copy SPM resource bundles (syntax highlighter themes, markdown template, etc.)
	@for bundle in $$(find $$(dirname "$(RELEASE_BIN)") -name '*.bundle' -maxdepth 1); do \
		echo "==> Copying $$(basename $$bundle)"; \
		cp -R "$$bundle" "$(APP_RESOURCES)/"; \
	done

	# Compile Asset Catalog with actool (produces Assets.car with squircle-masked icon)
	@echo "==> Compiling Asset Catalog"
	@/Applications/Xcode.app/Contents/Developer/usr/bin/actool \
		Sources/ScoutLib/Resources/Assets.xcassets \
		--compile "$(APP_RESOURCES)" \
		--platform macosx \
		--minimum-deployment-target 14.0 \
		--app-icon AppIcon \
		--output-partial-info-plist /dev/null 2>/dev/null

	# Ad-hoc code sign the bundle (seals Resources + binds Info.plist)
	@echo "==> Code signing $(APP_BUNDLE)"
	@codesign --force --deep --sign - "$(APP_BUNDLE)"

	@echo "==> $(APP_BUNDLE) is ready"

# ------------------------------------------------------------------
# dmg – create a distributable disk image from the .app bundle
# ------------------------------------------------------------------
dmg: app
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

	# Clean up
	@rm -rf "$(BUILD_DIR)/dmg_tmp"

	@echo "==> $(DMG_FILE) is ready"

# ------------------------------------------------------------------
# run – build debug and launch the executable
# ------------------------------------------------------------------
run: build
	"$(DEBUG_BIN)"

# ------------------------------------------------------------------
# clean – remove all build artefacts
# ------------------------------------------------------------------
clean:
	@echo "==> Cleaning build artefacts"
	@rm -rf .build $(BUILD_DIR)

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
