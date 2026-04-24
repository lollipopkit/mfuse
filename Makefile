.PHONY: all build test test-stable test-all generate clean lint debug-install release-dmg sync-homebrew-cask release

SCHEME = MFuse
APP_NAME = MFuse
DEBUG_DERIVED_DATA = DerivedData
DEBUG_APP_PATH = $(DEBUG_DERIVED_DATA)/Build/Products/Debug/$(APP_NAME).app
CODESIGN_FLAGS = CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
LOCAL_PROJECT_SPEC = project.local.yml
XCODEGEN_ENV =

ifneq ($(wildcard $(LOCAL_PROJECT_SPEC)),)
XCODEGEN_ENV := INCLUDE_PROJECT_LOCAL_YML=1
endif

all: build test-stable

build:
	xcodebuild -scheme $(SCHEME) build $(CODESIGN_FLAGS)

test: test-stable

# Stable local/default smoke-test subset.
# Intentionally excludes MFuseCore and other broader suites; use `make test-all`
# for the full verification matrix.
test-stable:
	cd Packages/MFuseWebDAV && swift test
	cd Packages/MFuseSMB && swift test
	cd Packages/MFuseNFS && swift test
	cd Packages/MFuseGoogleDrive && swift test
	cd Packages/MFuseDropbox && swift test
	cd Packages/MFuseOneDrive && swift test

# Full verification matrix intended for CI and exhaustive validation.
test-all:
	cd Packages/MFuseWebDAV && swift test
	cd Packages/MFuseSMB && swift test
	cd Packages/MFuseNFS && swift test
	cd Packages/MFuseGoogleDrive && swift test
	cd Packages/MFuseDropbox && swift test
	cd Packages/MFuseOneDrive && swift test
	cd Packages/MFuseCore && swift test
	cd Packages/MFuseFTP && swift test
	cd Packages/MFuseSFTP && swift test
	cd Packages/MFuseS3 && swift test

generate:
	$(XCODEGEN_ENV) xcodegen generate

clean:
	xcodebuild -scheme $(SCHEME) clean
	rm -rf DerivedData .build

lint:
	swiftlint

debug-install:
	xcodebuild -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DEBUG_DERIVED_DATA) build $(CODESIGN_FLAGS)
	rm -rf /Applications/$(APP_NAME).app
	ditto $(DEBUG_APP_PATH) /Applications/$(APP_NAME).app

release-dmg:
	@test -n "$(XCARCHIVE_PATH)" || (echo "release-dmg requires XCARCHIVE_PATH. Example: XCARCHIVE_PATH=/abs/path/to/MFuse.xcarchive make release-dmg; this target calls scripts/release/package-dmg-from-xcarchive.sh." >&2; exit 1)
	bash scripts/release/package-dmg-from-xcarchive.sh

sync-homebrew-cask:
	bash scripts/release/sync-homebrew-cask.sh

release:
	bash scripts/release/release-from-git-version.sh
