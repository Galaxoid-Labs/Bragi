#!/usr/bin/env bash
#
# package_macos.sh — build Bragi.app and Bragi.dmg for macOS.
#
# Reads deploy.ini at the repo root for metadata (name, identifier,
# version, code-signing identity, etc.). Run from the repo root or
# from anywhere; the script `cd`s to the repo root itself.
#
# Outputs:
#   dist/macos/Bragi.app/                      ← runnable bundle
#   dist/macos/Bragi-<version>.dmg             ← distributable disk image
#
# Stages (each can be skipped via env var, useful when iterating):
#   STAGE_BUILD=0    skip the `odin build` step
#   STAGE_BUNDLE=0   skip the bundle assembly + dylib gathering
#   STAGE_SIGN=0     skip code-signing
#   STAGE_DMG=0      skip the .dmg
#
# Requirements (all part of macOS / Xcode CLT — no extra installs):
#   sips, iconutil, plutil, codesign, hdiutil, otool, install_name_tool
# Plus, of course, a working `odin` and the Homebrew-installed runtime
# libs (sdl3, sdl3_ttf, libvterm).

set -euo pipefail

# ──────────────────────────────────────────────────────────────────
# Locate the repo root and cd into it. Lets us run as
# `./tools/package_macos.sh`, `bash tools/package_macos.sh`, or from
# anywhere via absolute path — output paths stay consistent.
# ──────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

DEPLOY_INI="$REPO_ROOT/deploy.ini"
[[ -f "$DEPLOY_INI" ]] || { echo "error: deploy.ini not found at $DEPLOY_INI"; exit 1; }

# ──────────────────────────────────────────────────────────────────
# Tiny INI reader. Picks values out of `deploy.ini` honoring [section]
# scoping so the same key can appear in [common] and [macos] without
# colliding. Falls back to [common] when the section-specific entry
# is missing or blank.
#
#   ini_get <section> <key>          → echoes the value, "" if absent
#   ini_get_or_common <macos> <key>  → tries [macos] then [common]
# ──────────────────────────────────────────────────────────────────
ini_get() {
	local section="$1" key="$2"
	awk -v want="$section" -v key="$key" '
		# Section header (`[name]` possibly indented). Compare the inner
		# name as plain text against `want`, not via a regex — letters
		# inside the brackets would otherwise be interpreted as a
		# character class.
		/^[[:space:]]*\[.*\][[:space:]]*$/ {
			line = $0
			sub(/^[[:space:]]*\[/, "", line)
			sub(/\][[:space:]]*$/, "", line)
			in_section = (line == want)
			next
		}
		in_section && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
			sub(/^[^=]*=[[:space:]]*/, "")
			sub(/[[:space:]]+$/, "")
			print
			exit
		}
	' "$DEPLOY_INI"
}

ini_get_or_common() {
	local v
	v="$(ini_get "$1" "$2")"
	if [[ -z "$v" ]]; then
		v="$(ini_get "common" "$2")"
	fi
	echo "$v"
}

require() {
	local var="$1" value="$2"
	if [[ -z "$value" ]]; then
		echo "error: deploy.ini is missing required key: $var"
		exit 1
	fi
}

# ──────────────────────────────────────────────────────────────────
# Pull every value we'll need up front. Trip on the missing required
# ones immediately rather than failing partway through.
# ──────────────────────────────────────────────────────────────────
APP_NAME="$(ini_get common name)"               ; require "common.name"        "$APP_NAME"
BIN_NAME="$(ini_get common binary_name)"        ; require "common.binary_name" "$BIN_NAME"
IDENTIFIER="$(ini_get common identifier)"       ; require "common.identifier"  "$IDENTIFIER"
VERSION="$(ini_get common version)"             ; require "common.version"     "$VERSION"
COPYRIGHT="$(ini_get common copyright)"         ; require "common.copyright"   "$COPYRIGHT"
DESCRIPTION="$(ini_get common description)"
ICON_PNG="$(ini_get common icon_png)"

MIN_OS="$(ini_get_or_common macos min_os_version)"
CATEGORY="$(ini_get macos category)"
SIGN_ID="$(ini_get macos codesign_identity)"
NOTARY_USER="$(ini_get macos notarize_apple_id)"
NOTARY_PASS="$(ini_get macos notarize_password)"
NOTARY_TEAM="$(ini_get macos notarize_team_id)"
DOC_EXTS="$(ini_get macos document_extensions)"
DMG_FORMAT="$(ini_get macos dmg_format)"
[[ -z "$DMG_FORMAT" ]] && DMG_FORMAT="UDZO"

# Stage toggles.
: "${STAGE_BUILD:=1}"
: "${STAGE_BUNDLE:=1}"
: "${STAGE_SIGN:=1}"
: "${STAGE_DMG:=1}"

# Derived paths.
DIST_DIR="$REPO_ROOT/dist/macos"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RES_DIR="$CONTENTS/Resources"
FRAMEWORKS_DIR="$CONTENTS/Frameworks"
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"
ICON_BUILD_DIR="$DIST_DIR/.iconset"
ICNS_PATH="$RES_DIR/$APP_NAME.icns"

echo "━━━ Bragi macOS package ━━━"
echo "  name        : $APP_NAME"
echo "  binary      : $BIN_NAME"
echo "  identifier  : $IDENTIFIER"
echo "  version     : $VERSION"
echo "  min macOS   : $MIN_OS"
echo "  output      : $APP_DIR"
echo

# ──────────────────────────────────────────────────────────────────
# 1. Build the release binary.
# ──────────────────────────────────────────────────────────────────
ODIN_OUT="$REPO_ROOT/$BIN_NAME"
if (( STAGE_BUILD )); then
	echo "→ building $BIN_NAME (release)"
	(
		cd "$REPO_ROOT"
		odin build . -o:speed -out:"$BIN_NAME"
	)
fi
[[ -x "$ODIN_OUT" ]] || { echo "error: expected built binary at $ODIN_OUT"; exit 1; }

# ──────────────────────────────────────────────────────────────────
# 2. Lay out the bundle skeleton + bundle the binary.
# ──────────────────────────────────────────────────────────────────
if (( STAGE_BUNDLE )); then
	echo "→ assembling $APP_DIR"
	rm -rf "$APP_DIR"
	mkdir -p "$MACOS_DIR" "$RES_DIR" "$FRAMEWORKS_DIR"

	cp "$ODIN_OUT" "$MACOS_DIR/$BIN_NAME"
	chmod +x "$MACOS_DIR/$BIN_NAME"

	# 4-byte PkgInfo file marks this as a regular .app to legacy Finder.
	# (Modern macOS will work without it; bundling is conventional.)
	printf 'APPL????' > "$CONTENTS/PkgInfo"

	# ──────────────────────────────────────────────────────────
	# 3. Generate the .icns icon from the source PNG.
	# ──────────────────────────────────────────────────────────
	if [[ -n "$ICON_PNG" && -f "$REPO_ROOT/$ICON_PNG" ]]; then
		echo "→ generating $APP_NAME.icns from $ICON_PNG"
		rm -rf "$ICON_BUILD_DIR"
		mkdir -p "$ICON_BUILD_DIR"
		# Standard iconset sizes — iconutil expects this exact naming.
		for size in 16 32 64 128 256 512; do
			sips -z "$size" "$size" "$REPO_ROOT/$ICON_PNG" \
				--out "$ICON_BUILD_DIR/icon_${size}x${size}.png" >/dev/null
			retina=$((size * 2))
			sips -z "$retina" "$retina" "$REPO_ROOT/$ICON_PNG" \
				--out "$ICON_BUILD_DIR/icon_${size}x${size}@2x.png" >/dev/null
		done
		# 1024 single (no @2x — iconutil derives 512@2x from this set).
		mv "$ICON_BUILD_DIR/icon_512x512@2x.png" "$ICON_BUILD_DIR/icon_512x512@2x.png"
		# Build the .icns. iconutil insists on the .iconset extension on disk.
		mv "$ICON_BUILD_DIR" "$DIST_DIR/icon.iconset"
		iconutil --convert icns --output "$ICNS_PATH" "$DIST_DIR/icon.iconset"
		rm -rf "$DIST_DIR/icon.iconset"
	else
		echo "  (no icon — skipping .icns generation)"
	fi

	# ──────────────────────────────────────────────────────────
	# 4. Write Info.plist.
	# ──────────────────────────────────────────────────────────
	echo "→ writing Info.plist"

	# Build the document-types XML fragment from `document_extensions`.
	doc_types_xml=""
	if [[ -n "$DOC_EXTS" ]]; then
		ext_items=""
		IFS=',' read -ra exts <<<"$DOC_EXTS"
		for e in "${exts[@]}"; do
			e="$(echo "$e" | xargs)" # trim
			[[ -z "$e" ]] && continue
			ext_items+="				<string>$e</string>
"
		done
		doc_types_xml="	<key>CFBundleDocumentTypes</key>
	<array>
		<dict>
			<key>CFBundleTypeName</key>
			<string>$APP_NAME Document</string>
			<key>CFBundleTypeRole</key>
			<string>Editor</string>
			<key>LSHandlerRank</key>
			<string>Alternate</string>
			<key>CFBundleTypeExtensions</key>
			<array>
$ext_items			</array>
		</dict>
	</array>"
	fi

	icon_key=""
	if [[ -f "$ICNS_PATH" ]]; then
		icon_key="	<key>CFBundleIconFile</key>
	<string>$APP_NAME.icns</string>"
	fi

	category_key=""
	if [[ -n "$CATEGORY" ]]; then
		category_key="	<key>LSApplicationCategoryType</key>
	<string>$CATEGORY</string>"
	fi

	cat > "$CONTENTS/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundleDisplayName</key>
	<string>$APP_NAME</string>
	<key>CFBundleExecutable</key>
	<string>$BIN_NAME</string>
	<key>CFBundleIdentifier</key>
	<string>$IDENTIFIER</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleSignature</key>
	<string>????</string>
	<key>CFBundleGetInfoString</key>
	<string>$DESCRIPTION</string>
	<key>NSHumanReadableCopyright</key>
	<string>$COPYRIGHT</string>
	<key>LSMinimumSystemVersion</key>
	<string>$MIN_OS</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSSupportsAutomaticGraphicsSwitching</key>
	<true/>
$icon_key
$category_key
$doc_types_xml
</dict>
</plist>
EOF
	# Validate the plist — catches typos / missing closing tags before
	# the bundle reaches Finder.
	plutil -lint "$CONTENTS/Info.plist" >/dev/null

	# ──────────────────────────────────────────────────────────
	# 5. Bundle Homebrew dylibs into Frameworks/ and rewrite paths.
	#    This makes the .app self-contained — no `brew install`
	#    required on the target machine.
	# ──────────────────────────────────────────────────────────
	echo "→ bundling dylibs"
	bundle_dylib() {
		local src="$1"
		local fname
		fname="$(basename "$src")"
		local dst="$FRAMEWORKS_DIR/$fname"
		[[ -f "$dst" ]] && return 0      # already copied
		cp "$src" "$dst"
		chmod +w "$dst"
		# Rewrite the dylib's own ID so consumers find it via @rpath.
		install_name_tool -id "@rpath/$fname" "$dst" 2>/dev/null || true
		# Recursively bundle this dylib's own non-system deps. `local`
		# on `dep` is critical — without it the inner read clobbers the
		# outer loop's `dep` since bash variables default to global.
		local dep
		while IFS= read -r dep; do
			[[ "$dep" == /opt/homebrew/* || "$dep" == /usr/local/* ]] || continue
			bundle_dylib "$dep"
			install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$dst" 2>/dev/null || true
		done < <(otool -L "$dst" | tail -n +2 | awk '{print $1}')
	}

	# Walk the binary's direct dependencies. Anything from /opt/homebrew
	# or /usr/local gets copied + path-rewritten; system libs in /usr/lib
	# and /System/Library are left alone (those ship with macOS).
	while IFS= read -r dep; do
		[[ "$dep" == /opt/homebrew/* || "$dep" == /usr/local/* ]] || continue
		bundle_dylib "$dep"
		install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$MACOS_DIR/$BIN_NAME"
	done < <(otool -L "$MACOS_DIR/$BIN_NAME" | tail -n +2 | awk '{print $1}')

	# Tell the binary where to find its bundled dylibs at runtime.
	install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/$BIN_NAME" 2>/dev/null || true
fi

# ──────────────────────────────────────────────────────────────────
# 6. Code-sign. Without a real Developer ID we ad-hoc sign — Apple
# Silicon Macs require *some* signature for the binary to launch.
# ──────────────────────────────────────────────────────────────────
if (( STAGE_SIGN )); then
	if [[ -n "$SIGN_ID" ]]; then
		echo "→ codesigning with: $SIGN_ID"
		# Sign every dylib + the binary, then re-sign the bundle as a whole.
		# `--options runtime` enables the hardened runtime, required for
		# notarization. `--timestamp` embeds a secure timestamp.
		find "$FRAMEWORKS_DIR" -type f \( -name '*.dylib' -o -name '*.so' \) -print0 \
			| xargs -0 -I{} codesign --force --options runtime --timestamp --sign "$SIGN_ID" "{}"
		codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$MACOS_DIR/$BIN_NAME"
		codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP_DIR"
		codesign --verify --deep --strict --verbose=2 "$APP_DIR"
	else
		echo "→ ad-hoc signing (no codesign_identity in deploy.ini)"
		codesign --force --deep --sign - "$APP_DIR"
	fi

	# Notarization — only meaningful when we have a real signing
	# identity AND credentials. Posts the bundle to Apple, waits for
	# the verdict, then staples the ticket onto the .app so Gatekeeper
	# can verify offline.
	if [[ -n "$SIGN_ID" && -n "$NOTARY_USER" && -n "$NOTARY_PASS" && -n "$NOTARY_TEAM" ]]; then
		echo "→ notarizing (this can take a few minutes)"
		zip_path="$DIST_DIR/$APP_NAME-notarize.zip"
		(cd "$DIST_DIR" && /usr/bin/ditto -c -k --keepParent "$APP_NAME.app" "$zip_path")
		xcrun notarytool submit "$zip_path" \
			--apple-id "$NOTARY_USER" \
			--password "$NOTARY_PASS" \
			--team-id  "$NOTARY_TEAM" \
			--wait
		xcrun stapler staple "$APP_DIR"
		rm -f "$zip_path"
	fi
fi

# ──────────────────────────────────────────────────────────────────
# 7. Build the .dmg.
# ──────────────────────────────────────────────────────────────────
if (( STAGE_DMG )); then
	echo "→ building $DMG_PATH"
	rm -f "$DMG_PATH"
	# `hdiutil create -srcfolder` with a single .app produces a tidy
	# disk image. For drag-to-Applications layouts you'd use
	# create-dmg or a custom AppleScript; v1 is just the .app on a
	# bare volume.
	hdiutil create \
		-volname "$APP_NAME" \
		-srcfolder "$APP_DIR" \
		-ov \
		-format "$DMG_FORMAT" \
		"$DMG_PATH" >/dev/null

	if [[ -n "$SIGN_ID" ]]; then
		codesign --force --sign "$SIGN_ID" --timestamp "$DMG_PATH"
		# Stapling the .dmg lets Gatekeeper verify offline at mount time.
		[[ -n "$NOTARY_USER" ]] && xcrun stapler staple "$DMG_PATH" || true
	fi
fi

echo
echo "✓ done"
echo "    bundle : $APP_DIR"
[[ -f "$DMG_PATH" ]] && echo "    dmg    : $DMG_PATH"
