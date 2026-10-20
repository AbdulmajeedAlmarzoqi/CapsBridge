#!/bin/bash
# Run by Xcode after the frameworks are embedded. Sparkle's own Arabic covers few of its messages,
# so the complete translation in Resources/Sparkle replaces it, and the framework is signed again
# to seal the change (an export re-signs it once more with Developer ID).
set -euo pipefail
framework="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/Sparkle.framework"
[ -d "$framework" ] || { echo "error: Sparkle.framework isn't embedded" >&2; exit 1; }
for source in "${SRCROOT}"/Resources/Sparkle/*.lproj/Sparkle.strings; do
	language=$(basename "$(dirname "$source")")
	destination="$framework/Versions/B/Resources/$language/Sparkle.strings"
	mkdir -p "$(dirname "$destination")"
	plutil -convert binary1 -o "$destination" "$source"
done
if [ "${CODE_SIGNING_ALLOWED:-YES}" = "YES" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
	codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --options runtime --timestamp=none \
		--preserve-metadata=identifier,entitlements,flags "$framework/Versions/B"
fi
