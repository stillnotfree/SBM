SHELL := /bin/zsh

APP_NAME := SBM
BUNDLE_NAME := SBM
APP_VERSION := 1.2.0
include Core.lock
CORE_BINARY := .vendor/sing-box
CORE_BUILD_INFO := Sources/SBMShared/CoreBuildInfo.swift
BUILD_DIR := $(shell swift build -c release --arch arm64 --show-bin-path --disable-sandbox 2>/dev/null)
RESOURCE_BUNDLE := $(BUILD_DIR)/SBM_SBM.bundle/Contents/Resources
DIST_DIR := dist
APP_BUNDLE := $(DIST_DIR)/$(BUNDLE_NAME).app
DMG := $(DIST_DIR)/$(APP_NAME)-$(APP_VERSION)-arm64.dmg
ASSET_INFO_PLIST := $(DIST_DIR)/asset-info.plist
GENERATED_LEGACY_HELPER_PLIST := $(DIST_DIR)/com.stillnotfree.sbm.helper.plist
GENERATED_HELPER_PLIST := $(DIST_DIR)/com.stillnotfree.sbm.helper.v12.plist
RELEASE_TOOL := $(BUILD_DIR)/SBMReleaseManifestTool

.PHONY: build core app validate-packaged-localization dmg clean release-check

release-check:
	@if [[ -z "$${TAG:-}" ]]; then \
		echo "TAG is required (for example: make release-check TAG=v$(APP_VERSION))" >&2; \
		exit 2; \
	fi
	swift scripts/release-preflight.swift --root . --tag "$$TAG"

build: core
	swift build -c release --arch arm64 --disable-sandbox

$(RELEASE_TOOL): Sources/SBMShared/Protocol.swift Sources/SBMShared/ReleaseManifest.swift scripts/release-manifest.swift
	mkdir -p "$(BUILD_DIR)"
	@set -eu; \
	staging="$$(mktemp -d "$(BUILD_DIR)/sbm-release-tool.XXXXXX")"; \
	trap 'rm -rf "$$staging"' EXIT; \
	swiftc -O -module-cache-path "$$staging" \
		Sources/SBMShared/Protocol.swift Sources/SBMShared/ReleaseManifest.swift \
		scripts/release-manifest.swift -o "$@"

core:
	mkdir -p .vendor
	@set -eu; \
	root="$$(pwd)"; \
	staging="$$(mktemp -d "$$root/.vendor/sbm-core-build.XXXXXX")"; \
	trap 'rm -rf "$$staging"' EXIT; \
	source="$$staging/sing-box-source"; unsigned="$$staging/sing-box-unsigned"; \
	signed="$$staging/sing-box-signed"; build_info="$$staging/CoreBuildInfo.swift"; \
	fetch_tag() { \
		git -C "$$1" fetch --depth=1 --no-tags --force \
			https://github.com/SagerNet/sing-box.git \
			"+refs/tags/v$(CORE_VERSION):refs/tags/v$(CORE_VERSION)" >/dev/null; \
		resolved="$$(git -C "$$1" rev-parse "refs/tags/v$(CORE_VERSION)^{commit}")"; \
		if [[ "$$resolved" != "$(CORE_REVISION)" ]]; then \
			echo "sing-box v$(CORE_VERSION) resolved to $$resolved, expected $(CORE_REVISION)" >&2; \
			return 1; \
		fi; \
	}; \
	mkdir -p "$$source"; \
	git -C "$$source" init -q; \
	git -C "$$source" remote add origin https://github.com/SagerNet/sing-box.git; \
	fetch_tag "$$source"; \
	git -C "$$source" checkout --quiet --detach "$(CORE_REVISION)"; \
	resolved="$$(git -C "$$source" rev-parse "refs/tags/v$(CORE_VERSION)^{commit}")"; \
	test "$$resolved" = "$(CORE_REVISION)"; \
	test "$$(git -C "$$source" rev-parse HEAD)" = "$(CORE_REVISION)"; \
	test -z "$$(git -C "$$source" status --porcelain --untracked-files=all)"; \
	source_go="$$(awk '$$1 == "go" { count++; value = $$2 } END { if (count != 1) exit 1; print value }' "$$source/go.mod")"; \
	test "$$source_go" = "$(CORE_GO_DIRECTIVE)"; \
	core_flags="$$(awk '$$1 == "CORE_LDFLAGS" && $$2 == ":=" { sub(/^[^:]*:=[ \t]*/, ""); count++; value = $$0 } END { if (count != 1) exit 1; print value }' "$$root/Core.lock")"; \
	source_flags="$$(cat "$$source/release/LDFLAGS")"; \
	test "$$source_flags" = "$$core_flags"; \
	cd "$$source"; \
	test "$$(env GOTOOLCHAIN=go$(CORE_GO_VERSION) GOWORK=off GOFLAGS= GOOS=darwin GOARCH=arm64 CGO_ENABLED=$(CORE_CGO_ENABLED) go env GOVERSION)" = "go$(CORE_GO_VERSION)"; \
	env GOTOOLCHAIN=go$(CORE_GO_VERSION) GOWORK=off GOFLAGS= GOOS=darwin GOARCH=arm64 CGO_ENABLED=$(CORE_CGO_ENABLED) go build \
		-mod=readonly -trimpath -tags "$(CORE_BUILD_TAGS)" \
		-ldflags "$$core_flags -X github.com/sagernet/sing-box/constant.Version=$(CORE_VERSION) -s -w -buildid=" \
		-o "$$unsigned" ./cmd/sing-box; \
	architectures="$$(xcrun lipo -archs "$$unsigned")"; \
	test "$$architectures" = arm64; \
	version_output="$$( "$$unsigned" version)"; \
	first_line="$$(printf '%s\n' "$$version_output" | sed -n '1p')"; \
	test "$$first_line" = "sing-box version $(CORE_VERSION)"; \
	printf '%s\n' "$$version_output" | grep -Fx "Environment: go$(CORE_GO_VERSION) darwin/arm64" >/dev/null; \
	printf '%s\n' "$$version_output" | grep -Fx "Tags: $(CORE_BUILD_TAGS)" >/dev/null; \
	printf '%s\n' "$$version_output" | grep -Fx "Revision: $(CORE_REVISION)" >/dev/null; \
	expected_cgo=enabled; if [[ "$(CORE_CGO_ENABLED)" == 0 ]]; then expected_cgo=disabled; fi; \
	printf '%s\n' "$$version_output" | grep -Fx "CGO: $$expected_cgo" >/dev/null; \
	unsigned_digest="$$(shasum -a 256 "$$unsigned" | awk '{print $$1}')"; \
	cp "$$unsigned" "$$signed"; \
	codesign --force --sign - --identifier io.nekohasekai.sing-box --timestamp=none "$$signed"; \
	codesign --verify --strict --verbose=2 "$$signed"; \
	codesign --display --verbose=2 "$$signed" 2>&1 | grep -Fx 'Identifier=io.nekohasekai.sing-box' >/dev/null; \
	mv -f "$$signed" "$$root/$(CORE_BINARY)"; \
	signed_digest="$$(shasum -a 256 "$$root/$(CORE_BINARY)" | awk '{print $$1}')"; \
	signed_size="$$(stat -f %z "$$root/$(CORE_BINARY)")"; \
	signed_size_literal="$$(awk -v size="$$signed_size" 'BEGIN { while (length(size) > 3) { suffix = "_" substr(size, length(size) - 2) suffix; size = substr(size, 1, length(size) - 3) } print size suffix }')"; \
	swift_flags="$$(printf '%s' "$$core_flags" | sed 's/\\/\\\\/g; s/"/\\"/g')"; \
	{ \
		echo 'public enum CoreBuildInfo {'; \
		echo '  public static let version = "$(CORE_VERSION)"'; \
		echo '  public static let revision = "$(CORE_REVISION)"'; \
		echo '  public static let goVersion = "go$(CORE_GO_VERSION)"'; \
		echo '  public static let buildTags = "$(CORE_BUILD_TAGS)"'; \
		echo '  public static let cgo = "'"$$expected_cgo"'"'; \
		echo '  public static let linkerFlags ='; \
		printf '    "%s"\n' "$$swift_flags"; \
		echo "  public static let signedSize: Int64 = $$signed_size_literal"; \
		echo '  public static let unsignedSHA256 ='; \
		echo '    "'"$$unsigned_digest"'"'; \
		echo '  public static let signedSHA256 ='; \
		echo '    "'"$$signed_digest"'"'; \
		echo '}'; \
	} > "$$build_info"; \
	if ! cmp -s "$$build_info" "$$root/$(CORE_BUILD_INFO)"; then \
		mv -f "$$build_info" "$$root/$(CORE_BUILD_INFO)"; \
	fi; \
	printf '%s\n' "$$version_output" | sed -n '1,6p'

app: build $(RELEASE_TOOL)
	codesign --force --sign - --identifier com.stillnotfree.sbm.helper \
		--options runtime --timestamp=none "$(BUILD_DIR)/SBMHelper"
	mkdir -p "$(DIST_DIR)"
	"$(RELEASE_TOOL)" helper-plist \
		--helper "$(BUILD_DIR)/SBMHelper" \
		--template Resources/com.stillnotfree.sbm.helper.plist \
		--output "$(GENERATED_LEGACY_HELPER_PLIST)"
	"$(RELEASE_TOOL)" helper-plist \
		--helper "$(BUILD_DIR)/SBMHelper" \
		--template Resources/com.stillnotfree.sbm.helper.v12.plist \
		--output "$(GENERATED_HELPER_PLIST)"
	rm -rf "$(APP_BUNDLE)"
	mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	mkdir -p "$(APP_BUNDLE)/Contents/Library/LaunchDaemons"
	cp "$(BUILD_DIR)/SBM" "$(APP_BUNDLE)/Contents/MacOS/SBM"
	cp "$(BUILD_DIR)/SBMHelper" "$(APP_BUNDLE)/Contents/Resources/SBMHelper"
	cp "$(CORE_BINARY)" "$(APP_BUNDLE)/Contents/Resources/sing-box"
	cp -R "$(RESOURCE_BUNDLE)/en.lproj" "$(APP_BUNDLE)/Contents/Resources/"
	cp -R "$(RESOURCE_BUNDLE)/ru.lproj" "$(APP_BUNDLE)/Contents/Resources/"
	cp -R "$(RESOURCE_BUNDLE)/zh-hans.lproj" "$(APP_BUNDLE)/Contents/Resources/zh-Hans.lproj"
	cp THIRD_PARTY_NOTICES.md "$(APP_BUNDLE)/Contents/Resources/THIRD_PARTY_NOTICES.md"
	cp Resources/Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	cp "$(GENERATED_LEGACY_HELPER_PLIST)" "$(APP_BUNDLE)/Contents/Library/LaunchDaemons/com.stillnotfree.sbm.helper.plist"
	cp "$(GENERATED_HELPER_PLIST)" "$(APP_BUNDLE)/Contents/Library/LaunchDaemons/com.stillnotfree.sbm.helper.v12.plist"
	$(MAKE) validate-packaged-localization
	xcrun actool \
		--compile "$(APP_BUNDLE)/Contents/Resources" \
		--platform macosx \
		--minimum-deployment-target 26.0 \
		--app-icon AppIcon \
		--standalone-icon-behavior all \
		--output-partial-info-plist "$(ASSET_INFO_PLIST)" \
		Resources/AppIcon.icon
	/usr/libexec/PlistBuddy -c "Merge $(ASSET_INFO_PLIST)" "$(APP_BUNDLE)/Contents/Info.plist"
	codesign --force --sign - --identifier com.stillnotfree.sbm \
		--options runtime --timestamp=none "$(APP_BUNDLE)"
	"$(RELEASE_TOOL)" sign-attach-verify \
		--app "$(APP_BUNDLE)" \
		--core-digest-file "$(CORE_BUILD_INFO)"
	codesign --verify --deep --strict --verbose=2 "$(APP_BUNDLE)"

validate-packaged-localization:
	swift scripts/validate-packaged-localization.swift --app "$(APP_BUNDLE)"

dmg: app
	@set -euo pipefail; \
	workdir=""; \
	mounted=0; \
	detach_mounted_image() { \
		if hdiutil detach "$$mountpoint"; then \
			mounted=0; \
		else \
			local detach_status=$$?; \
			return "$$detach_status"; \
		fi; \
	}; \
	cleanup() { \
		local cleanup_status=$$?; \
		if [[ "$$mounted" == 1 ]]; then \
			if ! detach_mounted_image >/dev/null 2>&1; then \
				printf 'DMG detach failed; retaining mount and recovery image at %s.\n' "$$workdir" >&2; \
			fi; \
		fi; \
		if [[ -n "$$workdir" ]]; then \
			if [[ "$$mounted" == 1 ]]; then \
				printf 'DMG remains mounted; preserve writable image at %s for manual recovery.\n' "$$workdir" >&2; \
			elif rm -rf "$$workdir"; then :; \
			else \
				local remove_status=$$?; \
				printf 'Could not remove DMG staging directory %s (status %s).\n' "$$workdir" "$$remove_status" >&2; \
				if [[ "$$cleanup_status" == 0 ]]; then cleanup_status=$$remove_status; fi; \
			fi; \
		fi; \
		return "$$cleanup_status"; \
	}; \
	trap cleanup EXIT; \
	trap 'exit 1' HUP INT TERM; \
	workdir="$$(mktemp -d "$(DIST_DIR)/sbm-dmg-build.XXXXXX")"; \
	staging="$$workdir/staging"; \
	mountpoint="/Volumes/$(APP_NAME)"; \
	rw_dmg="$$workdir/writable.dmg"; \
	mkdir -p "$$staging/.background"; \
	ditto "$(APP_BUNDLE)" "$$staging/$(BUNDLE_NAME).app"; \
	ln -s /Applications "$$staging/Applications"; \
	cp "Resources/DMG/background.png" "$$staging/.background/background.png"; \
	hdiutil create -volname "$(APP_NAME)" -srcfolder "$$staging" -ov -format UDRW "$$rw_dmg"; \
	[[ ! -e "$$mountpoint" && ! -h "$$mountpoint" ]] || { echo "DMG mountpoint already exists: $$mountpoint" >&2; exit 1; }; \
	hdiutil attach -readwrite -mountpoint "$$mountpoint" "$$rw_dmg"; \
	mounted=1; \
	osascript scripts/configure-dmg.applescript "$(APP_NAME)"; \
	sync; \
	detach_mounted_image || exit $$?; \
	hdiutil convert "$$rw_dmg" -format UDZO -o "$(DMG)" -ov; \
	rm -rf "$$workdir"; \
	(cd "$(DIST_DIR)" && shasum -a 256 "$(notdir $(DMG))" > "$(notdir $(DMG)).sha256"); \
	"$(RELEASE_TOOL)" sign-update-artifact --dmg "$(DMG)" --core-digest-file "$(CORE_BUILD_INFO)"

clean:
	rm -rf .build "$(DIST_DIR)"
