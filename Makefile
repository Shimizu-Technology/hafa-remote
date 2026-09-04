.PHONY: format gate release-preflight test

format:
	xcrun swift-format format --in-place --recursive HafaRemote HafaRemoteTests HafaRemoteUITests

gate:
	./scripts/gate.sh

release-preflight:
	./scripts/ios-release-preflight.sh

test:
	./scripts/gate.sh
