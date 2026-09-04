.PHONY: format gate release-preflight test

format:
	xcrun swift-format format --in-place --recursive HafaRemote HafaRemoteTests HafaRemoteUITests

gate:
	./scripts/gate.sh

release-preflight:
	./scripts/ios-release-preflight.sh

test:
	xcodebuild -project HafaRemote.xcodeproj -scheme HafaRemote -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test CODE_SIGNING_ALLOWED=NO
