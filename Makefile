.PHONY: all build test test-stable test-all generate clean lint release-install-signing release-clean-signing release-dmg

SCHEME = MFuse
CODESIGN_FLAGS = CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

all: build test-stable

build:
	xcodebuild -scheme $(SCHEME) build $(CODESIGN_FLAGS)

test: test-stable

# Stable local/default test subset. Use `make test-all` for the full package matrix.
test-stable:
	cd Packages/MFuseWebDAV && swift test
	cd Packages/MFuseSMB && swift test
	cd Packages/MFuseNFS && swift test
	cd Packages/MFuseGoogleDrive && swift test

# Full verification matrix intended for CI and exhaustive validation.
test-all:
	cd Packages/MFuseWebDAV && swift test
	cd Packages/MFuseSMB && swift test
	cd Packages/MFuseNFS && swift test
	cd Packages/MFuseGoogleDrive && swift test
	cd Packages/MFuseCore && swift test
	cd Packages/MFuseFTP && swift test
	cd Packages/MFuseSFTP && swift test
	cd Packages/MFuseS3 && swift test

generate:
	xcodegen generate

clean:
	xcodebuild -scheme $(SCHEME) clean
	rm -rf DerivedData .build

lint:
	swiftlint

release-install-signing:
	bash scripts/release/install-apple-signing.sh

release-clean-signing:
	bash scripts/release/cleanup-apple-signing.sh

release-dmg:
	bash scripts/release/release-dmg.sh
