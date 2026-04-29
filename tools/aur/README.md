# AUR packaging

Three PKGBUILDs covering the conventional Arch User Repository
trinity:

| Variant      | What it installs                                                  | Build deps on the user's host        |
| ------------ | ----------------------------------------------------------------- | ------------------------------------ |
| `bragi-bin`  | The prebuilt Linux tarball produced by `tools/package_linux.sh`.  | None.                                |
| `bragi`      | A tagged source release. Compiles via Odin at install time.       | `odin`, `imagemagick`.               |
| `bragi-git`  | A rolling build off `master`. Same as `bragi` but unversioned.    | `odin`, `imagemagick`, `git`.        |

All three end up at `/usr/bin/bragi` and conflict with each other — a
user installs exactly one. The most-used variant on the AUR is the
`-bin` one (zero build deps); `-git` is for hackers tracking
development.

## Per-release flow

When you tag a new release (say `v0.2.0`):

1. **Build the artifacts.** On a Linux host (or Docker; see
   `package_linux.sh` footer):

   ```sh
   ./tools/package_linux.sh
   ```

   This now produces, in `dist/linux/`:

   ```
   bragi_0.2.0_amd64.deb
   bragi-0.2.0-1.x86_64.rpm
   bragi-0.2.0-x86_64-linux.tar.gz   ← the one bragi-bin downloads
   ```

2. **Push the tag and upload the tarball as a release asset.**

   ```sh
   git tag v0.2.0
   git push --tags
   gh release create v0.2.0 \
     dist/linux/bragi-0.2.0-x86_64-linux.tar.gz \
     dist/linux/bragi_0.2.0_amd64.deb \
     dist/linux/bragi-0.2.0-1.x86_64.rpm \
     dist/macos/Bragi-0.2.0.dmg
   ```

3. **Bump every PKGBUILD's `pkgver` to `0.2.0`.** (The `-git` one
   keeps `pkgver=0.0.0` — its real version is computed by `pkgver()`
   at build time.)

   ```sh
   sed -i 's/^pkgver=.*/pkgver=0.2.0/' tools/aur/bragi/PKGBUILD
   sed -i 's/^pkgver=.*/pkgver=0.2.0/' tools/aur/bragi-bin/PKGBUILD
   ```

4. **Refresh the source hashes.** `updpkgsums` (from the `pacman-contrib`
   package on Arch) reads the PKGBUILD, downloads each `source=` URL,
   and writes the real sha256 into `sha256sums=`:

   ```sh
   cd tools/aur/bragi-bin && updpkgsums   # downloads the tarball, hashes it
   cd ../bragi             && updpkgsums  # hashes the GitHub source archive
   ```

   `bragi-git`'s `sha256sums=('SKIP')` is correct as-is — git sources
   don't get a hash.

5. **Regenerate `.SRCINFO`.** AUR's web UI parses this rather than the
   PKGBUILD; a stale one shows wrong metadata on the package page.

   ```sh
   for d in tools/aur/bragi tools/aur/bragi-bin tools/aur/bragi-git; do
     (cd "$d" && makepkg --printsrcinfo > .SRCINFO)
   done
   ```

6. **Push to each AUR repo.** Each variant lives in its own AUR git
   repo (`ssh://aur@aur.archlinux.org/<pkgname>.git`). First time
   only:

   ```sh
   git clone ssh://aur@aur.archlinux.org/bragi.git    aur-bragi
   git clone ssh://aur@aur.archlinux.org/bragi-bin.git aur-bragi-bin
   git clone ssh://aur@aur.archlinux.org/bragi-git.git aur-bragi-git
   ```

   Then for each release:

   ```sh
   cp tools/aur/bragi-bin/PKGBUILD  aur-bragi-bin/
   cp tools/aur/bragi-bin/.SRCINFO  aur-bragi-bin/
   (cd aur-bragi-bin && git add . && git commit -m "0.2.0-1" && git push)

   # ...repeat for aur-bragi/ and aur-bragi-git/
   ```

   AUR refuses commits that don't include both `PKGBUILD` and
   `.SRCINFO`, so don't skip step 5.

## Local testing without publishing

To verify a PKGBUILD before pushing it:

```sh
cd tools/aur/bragi-bin
makepkg -si --noconfirm   # builds and installs to your host
pacman -Qi bragi-bin      # confirm install metadata
bragi --version           # smoke-test
```

`makepkg -s` alone (no `i`) builds the package without installing it;
`namcap PKGBUILD` lints metadata; `namcap *.pkg.tar.zst` lints the
built artifact. Both are non-fatal but worth running before pushing.

## First-time AUR account setup

Maintainer pushes go through SSH, not HTTPS:

1. Create an account at https://aur.archlinux.org/.
2. Add your SSH public key under **My Account → SSH Public Key**.
3. `aur@aur.archlinux.org` accepts pushes only on TCP port 22; if
   you're behind a strict firewall, the AUR docs cover the
   `~/.ssh/config` workaround.
