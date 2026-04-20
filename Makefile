.PHONY: build test generate clean lint release-install-signing release-clean-signing release-dmg

SCHEME = MFuse
CODESIGN_FLAGS = CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

build:
	xcodebuild -scheme $(SCHEME) build $(CODESIGN_FLAGS)

test:
	cd Packages/MFuseCore && swift test
	cd Packages/MFuseFTP && swift test
	cd Packages/MFuseWebDAV && swift test

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
