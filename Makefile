SHELL := /bin/zsh

APP_NAME := SBM
BUNDLE_NAME := SBM
APP_VERSION := 1.1.0
CORE_VERSION := 1.13.14
CORE_SHA256 := 73e8967b0fc08e17bce4263ca56ebc394822401a16497a1c4e02316c888202ab
CORE_BINARY_SHA256 := 813d8effd02a19572a8d75aef29fc073101404ca535b2496be86f21827c7684d
SIGNED_CORE_SHA256 := a74ca72d18f7fbf5756170927f257e0a27e51ba8a590d1a8388bffd2300cee4f
CORE_ARCHIVE := .vendor/sing-box-$(CORE_VERSION)-darwin-arm64.tar.gz
CORE_BINARY := .vendor/sing-box
BUILD_DIR := .build/arm64-apple-macosx/release
DIST_DIR := dist
APP_BUNDLE := $(DIST_DIR)/$(BUNDLE_NAME).app
DMG := $(DIST_DIR)/$(APP_NAME)-$(APP_VERSION)-arm64.dmg
ASSET_INFO_PLIST := $(DIST_DIR)/asset-info.plist

.PHONY: build core app dmg clean

build:
	swift build -c release --arch arm64

core:
	mkdir -p .vendor
	@if [[ ! -x "$(CORE_BINARY)" ]]; then \
		curl --fail --location --retry 3 --output "$(CORE_ARCHIVE).tmp" \
			"https://github.com/SagerNet/sing-box/releases/download/v$(CORE_VERSION)/sing-box-$(CORE_VERSION)-darwin-arm64.tar.gz"; \
		echo "$(CORE_SHA256)  $(CORE_ARCHIVE).tmp" | shasum -a 256 --check; \
		mv "$(CORE_ARCHIVE).tmp" "$(CORE_ARCHIVE)"; \
		tar -xzf "$(CORE_ARCHIVE)" --strip-components 1 -C .vendor \
			"sing-box-$(CORE_VERSION)-darwin-arm64/sing-box"; \
		chmod 0755 "$(CORE_BINARY)"; \
	fi
	@echo "$(CORE_BINARY_SHA256)  $(CORE_BINARY)" | shasum -a 256 --check
	@"$(CORE_BINARY)" version | head -n 1

app: build core
	@grep -Fq '"$(SIGNED_CORE_SHA256)"' Sources/SBMHelper/CoreManager.swift
	rm -rf "$(APP_BUNDLE)"
	mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	mkdir -p "$(APP_BUNDLE)/Contents/Library/LaunchDaemons"
	cp "$(BUILD_DIR)/SBM" "$(APP_BUNDLE)/Contents/MacOS/SBM"
	cp "$(BUILD_DIR)/SBMHelper" "$(APP_BUNDLE)/Contents/Resources/SBMHelper"
	cp "$(CORE_BINARY)" "$(APP_BUNDLE)/Contents/Resources/sing-box"
	cp THIRD_PARTY_NOTICES.md "$(APP_BUNDLE)/Contents/Resources/THIRD_PARTY_NOTICES.md"
	cp Resources/Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	cp Resources/com.stillnotfree.sbm.helper.plist "$(APP_BUNDLE)/Contents/Library/LaunchDaemons/"
	xcrun actool \
		--compile "$(APP_BUNDLE)/Contents/Resources" \
		--platform macosx \
		--minimum-deployment-target 26.0 \
		--app-icon AppIcon \
		--standalone-icon-behavior all \
		--output-partial-info-plist "$(ASSET_INFO_PLIST)" \
		Resources/AppIcon.icon
	/usr/libexec/PlistBuddy -c "Merge $(ASSET_INFO_PLIST)" "$(APP_BUNDLE)/Contents/Info.plist"
	codesign --force --sign - --identifier io.nekohasekai.sing-box "$(APP_BUNDLE)/Contents/Resources/sing-box"
	@echo "$(SIGNED_CORE_SHA256)  $(APP_BUNDLE)/Contents/Resources/sing-box" | shasum -a 256 --check
	codesign --force --sign - --identifier com.stillnotfree.sbm.helper "$(APP_BUNDLE)/Contents/Resources/SBMHelper"
	codesign --force --sign - "$(APP_BUNDLE)"
	codesign --verify --deep --strict --verbose=2 "$(APP_BUNDLE)"

dmg: app
	rm -rf "$(DIST_DIR)/dmg-root" "$(DMG)"
	mkdir -p "$(DIST_DIR)/dmg-root"
	cp -R "$(APP_BUNDLE)" "$(DIST_DIR)/dmg-root/"
	ln -s /Applications "$(DIST_DIR)/dmg-root/Applications"
	hdiutil create -volname "$(APP_NAME)" -srcfolder "$(DIST_DIR)/dmg-root" -ov -format UDZO "$(DMG)"
	shasum -a 256 "$(DMG)" > "$(DMG).sha256"
	rm -rf "$(DIST_DIR)/dmg-root"

clean:
	rm -rf .build "$(DIST_DIR)"
