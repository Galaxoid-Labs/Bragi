#!/usr/bin/env bash
#
# package_linux.sh — build .deb and .rpm packages for Bragi.
#
# Reads deploy.ini at the repo root for metadata. Run on a Linux host
# (or in a Linux container — see the comment block at the bottom for
# a Docker recipe that works from macOS).
#
# Outputs:
#   dist/linux/bragi_<version>_<arch>.deb
#   dist/linux/bragi-<version>-1.<rpmarch>.rpm
#
# Both packages declare runtime dependencies on the distro's SDL3 /
# SDL3_ttf / libvterm packages (configurable in deploy.ini's [linux]
# section). On install, `apt` / `dnf` resolve those; on missing-dep
# systems the user gets a clear "needs libsdl3-0" message rather than
# a runtime crash. We intentionally don't bundle .so files —
# bundling on Linux is fragile across glibc / Wayland / X11 versions
# and is frowned on by both packaging policies.
#
# Stage toggles:
#   STAGE_BUILD=0    skip the `odin build` step
#   STAGE_DEB=0      skip building the .deb
#   STAGE_RPM=0      skip building the .rpm
#
# Each format auto-skips if the matching tool (`dpkg-deb` or
# `rpmbuild`) isn't on PATH, so a Debian-only host can still produce
# a .deb without rpmbuild installed (and vice versa).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

DEPLOY_INI="$REPO_ROOT/deploy.ini"
[[ -f "$DEPLOY_INI" ]] || { echo "error: deploy.ini not found at $DEPLOY_INI"; exit 1; }

# ──────────────────────────────────────────────────────────────────
# Same INI reader as the macOS script. Could be factored into a
# tools/_ini.sh helper, but it's short enough that two copies is
# cleaner than the indirection.
# ──────────────────────────────────────────────────────────────────
ini_get() {
	local section="$1" key="$2"
	awk -v want="$section" -v key="$key" '
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
	[[ -z "$v" ]] && v="$(ini_get "common" "$2")"
	echo "$v"
}

require() {
	[[ -n "$2" ]] || { echo "error: deploy.ini is missing required key: $1"; exit 1; }
}

# ──────────────────────────────────────────────────────────────────
# Pull metadata.
# ──────────────────────────────────────────────────────────────────
APP_NAME="$(ini_get common name)"        ; require "common.name"        "$APP_NAME"
BIN_NAME="$(ini_get common binary_name)" ; require "common.binary_name" "$BIN_NAME"
VERSION="$(ini_get common version)"      ; require "common.version"     "$VERSION"
AUTHOR="$(ini_get common author)"        ; require "common.author"      "$AUTHOR"
COPYRIGHT="$(ini_get common copyright)"  ; require "common.copyright"   "$COPYRIGHT"
DESCRIPTION="$(ini_get common description)"
URL="$(ini_get common url)"
LICENSE_ID="$(ini_get common license)"
ICON_PNG="$(ini_get common icon_png)"

CATEGORIES="$(ini_get linux categories)"
MIME_TYPES="$(ini_get linux mime_types)"
KEYWORDS="$(ini_get linux keywords)"
MAINTAINER_EMAIL="$(ini_get linux maintainer_email)"
DEB_DEPENDS="$(ini_get linux deb_depends)"
RPM_REQUIRES="$(ini_get linux rpm_requires)"

# Sensible fallbacks.
[[ -z "$MAINTAINER_EMAIL" ]] && MAINTAINER_EMAIL="noreply@example.com"
[[ -z "$CATEGORIES"       ]] && CATEGORIES="Development;TextEditor;"

# Stage toggles.
: "${STAGE_BUILD:=1}"
: "${STAGE_DEB:=1}"
: "${STAGE_RPM:=1}"

# Tool detection.
HAS_DEB=1; command -v dpkg-deb >/dev/null 2>&1 || HAS_DEB=0
HAS_RPM=1; command -v rpmbuild >/dev/null 2>&1 || HAS_RPM=0
HAS_CONVERT=1; command -v convert >/dev/null 2>&1 || HAS_CONVERT=0

# Refuse to run on macOS — this script needs the actual Linux build of
# the binary plus dpkg-deb/rpmbuild. If you only have a Mac, run this
# inside a Linux container (see the bottom of the file).
if [[ "$(uname -s)" != "Linux" ]]; then
	echo "error: package_linux.sh must run on Linux"
	echo "       (use the Docker recipe in this script's footer if you're on macOS)"
	exit 1
fi

# Architecture strings.
DEB_ARCH="$(dpkg --print-architecture 2>/dev/null || echo amd64)"   # amd64, arm64
RPM_ARCH="$(uname -m)"                                              # x86_64, aarch64

# Derived paths.
DIST_DIR="$REPO_ROOT/dist/linux"
STAGING="$DIST_DIR/staging"

echo "━━━ Bragi Linux packages ━━━"
echo "  name        : $APP_NAME"
echo "  binary      : $BIN_NAME"
echo "  version     : $VERSION"
echo "  deb arch    : $DEB_ARCH    ($([[ $HAS_DEB == 1 ]] && echo enabled || echo 'skipped — dpkg-deb missing'))"
echo "  rpm arch    : $RPM_ARCH    ($([[ $HAS_RPM == 1 ]] && echo enabled || echo 'skipped — rpmbuild missing'))"
echo "  output      : $DIST_DIR"
echo

(( HAS_DEB || HAS_RPM )) || { echo "error: neither dpkg-deb nor rpmbuild found"; exit 1; }

# ──────────────────────────────────────────────────────────────────
# 1. Build the release binary.
# ──────────────────────────────────────────────────────────────────
ODIN_OUT="$REPO_ROOT/$BIN_NAME"
if (( STAGE_BUILD )); then
	echo "→ building $BIN_NAME (release)"
	(cd "$REPO_ROOT" && odin build . -o:speed -out:"$BIN_NAME")
fi
[[ -x "$ODIN_OUT" ]] || { echo "error: expected built binary at $ODIN_OUT"; exit 1; }

# ──────────────────────────────────────────────────────────────────
# 2. Stage the FHS-shaped install tree both packages share. Anything
# the .deb / .rpm would deposit lands here exactly once; the format-
# specific build steps just take this directory as their source.
# ──────────────────────────────────────────────────────────────────
echo "→ staging filesystem tree"
rm -rf "$STAGING"
mkdir -p "$STAGING/usr/bin"
mkdir -p "$STAGING/usr/share/applications"
mkdir -p "$STAGING/usr/share/doc/$BIN_NAME"
mkdir -p "$STAGING/usr/share/pixmaps"

# The binary lives directly in /usr/bin. Linux convention; /opt or
# /usr/lib/<app> is for shipping multi-file blobs that we don't have.
cp "$ODIN_OUT" "$STAGING/usr/bin/$BIN_NAME"
chmod 0755 "$STAGING/usr/bin/$BIN_NAME"
strip "$STAGING/usr/bin/$BIN_NAME" 2>/dev/null || true

# Icon. Generate every hicolor size if ImageMagick is available;
# otherwise just install the source PNG to pixmaps as a fallback
# (legacy, but the freedesktop spec still honors it).
if [[ -n "$ICON_PNG" && -f "$REPO_ROOT/$ICON_PNG" ]]; then
	echo "→ generating icons"
	if (( HAS_CONVERT )); then
		for size in 16 32 48 64 128 256 512; do
			dir="$STAGING/usr/share/icons/hicolor/${size}x${size}/apps"
			mkdir -p "$dir"
			convert "$REPO_ROOT/$ICON_PNG" -resize "${size}x${size}" "$dir/$BIN_NAME.png"
		done
	else
		# Without ImageMagick we still drop ONE hicolor entry (the
		# source unmodified at the 256x256 slot) — desktop environments
		# scale on the fly, and the .rpm %files glob always needs at
		# least one match for the hicolor path.
		echo "  (ImageMagick 'convert' missing — installing source PNG at 256x256)"
		dir="$STAGING/usr/share/icons/hicolor/256x256/apps"
		mkdir -p "$dir"
		cp "$REPO_ROOT/$ICON_PNG" "$dir/$BIN_NAME.png"
	fi
	# Always drop the source into /usr/share/pixmaps as the final
	# fallback for desktop environments that don't read hicolor.
	cp "$REPO_ROOT/$ICON_PNG" "$STAGING/usr/share/pixmaps/$BIN_NAME.png"
fi

# .desktop file. `Exec=$BIN_NAME %F` lets DEs pass selected files in
# Nautilus/Files via "Open with Bragi". `MimeType=` empty is fine —
# we only fill it when the user opted in via deploy.ini.
echo "→ writing $BIN_NAME.desktop"
{
	echo "[Desktop Entry]"
	echo "Type=Application"
	echo "Name=$APP_NAME"
	echo "GenericName=Text Editor"
	echo "Comment=$DESCRIPTION"
	echo "Exec=$BIN_NAME %F"
	echo "Icon=$BIN_NAME"
	echo "Terminal=false"
	echo "Categories=$CATEGORIES"
	[[ -n "$KEYWORDS"   ]] && echo "Keywords=$KEYWORDS"
	[[ -n "$MIME_TYPES" ]] && echo "MimeType=$MIME_TYPES"
	echo "StartupWMClass=$BIN_NAME"
	echo "StartupNotify=true"
} > "$STAGING/usr/share/applications/$BIN_NAME.desktop"
chmod 0644 "$STAGING/usr/share/applications/$BIN_NAME.desktop"

# Copyright file (Debian convention — also picked up by RPM).
{
	echo "Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/"
	echo "Upstream-Name: $APP_NAME"
	[[ -n "$URL" ]] && echo "Source: $URL"
	echo
	echo "Files: *"
	echo "Copyright: $COPYRIGHT"
	echo "License: $LICENSE_ID"
	echo
	if [[ -f "$REPO_ROOT/LICENSE" ]]; then
		# Indent each line per debian copyright format.
		sed 's/^/ /; s/^ $/ ./' "$REPO_ROOT/LICENSE"
	fi
} > "$STAGING/usr/share/doc/$BIN_NAME/copyright"
chmod 0644 "$STAGING/usr/share/doc/$BIN_NAME/copyright"

# ──────────────────────────────────────────────────────────────────
# 3. Build the .deb.
# ──────────────────────────────────────────────────────────────────
if (( STAGE_DEB && HAS_DEB )); then
	echo "→ building .deb"
	DEB_BUILD="$DIST_DIR/deb-build"
	rm -rf "$DEB_BUILD"
	cp -a "$STAGING" "$DEB_BUILD"

	# Compute installed-size from the staged tree (KiB, per Debian policy).
	installed_size=$(du -sk "$DEB_BUILD" | awk '{print $1}')

	mkdir -p "$DEB_BUILD/DEBIAN"
	{
		echo "Package: $BIN_NAME"
		echo "Version: $VERSION"
		echo "Section: editors"
		echo "Priority: optional"
		echo "Architecture: $DEB_ARCH"
		echo "Maintainer: $AUTHOR <$MAINTAINER_EMAIL>"
		echo "Installed-Size: $installed_size"
		[[ -n "$DEB_DEPENDS" ]] && echo "Depends: $DEB_DEPENDS"
		[[ -n "$URL"         ]] && echo "Homepage: $URL"
		echo "Description: $DESCRIPTION"
		echo " $APP_NAME is a small GPU-accelerated, vim-flavoured text/code"
		echo " editor. Modal editing, side-by-side panes, embedded terminal,"
		echo " native file dialogs, hand-rolled syntax highlighting."
	} > "$DEB_BUILD/DEBIAN/control"

	deb_path="$DIST_DIR/${BIN_NAME}_${VERSION}_${DEB_ARCH}.deb"
	dpkg-deb --root-owner-group --build "$DEB_BUILD" "$deb_path" >/dev/null
	rm -rf "$DEB_BUILD"
	echo "  → $deb_path"
fi

# ──────────────────────────────────────────────────────────────────
# 4. Build the .rpm. We stage a tarball into rpmbuild's SOURCES, write
# a minimal .spec, and let rpmbuild do the rest. The -bb flag means
# "binary RPM only" — no source RPM (not useful for us; the source is
# the upstream Bragi repo).
# ──────────────────────────────────────────────────────────────────
if (( STAGE_RPM && HAS_RPM )); then
	echo "→ building .rpm"
	RPM_TOPDIR="$DIST_DIR/rpm-build"
	rm -rf "$RPM_TOPDIR"
	mkdir -p "$RPM_TOPDIR"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}

	# Tar up the staged tree; rpmbuild's %setup -c will extract it
	# into BUILD/<name>-<version>/ which we then copy into BUILDROOT
	# during %install.
	tar_name="${BIN_NAME}-${VERSION}.tar.gz"
	tar -C "$STAGING" -czf "$RPM_TOPDIR/SOURCES/$tar_name" .

	spec="$RPM_TOPDIR/SPECS/$BIN_NAME.spec"
	# Translate the comma-separated rpm_requires into newline-separated
	# Requires: lines for the spec.
	requires_lines=""
	if [[ -n "$RPM_REQUIRES" ]]; then
		IFS=',' read -ra reqs <<<"$RPM_REQUIRES"
		for r in "${reqs[@]}"; do
			r="$(echo "$r" | xargs)"
			[[ -z "$r" ]] && continue
			requires_lines+="Requires:       $r"$'\n'
		done
	fi

	{
		echo "Name:           $BIN_NAME"
		echo "Version:        $VERSION"
		echo "Release:        1%{?dist}"
		echo "Summary:        $DESCRIPTION"
		echo "License:        $LICENSE_ID"
		[[ -n "$URL" ]] && echo "URL:            $URL"
		echo "Source0:        $tar_name"
		echo "BuildArch:      $RPM_ARCH"
		echo
		[[ -n "$requires_lines" ]] && printf '%s' "$requires_lines"
		echo
		echo "%description"
		echo "$DESCRIPTION"
		echo
		# We're shipping a prebuilt binary, so the standard %prep ->
		# %build -> %install dance is a no-op apart from copying our
		# staged tree into BUILDROOT. The %setup arguments tell
		# rpmbuild "extract the tarball into a fresh dir of this name."
		echo "%prep"
		echo "%setup -c -q -n $BIN_NAME-$VERSION"
		echo
		echo "%build"
		echo "# nothing to build — Source0 is a staged install tree"
		echo
		echo "%install"
		echo "rm -rf %{buildroot}"
		echo "cp -a usr %{buildroot}/usr"
		echo
		echo "%files"
		echo "%license /usr/share/doc/$BIN_NAME/copyright"
		echo "/usr/bin/$BIN_NAME"
		echo "/usr/share/applications/$BIN_NAME.desktop"
		echo "/usr/share/pixmaps/$BIN_NAME.png"
		echo "/usr/share/icons/hicolor/*/apps/$BIN_NAME.png"
		echo "/usr/share/doc/$BIN_NAME/"
		echo
		echo "%changelog"
		echo "* $(date '+%a %b %d %Y') $AUTHOR <$MAINTAINER_EMAIL> - $VERSION-1"
		echo "- Release $VERSION"
	} > "$spec"

	rpmbuild --define "_topdir $RPM_TOPDIR" -bb "$spec" >/dev/null

	# rpmbuild deposits in RPMS/<arch>/. Move the result up into dist/linux.
	rpm_built=$(find "$RPM_TOPDIR/RPMS" -name "${BIN_NAME}-${VERSION}-1*.rpm" -print -quit)
	if [[ -n "$rpm_built" ]]; then
		mv "$rpm_built" "$DIST_DIR/"
		echo "  → $DIST_DIR/$(basename "$rpm_built")"
	else
		echo "  warning: rpmbuild ran but no .rpm was found in $RPM_TOPDIR/RPMS"
	fi
	rm -rf "$RPM_TOPDIR"
fi

# Clean up the shared staging dir.
rm -rf "$STAGING"

echo
echo "✓ done"
ls -lh "$DIST_DIR"/*.deb "$DIST_DIR"/*.rpm 2>/dev/null || true

# ──────────────────────────────────────────────────────────────────
# Build-host setup recipes
# ──────────────────────────────────────────────────────────────────
#
# This script needs to run on Linux. Pick the row matching your host:
#
# ── Fedora (40+) — produces .rpm out of the box. Install dpkg-dev
#    too if you also want .deb from the same box.
#
#   sudo dnf install -y \
#     gcc clang git curl unzip ImageMagick \
#     SDL3-devel SDL3_ttf-devel libvterm-devel \
#     rpm-build dpkg                              # last one for the .deb
#
#   # Odin: grab the latest dev release.
#   curl -L https://github.com/odin-lang/Odin/releases/latest/download/odin-linux-amd64.zip \
#     -o /tmp/odin.zip
#   sudo unzip -o /tmp/odin.zip -d /opt/odin
#   sudo ln -sf /opt/odin/odin /usr/local/bin/odin
#
#   ./tools/package_linux.sh
#
# ── Debian / Ubuntu — produces .deb out of the box. Install rpm too
#    if you also want .rpm.
#
#   sudo apt-get install -y \
#     build-essential clang git curl unzip imagemagick \
#     libsdl3-dev libsdl3-ttf-dev libvterm-dev \
#     dpkg-dev rpm                               # last one for the .rpm
#
#   curl -L https://github.com/odin-lang/Odin/releases/latest/download/odin-linux-amd64.zip \
#     -o /tmp/odin.zip
#   sudo unzip -o /tmp/odin.zip -d /opt/odin
#   sudo ln -sf /opt/odin/odin /usr/local/bin/odin
#
#   ./tools/package_linux.sh
#
# ── macOS via Docker — drop into a Debian container with both tools.
#
#   docker run --rm -it -v "$(pwd):/src" -w /src debian:bookworm bash -c '
#     apt-get update && apt-get install -y \
#       build-essential clang git curl unzip \
#       libsdl3-dev libsdl3-ttf-dev libvterm-dev \
#       dpkg-dev rpm imagemagick &&
#     curl -L https://github.com/odin-lang/Odin/releases/latest/download/odin-linux-amd64.zip \
#       -o /tmp/odin.zip &&
#     unzip /tmp/odin.zip -d /opt/odin && export PATH=/opt/odin:$PATH &&
#     ./tools/package_linux.sh
#   '
