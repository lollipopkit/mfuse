.PHONY: all build test test-stable test-all generate clean lint debug-install release-install release-dmg sync-homebrew-cask release

SCHEME = MFuse
APP_NAME = MFuse
DEBUG_DERIVED_DATA = DerivedData
DEBUG_APP_PATH = $(DEBUG_DERIVED_DATA)/Build/Products/Debug/$(APP_NAME).app
RELEASE_INSTALL_DERIVED_DATA = build/release-install-derived-data
RELEASE_INSTALL_APP_PATH = $(RELEASE_INSTALL_DERIVED_DATA)/Build/Products/Release/$(APP_NAME).app
RELEASE_INSTALL_STAGING_PATH = build/release-install-staging/$(APP_NAME).app
# Same derivation as scripts/release/release-from-git-version.sh.
COMMIT_COUNT = $(shell git rev-list --count HEAD)
RELEASE_MARKETING_VERSION = $(or $(MFUSE_BASE_VERSION),1.0).$(COMMIT_COUNT)
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

# Deliberately does NOT pass $(CODESIGN_FLAGS): an ad-hoc signed bundle has no team
# identifier, so the File Provider extension never registers with the system
# (`pluginkit` cannot see it) and no domain can be mounted. Installing a debug build
# that is useful for testing requires real signing, which comes from project.local.yml.
debug-install: generate
	xcodebuild -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DEBUG_DERIVED_DATA) build
	rm -rf /Applications/$(APP_NAME).app
	ditto $(DEBUG_APP_PATH) /Applications/$(APP_NAME).app

# A Release build installed locally, signed the way `make release` signs it (Developer ID
# and the Release profiles from project.local.yml, hardened runtime) so problems that only
# show up in a release build can be reproduced without archiving, notarizing or publishing.
release-install: generate
	xcodebuild -scheme $(SCHEME) -configuration Release -derivedDataPath $(RELEASE_INSTALL_DERIVED_DATA) build \
		MARKETING_VERSION="$(RELEASE_MARKETING_VERSION)" \
		CURRENT_PROJECT_VERSION="$(COMMIT_COUNT)" \
		OTHER_CODE_SIGN_FLAGS="--options runtime"
	# Copied to a staging path first, so a failed copy leaves the installed app in place;
	# staged outside /Applications so Launch Services never registers a second copy.
	rm -rf $(RELEASE_INSTALL_STAGING_PATH)
	ditto $(RELEASE_INSTALL_APP_PATH) $(RELEASE_INSTALL_STAGING_PATH)
	rm -rf /Applications/$(APP_NAME).app
	mv $(RELEASE_INSTALL_STAGING_PATH) /Applications/$(APP_NAME).app

release-dmg:
	@test -n "$(XCARCHIVE_PATH)" || (echo "release-dmg requires XCARCHIVE_PATH. Example: XCARCHIVE_PATH=/abs/path/to/MFuse.xcarchive make release-dmg; this target calls scripts/release/package-dmg-from-xcarchive.sh." >&2; exit 1)
	bash scripts/release/package-dmg-from-xcarchive.sh

sync-homebrew-cask:
	bash scripts/release/sync-homebrew-cask.sh

release:
	bash scripts/release/release-from-git-version.sh
