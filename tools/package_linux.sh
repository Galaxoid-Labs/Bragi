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
IDENTIFIER="$(ini_get common identifier)"
VERSION="$(ini_get common version)"      ; require "common.version"     "$VERSION"
AUTHOR="$(ini_get common author)"        ; require "common.author"      "$AUTHOR"
COPYRIGHT="$(ini_get common copyright)"  ; require "common.copyright"   "$COPYRIGHT"
DESCRIPTION="$(ini_get common description)"
URL="$(ini_get common url)"
LICENSE_ID="$(ini_get common license)"
ICON_PNG="$(ini_get common icon_png)"

# Tiny XML-escaper for fields we splice into the AppStream metainfo.
# Only the five canonical entities; nothing in deploy.ini needs more.
xml_escape() {
	local s="$1"
	s="${s//&/&amp;}"
	s="${s//</&lt;}"
	s="${s//>/&gt;}"
	s="${s//\"/&quot;}"
	s="${s//\'/&apos;}"
	printf '%s' "$s"
}

CATEGORIES="$(ini_get linux categories)"
MIME_TYPES="$(ini_get linux mime_types)"
KEYWORDS="$(ini_get linux keywords)"
MAINTAINER_EMAIL="$(ini_get linux maintainer_email)"
DEB_DEPENDS="$(ini_get linux deb_depends)"
RPM_REQUIRES="$(ini_get linux rpm_requires)"
PACMAN_DEPENDS="$(ini_get linux pacman_depends)"

# Sensible fallbacks.
[[ -z "$MAINTAINER_EMAIL" ]] && MAINTAINER_EMAIL="noreply@example.com"
[[ -z "$CATEGORIES"       ]] && CATEGORIES="Development;TextEditor;"

# Stage toggles.
: "${STAGE_BUILD:=1}"
: "${STAGE_DEB:=1}"
: "${STAGE_RPM:=1}"
: "${STAGE_ARCH:=1}"

# Tool detection.
HAS_DEB=1;     command -v dpkg-deb >/dev/null 2>&1 || HAS_DEB=0
HAS_RPM=1;     command -v rpmbuild >/dev/null 2>&1 || HAS_RPM=0
HAS_MAKEPKG=1; command -v makepkg  >/dev/null 2>&1 || HAS_MAKEPKG=0
HAS_CONVERT=0
if command -v magick >/dev/null 2>&1; then
	HAS_CONVERT=1; CONVERT_CMD="magick"
elif command -v convert >/dev/null 2>&1; then
	HAS_CONVERT=1; CONVERT_CMD="convert"
fi

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
echo "  arch pkg    : $RPM_ARCH    ($([[ $HAS_MAKEPKG == 1 ]] && echo enabled || echo 'skipped — makepkg missing'))"
echo "  output      : $DIST_DIR"
echo

(( HAS_DEB || HAS_RPM || HAS_MAKEPKG )) || { echo "error: none of dpkg-deb / rpmbuild / makepkg found"; exit 1; }

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
mkdir -p "$STAGING/usr/share/metainfo"
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
			"$CONVERT_CMD" "$REPO_ROOT/$ICON_PNG" -resize "${size}x${size}" "$dir/$BIN_NAME.png"
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

# AppStream metainfo. Without this, GNOME Software / KDE Discover /
# Plasma Discover do NOT show the package in their "Installed" list,
# even though apt/dnf/pacman know about it. The .desktop file alone
# is enough for the OS to put us in the menu, but the GUI app stores
# index by AppStream component id (reverse-DNS), not by package name.
#
# Spec: https://www.freedesktop.org/software/appstream/docs/
# Validate locally with: appstreamcli validate <file>
if [[ -n "$IDENTIFIER" ]]; then
	echo "→ writing $IDENTIFIER.metainfo.xml"
	metainfo_path="$STAGING/usr/share/metainfo/$IDENTIFIER.metainfo.xml"
	xe_name="$(xml_escape "$APP_NAME")"
	xe_desc="$(xml_escape "$DESCRIPTION")"
	xe_url="$(xml_escape "$URL")"
	xe_author="$(xml_escape "$AUTHOR")"
	xe_license="$(xml_escape "$LICENSE_ID")"
	xe_email="$(xml_escape "$MAINTAINER_EMAIL")"
	xe_version="$(xml_escape "$VERSION")"
	# Stable developer id derived from the reverse-DNS identifier
	# (everything except the trailing app component). E.g.
	# `com.galaxoidlabs.bragi` → `com.galaxoidlabs`. Falls back to the
	# full identifier if it has no dots.
	dev_id="${IDENTIFIER%.*}"
	[[ "$dev_id" == "$IDENTIFIER" ]] && dev_id="$IDENTIFIER"
	xe_dev_id="$(xml_escape "$dev_id")"
	{
		echo '<?xml version="1.0" encoding="UTF-8"?>'
		echo "<component type=\"desktop-application\">"
		echo "  <id>$IDENTIFIER</id>"
		echo "  <name>$xe_name</name>"
		echo "  <summary>$xe_desc</summary>"
		# metadata_license = the license of THIS XML file (CC0 is the
		# AppStream-recommended default). project_license = SPDX of the
		# actual project, from deploy.ini.
		echo "  <metadata_license>CC0-1.0</metadata_license>"
		echo "  <project_license>$xe_license</project_license>"
		echo "  <launchable type=\"desktop-id\">$BIN_NAME.desktop</launchable>"
		[[ -n "$URL" ]] && echo "  <url type=\"homepage\">$xe_url</url>"
		echo "  <developer id=\"$xe_dev_id\">"
		echo "    <name>$xe_author</name>"
		echo "  </developer>"
		echo "  <description>"
		echo "    <p>$xe_desc</p>"
		echo "  </description>"
		# OARS content rating — required by appstream-glib's strict
		# validator and by GNOME Software for the "appropriate audience"
		# UI. Empty rating tag = no concerning content.
		echo "  <content_rating type=\"oars-1.1\"/>"
		echo "  <releases>"
		echo "    <release version=\"$xe_version\" date=\"$(date '+%Y-%m-%d')\"/>"
		echo "  </releases>"
		[[ -n "$MAINTAINER_EMAIL" && "$MAINTAINER_EMAIL" != "noreply@example.com" ]] && \
			echo "  <update_contact>$xe_email</update_contact>"
		echo "</component>"
	} > "$metainfo_path"
	chmod 0644 "$metainfo_path"
fi

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

# Third-party license notices. Required by every bundled / linked dep
# (libvterm MIT, SDL3 / SDL3_ttf zlib, Fira Code OFL, Nerd Font OFL,
# Odin zlib-style). Drop them alongside the Debian-style copyright.
if [[ -d "$REPO_ROOT/licenses" ]]; then
	mkdir -p "$STAGING/usr/share/doc/$BIN_NAME/licenses"
	cp "$REPO_ROOT"/licenses/*.txt "$STAGING/usr/share/doc/$BIN_NAME/licenses/"
fi
if [[ -f "$REPO_ROOT/THIRD_PARTY_LICENSES.md" ]]; then
	cp "$REPO_ROOT/THIRD_PARTY_LICENSES.md" "$STAGING/usr/share/doc/$BIN_NAME/THIRD_PARTY_LICENSES.md"
fi

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
		# We ship a stripped, prebuilt binary — no debug info to harvest.
		# Without this, Fedora's rpmbuild auto-generates an empty
		# -debugsource subpackage and dies on "Empty %files file ...
		# debugsourcefiles.list".
		echo "%global debug_package %{nil}"
		echo
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
		echo "mkdir -p %{buildroot}"
		echo "cp -a usr %{buildroot}/"
		echo
		echo "%files"
		# Claim the whole doc dir so it sweeps up `copyright`,
		# `THIRD_PARTY_LICENSES.md`, and `licenses/*.txt` in one entry.
		# rpmbuild errors out on "Installed (but unpackaged) file(s)"
		# if any subpath isn't declared here.
		echo "%license /usr/share/doc/$BIN_NAME/copyright"
		echo "/usr/share/doc/$BIN_NAME/"
		echo "/usr/bin/$BIN_NAME"
		echo "/usr/share/applications/$BIN_NAME.desktop"
		[[ -n "$IDENTIFIER" ]] && echo "/usr/share/metainfo/$IDENTIFIER.metainfo.xml"
		echo "/usr/share/pixmaps/$BIN_NAME.png"
		echo "/usr/share/icons/hicolor/*/apps/$BIN_NAME.png"
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

# ──────────────────────────────────────────────────────────────────
# Generic FHS tarball — same staged tree compressed as a vanilla
# .tar.gz. Used by tools/aur/bragi-bin/PKGBUILD (the user uploads this
# tarball as a GitHub release artifact and the AUR PKGBUILD downloads
# + extracts it). Also a useful fallback for any distro without
# .deb / .rpm tooling — `tar -xzf bragi-<v>-<arch>-linux.tar.gz -C /`
# installs the same files as the proper packages.
# ──────────────────────────────────────────────────────────────────
tar_name="${BIN_NAME}-${VERSION}-${RPM_ARCH}-linux.tar.gz"
tar_path="$DIST_DIR/$tar_name"
echo "→ building generic tarball"
tar -C "$STAGING" -czf "$tar_path" .
echo "  → $tar_path"

# ──────────────────────────────────────────────────────────────────
# 5. Build the .pkg.tar.zst (Arch / pacman) by writing a tiny
# PKGBUILD that points at the tarball we just produced and running
# makepkg against it. The `tools/aur/*/PKGBUILD` files are the ones
# you actually publish to the AUR — those download from a GitHub
# release. This stage is for local builds on an Arch host so a
# single `package_linux.sh` run produces every Linux artifact.
# ──────────────────────────────────────────────────────────────────
if (( STAGE_ARCH && HAS_MAKEPKG )); then
	echo "→ building .pkg.tar.zst"
	ARCH_BUILD="$DIST_DIR/arch-build"
	rm -rf "$ARCH_BUILD"
	mkdir -p "$ARCH_BUILD"

	# Stage the just-built tarball alongside the PKGBUILD so makepkg
	# treats it as a local source (no network fetch).
	cp "$tar_path" "$ARCH_BUILD/$tar_name"

	# Translate the comma-separated `pacman_depends` field into the
	# bash-array form `('a' 'b' 'c')` that PKGBUILDs expect.
	depends_array=""
	if [[ -n "$PACMAN_DEPENDS" ]]; then
		IFS=',' read -ra deps <<<"$PACMAN_DEPENDS"
		for d in "${deps[@]}"; do
			d="$(echo "$d" | xargs)"
			[[ -z "$d" ]] && continue
			depends_array+="'$d' "
		done
	fi

	# Write the PKGBUILD. `provides` + `conflicts` lets `pacman -U`
	# replace any AUR-installed bragi/-bin/-git cleanly. `--skipinteg`
	# below skips checksum verification (we set 'SKIP' here too — the
	# tarball is something we just built, not a downloaded asset).
	cat > "$ARCH_BUILD/PKGBUILD" <<PKGEOF
# Auto-generated by tools/package_linux.sh — do not edit by hand.
# Built locally from a tarball produced in the same run; not the
# canonical AUR PKGBUILD (see tools/aur/ for those).
pkgname=$BIN_NAME
pkgver=$VERSION
pkgrel=1
pkgdesc="$DESCRIPTION"
arch=('$RPM_ARCH')
url="$URL"
license=('$LICENSE_ID')
depends=($depends_array)
provides=("\$pkgname=\$pkgver")
conflicts=("\$pkgname-bin" "\$pkgname-git")
source=("$tar_name")
sha256sums=('SKIP')

package() {
	cd "\$srcdir"
	cp -a usr/. "\$pkgdir/usr"
	install -Dm644 "\$srcdir/usr/share/doc/$BIN_NAME/copyright" \\
		"\$pkgdir/usr/share/licenses/$BIN_NAME/LICENSE"
}
PKGEOF

	# `-f` overwrites any prior build; `--skipinteg` skips the
	# 'SKIP' checksum check (it's a local file we just produced);
	# `--noconfirm` keeps it non-interactive.
	(cd "$ARCH_BUILD" && makepkg -f --skipinteg --noconfirm) >/dev/null

	# Move the produced .pkg.tar.zst out of the build dir, then
	# clean up. makepkg names it <pkgname>-<pkgver>-<pkgrel>-<arch>.
	pkg_built=$(find "$ARCH_BUILD" -maxdepth 1 -name "${BIN_NAME}-${VERSION}-1*.pkg.tar.zst" -print -quit)
	if [[ -n "$pkg_built" ]]; then
		mv "$pkg_built" "$DIST_DIR/"
		echo "  → $DIST_DIR/$(basename "$pkg_built")"
	else
		echo "  warning: makepkg ran but no .pkg.tar.zst was found in $ARCH_BUILD"
	fi
	rm -rf "$ARCH_BUILD"
fi

# Clean up the shared staging dir.
rm -rf "$STAGING"

echo
echo "✓ done"
ls -lh "$DIST_DIR"/*.deb "$DIST_DIR"/*.rpm "$DIST_DIR"/*.pkg.tar.zst "$DIST_DIR"/*.tar.gz 2>/dev/null || true

# ──────────────────────────────────────────────────────────────────
# Build-host setup recipes
# ──────────────────────────────────────────────────────────────────
#
# This script needs to run on Linux. Pick the row matching your host:
#
# ── Arch / Manjaro — produces .pkg.tar.zst out of the box. Install
#    `dpkg` and `rpm-tools` too if you also want .deb / .rpm.
#    `makepkg` lives in `pacman` (already installed on every Arch box).
#
#   sudo pacman -S --needed \
#     base-devel git curl unzip imagemagick \
#     sdl3 sdl3_ttf libvterm \
#     dpkg rpm-tools             # only if you want .deb / .rpm too
#
#   curl -L https://github.com/odin-lang/Odin/releases/latest/download/odin-linux-amd64.zip \
#     -o /tmp/odin.zip
#   sudo unzip -o /tmp/odin.zip -d /opt/odin
#   sudo ln -sf /opt/odin/odin /usr/local/bin/odin
#
#   ./tools/package_linux.sh
#
# ── Fedora (40+) — produces .rpm out of the box. Install dpkg-dev
#    too if you also want .deb from the same box. `.pkg.tar.zst` is
#    not practical on Fedora — `makepkg` is hard-wired to Arch
#    conventions and isn't packaged for Fedora; build that artifact
#    in an Arch container if you need it (see Docker recipe below).
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
# ── Arch container — for producing a .pkg.tar.zst from a non-Arch
#    host (Fedora, Debian, macOS). Drop into archlinux:base-devel.
#
#   docker run --rm -it -v "$(pwd):/src" -w /src archlinux:base-devel bash -c '
#     pacman -Syu --noconfirm --needed \
#       git curl unzip imagemagick sudo \
#       sdl3 sdl3_ttf libvterm &&
#     # makepkg refuses to run as root; create a build user.
#     useradd -m builder && chown -R builder /src &&
#     curl -L https://github.com/odin-lang/Odin/releases/latest/download/odin-linux-amd64.zip \
#       -o /tmp/odin.zip &&
#     unzip /tmp/odin.zip -d /opt/odin && ln -sf /opt/odin/odin /usr/local/bin/odin &&
#     sudo -u builder ./tools/package_linux.sh
#   '
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
