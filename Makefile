.PHONY: archive export format gate release-preflight test

archive:
	./scripts/ios-release.sh archive

export:
	./scripts/ios-release.sh export "$(ARCHIVE_PATH)"

format:
	xcrun swift-format format --in-place --recursive HafaRemote HafaRemoteTests HafaRemoteUITests

gate:
	./scripts/gate.sh

release-preflight:
	./scripts/ios-release-preflight.sh

test:
	./scripts/gate.sh
