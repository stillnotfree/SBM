SHELL := /bin/zsh

APP_NAME := SBM
BUNDLE_NAME := SBM
APP_VERSION := 1.1.12
include Core.lock
CORE_ARCHIVE := .vendor/sing-box-$(CORE_VERSION)-darwin-arm64.tar.gz
CORE_UPSTREAM_BINARY := .vendor/sing-box-upstream
CORE_BINARY := .vendor/sing-box
CORE_DIGEST_FILE := .vendor/sing-box.signed.sha256
CORE_BUILD_INFO := Sources/SBMShared/CoreBuildInfo.swift
BUILD_DIR := .build/arm64-apple-macosx/release
DIST_DIR := dist
APP_BUNDLE := $(DIST_DIR)/$(BUNDLE_NAME).app
DMG := $(DIST_DIR)/$(APP_NAME)-$(APP_VERSION)-arm64.dmg
ASSET_INFO_PLIST := $(DIST_DIR)/asset-info.plist

.PHONY: build core app dmg clean release-check

release-check:
	@if [[ -z "$${TAG:-}" ]]; then \
		echo "TAG is required (for example: make release-check TAG=v$(APP_VERSION))" >&2; \
		exit 2; \
	fi
	swift scripts/release-preflight.swift --root . --tag "$$TAG"

build: core
	swift build -c release --arch arm64

core:
	mkdir -p .vendor
	@if [[ ! -f "$(CORE_ARCHIVE)" ]] \
		|| ! echo "$(CORE_ARCHIVE_SHA256)  $(CORE_ARCHIVE)" | shasum -a 256 --check --status; then \
		curl --fail --location --retry 3 --output "$(CORE_ARCHIVE).tmp" \
			"https://github.com/SagerNet/sing-box/releases/download/v$(CORE_VERSION)/sing-box-$(CORE_VERSION)-darwin-arm64.tar.gz"; \
		echo "$(CORE_ARCHIVE_SHA256)  $(CORE_ARCHIVE).tmp" | shasum -a 256 --check; \
		mv "$(CORE_ARCHIVE).tmp" "$(CORE_ARCHIVE)"; \
	fi
	@if [[ ! -x "$(CORE_UPSTREAM_BINARY)" ]] \
		|| ! echo "$(CORE_BINARY_SHA256)  $(CORE_UPSTREAM_BINARY)" | shasum -a 256 --check --status; then \
		tar -xzf "$(CORE_ARCHIVE)" --strip-components 1 -C .vendor \
			"sing-box-$(CORE_VERSION)-darwin-arm64/sing-box"; \
		mv .vendor/sing-box "$(CORE_UPSTREAM_BINARY)"; \
		chmod 0755 "$(CORE_UPSTREAM_BINARY)"; \
	fi
	@echo "$(CORE_BINARY_SHA256)  $(CORE_UPSTREAM_BINARY)" | shasum -a 256 --check
	@test "$$(xcrun lipo -archs "$(CORE_UPSTREAM_BINARY)")" = "arm64"
	cp "$(CORE_UPSTREAM_BINARY)" "$(CORE_BINARY).tmp"
	codesign --force --sign - --identifier io.nekohasekai.sing-box "$(CORE_BINARY).tmp"
	mv "$(CORE_BINARY).tmp" "$(CORE_BINARY)"
	@shasum -a 256 "$(CORE_BINARY)" | awk '{print $$1}' > "$(CORE_DIGEST_FILE).tmp"
	@mv "$(CORE_DIGEST_FILE).tmp" "$(CORE_DIGEST_FILE)"
	@{ \
		echo 'public enum CoreBuildInfo {'; \
		echo '  public static let version = "$(CORE_VERSION)"'; \
		echo '  public static let signedSHA256 ='; \
		echo '    "'"$$(cat "$(CORE_DIGEST_FILE)")"'"'; \
		echo '}'; \
	} > "$(CORE_BUILD_INFO).tmp"
	@cmp -s "$(CORE_BUILD_INFO).tmp" "$(CORE_BUILD_INFO)" \
		&& rm "$(CORE_BUILD_INFO).tmp" \
		|| mv "$(CORE_BUILD_INFO).tmp" "$(CORE_BUILD_INFO)"
	@"$(CORE_BINARY)" version | head -n 1

app: build
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
	@echo "$$(cat "$(CORE_DIGEST_FILE)")  $(APP_BUNDLE)/Contents/Resources/sing-box" | shasum -a 256 --check
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
