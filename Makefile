# ------------------------------------------------------------------
# Scout macOS App – Makefile
# ------------------------------------------------------------------

# Variables
APP_NAME   := Scout
BUNDLE_ID  := com.jackspirou.scout
BUILD_DIR  := build

# Paths – source artifacts
INFO_PLIST   := Sources/Scout/Resources/Info.plist
ENTITLEMENTS := Sources/Scout/Resources/Scout.entitlements
ICONSET_DIR  := Sources/Scout/Resources/AppIcon.iconset

# Paths – build artifacts
APP_BUNDLE     := $(BUILD_DIR)/$(APP_NAME).app
APP_CONTENTS   := $(APP_BUNDLE)/Contents
APP_MACOS      := $(APP_CONTENTS)/MacOS
APP_RESOURCES  := $(APP_CONTENTS)/Resources
RELEASE_BIN    := .build/release/$(APP_NAME)
DEBUG_BIN      := .build/debug/$(APP_NAME)
DMG_FILE       := $(BUILD_DIR)/$(APP_NAME).dmg

# ------------------------------------------------------------------
# Phony targets
# ------------------------------------------------------------------
.PHONY: build release app dmg run clean install uninstall lint test version

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

	# Create bundle directory structure
	@mkdir -p "$(APP_MACOS)"
	@mkdir -p "$(APP_RESOURCES)"

	# Copy the release binary
	@cp "$(RELEASE_BIN)" "$(APP_MACOS)/$(APP_NAME)"

	# Copy Info.plist into Contents/
	@cp "$(INFO_PLIST)" "$(APP_CONTENTS)/Info.plist"

	# Copy entitlements into Resources/
	@cp "$(ENTITLEMENTS)" "$(APP_RESOURCES)/$(APP_NAME).entitlements"

	# Generate .icns from .iconset if both iconutil and the source exist
	@if command -v iconutil >/dev/null 2>&1 && [ -d "$(ICONSET_DIR)" ]; then \
		echo "==> Generating AppIcon.icns from $(ICONSET_DIR)"; \
		iconutil -c icns "$(ICONSET_DIR)" -o "$(APP_RESOURCES)/AppIcon.icns"; \
	else \
		echo "==> Skipping icon generation (iconutil or $(ICONSET_DIR) not found)"; \
	fi

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
	swift build

# ------------------------------------------------------------------
# test – placeholder until a test suite is added
# ------------------------------------------------------------------
test:
	@echo "No tests yet"

# ------------------------------------------------------------------
# version – extract the short version string from Info.plist
# ------------------------------------------------------------------
version:
	@/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$(INFO_PLIST)"
