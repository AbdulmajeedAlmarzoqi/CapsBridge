#!/bin/bash
# Builds CapsBridge.
#
#   ./scripts/build.sh            release: archive, sign with Developer ID, notarize, staple, zip
#   ./scripts/build.sh dev        local build signed for development, not notarized
#   ./scripts/build.sh ci         unsigned compile check, and the package's tests
#
# A release needs Xcode with the project's Apple Developer account signed in under
# Xcode > Settings > Accounts: Xcode makes and keeps the Developer ID certificate itself.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

MODE=${1:-release}
VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml)
PROJECT=CapsBridge.xcodeproj
SCHEME=CapsBridge
ARCHIVE=build/CapsBridge.xcarchive
DERIVED=build/DerivedData
mkdir -p build

# The project lists its files, so it's regenerated whenever XcodeGen is there to do it.
if command -v xcodegen >/dev/null 2>&1; then
	xcodegen generate --quiet
fi

report() { grep -E "error:|warning: [^M]|BUILD|ARCHIVE|EXPORT|Uploaded" || true; }

case "$MODE" in
ci)
	echo "==> Testing CapsBridgeKit"
	xcrun swift test --package-path Packages/CapsBridgeKit 2>&1 | grep -E "error|✘|Test run|passed|failed"
	echo "==> Compile check (unsigned)"
	xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release -destination "platform=macOS,arch=arm64" \
		-derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM= build | report
	exit 0 ;;
dev)
	echo "==> Local build (CapsBridge $VERSION, signed for development, not notarized)"
	rm -rf build/CapsBridge.app
	xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release -destination "platform=macOS,arch=arm64" \
		-derivedDataPath "$DERIVED" build | report
	cp -R "$DERIVED/Build/Products/Release/CapsBridge.app" build/
	echo "==> Done: build/CapsBridge.app"
	exit 0 ;;
release) ;;
*)
	echo "usage: $0 [release|dev|ci]" >&2
	exit 2 ;;
esac

echo "==> Archiving CapsBridge $VERSION"
rm -rf "$ARCHIVE" build/export build/notarized build/CapsBridge.app build/notarize.log
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release -destination "generic/platform=macOS" \
	-archivePath "$ARCHIVE" -derivedDataPath "$DERIVED" archive -allowProvisioningUpdates | report

echo "==> Signing with Developer ID and sending to Apple's notary service"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist scripts/ExportOptions.plist \
	-exportPath build/export -allowProvisioningUpdates | report

echo "==> Waiting for Apple to notarize"
for attempt in $(seq 1 60); do
	if xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath build/notarized >build/notarize.log 2>&1; then
		echo "notarized (attempt $attempt)"
		break
	fi
	# A rejection won't turn into an acceptance by waiting.
	if grep -q -i -E "invalid|rejected" build/notarize.log; then
		echo "Apple rejected the app; see build/notarize.log" >&2
		exit 1
	fi
	if [ "$attempt" -eq 60 ]; then
		echo "notarization did not finish in 30 minutes; see build/notarize.log" >&2
		exit 1
	fi
	sleep 30
done
APP=build/notarized/CapsBridge.app
cp -R "$APP" build/CapsBridge.app

echo "==> Verifying"
xcrun stapler validate "$APP" | tail -1
codesign --verify --deep --strict --verbose=1 "$APP"
spctl -a -vv -t exec "$APP" 2>&1 | grep -E "source=|origin="
# The app is useless without its helper, so a bundle that lost it never ships.
HELPER="$APP/Contents/Library/LoginItems/CapsBridgeHelper.app"
[ -x "$HELPER/Contents/MacOS/CapsBridgeHelper" ] || { echo "refusing to package: the helper is missing from the bundle" >&2; exit 1; }
[ -f "$APP/Contents/Library/LaunchAgents/com.abdulmajeedalmarzoqi.capsbridge.helper.plist" ] ||
	{ echo "refusing to package: the helper's property list is missing from the bundle" >&2; exit 1; }
team() { codesign -dv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p'; }
[ -n "$(team "$HELPER")" ] && [ "$(team "$HELPER")" = "$(team "$APP")" ] ||
	{ echo "refusing to package: the helper isn't signed by the app's team" >&2; exit 1; }
[ -d "$APP/Contents/Resources/ar.lproj" ] || { echo "refusing to package: the Arabic localization is missing" >&2; exit 1; }
echo "bundle: helper, property list and localization OK"

ZIP="build/CapsBridge-$VERSION.zip"
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"
echo "==> Done: build/CapsBridge.app and $ZIP"
