#!/bin/sh
#  Builds scopebridge-server and scopebridge-term for a Raspberry Pi, or another
#  Debian-based arm64 or armhf computer, on this one, and packs them with
#  "make package": a tarball to copy over, unpack, and sudo ./install.sh.
#
#    contrib/cross-build.sh                      64-bit Raspberry Pi OS 11
#    contrib/cross-build.sh --arch armhf         32-bit (ARMv7: Pi 2, 3, 4)
#    contrib/cross-build.sh --suite bookworm     Raspberry Pi OS 12
#
#  How: a small root of the target's own Debian packages (GNAT, gprbuild,
#  GNATCOLL), fetched with apt and checked against Debian's archive keys,
#  in which the build runs under qemu, in a bubblewrap sandbox; no root
#  needed.  The Ada runtime and GNATCOLL are linked statically, so the
#  target needs nothing but its C library.  The build is of the committed
#  sources (git archive HEAD).
#
#  Needs a Debian or Ubuntu computer with apt, qemu-user-static (with
#  binfmt support) and bubblewrap:
#    sudo apt install qemu-user-static binfmt-support bubblewrap
#  The target's root is kept in ~/.cache/scopebridge-cross (CROSS_DIR), about
#  400 MB; the build takes a few minutes, emulated.
# Copyright (C) 2026 By Ulrik Hørlyk Hjort; MIT licence, see LICENSE.
set -e

arch=arm64
suite=bullseye
while [ $# -gt 0 ]; do
  case $1 in
    --arch) arch=$2; shift 2 ;;
    --suite) suite=$2; shift 2 ;;
    *) echo "usage: contrib/cross-build.sh [--arch arm64|armhf] [--suite bullseye|bookworm]" >&2
       exit 2 ;;
  esac
done

top=$(cd "$(dirname "$0")/.." && pwd)
cache=${CROSS_DIR:-$HOME/.cache/scopebridge-cross}/$suite-$arch
apt_dir=$cache/apt
root=$cache/root
qemu=$(case $arch in arm64) echo aarch64 ;; armhf) echo arm ;; *) echo "$arch" ;; esac)

for tool in apt-get dpkg-deb bwrap git; do
  command -v $tool > /dev/null || { echo "cross-build: $tool is needed" >&2; exit 1; }
done
[ -e /proc/sys/fs/binfmt_misc/qemu-$qemu ] ||
  { echo "cross-build: no qemu-$qemu binfmt: sudo apt install qemu-user-static binfmt-support" >&2; exit 1; }

#  -- The target's root, once ------------------------------------------------

if [ ! -x "$root/usr/bin/gprbuild" ]; then
  echo "cross-build: making a $suite $arch root in $cache"
  mkdir -p "$apt_dir/etc/apt/preferences.d" "$apt_dir/var/lib/dpkg" "$apt_dir/var/lib/apt/lists/partial" \
           "$apt_dir/var/cache/apt/archives/partial" "$apt_dir/keys"
  touch "$apt_dir/var/lib/dpkg/status"

  #  Debian's archive keys, from this computer's own (verified) apt
  (cd "$apt_dir/keys" && apt-get download debian-archive-keyring > /dev/null &&
   dpkg-deb -x debian-archive-keyring_*.deb .)
  key=$apt_dir/keys/usr/share/keyrings/debian-archive-$suite-automatic.gpg
  [ -e "$key" ] || { echo "cross-build: this computer's debian-archive-keyring has no keys for $suite" >&2; exit 1; }
  echo "deb [arch=$arch signed-by=$key] https://deb.debian.org/debian $suite main" \
    > "$apt_dir/etc/apt/sources.list"

  apt_opts="-o Dir=$apt_dir -o Dir::State::status=$apt_dir/var/lib/dpkg/status
            -o APT::Architecture=$arch -o APT::Architectures=$arch
            -o Debug::NoLocking=1 -o Dir::Etc::TrustedParts=/nonexistent"
  apt-get $apt_opts update > /dev/null
  gnatcoll=$(apt-cache $apt_opts pkgnames libgnatcoll | grep -E '^libgnatcoll[0-9]*-dev$' | sort | tail -1)
  apt-get $apt_opts install --download-only --no-install-recommends -y \
    gnat gprbuild "$gnatcoll" make bash dash coreutils sed grep findutils diffutils gawk > /dev/null

  mkdir -p "$root"
  for deb in "$apt_dir"/var/cache/apt/archives/*.deb; do
    dpkg-deb -x "$deb" "$root"
  done
  mkdir -p "$root/tmp" "$root/proc" "$root/dev" "$root/src"
  chmod 1777 "$root/tmp"
  [ -e "$root/bin/sh" ] || ln -s dash "$root/bin/sh"

  #  Static GNATCOLL (and what it uses), in this root only: the target
  #  then needs no Ada libraries
  sed -i 's/for Library_Kind use "dynamic";/for Library_Kind use "static";/' "$root"/usr/share/gpr/*.gpr
fi

#  -- Build -------------------------------------------------------------------

version=$(git -C "$top" describe --always)
rm -rf "$root/src/scopebridge"
mkdir -p "$root/src/scopebridge"
git -C "$top" archive HEAD | tar -x -C "$root/src/scopebridge"

echo "cross-build: building $version for $suite $arch (emulated: a few minutes)"
bwrap --bind "$root" / --proc /proc --dev /dev --setenv PATH /usr/bin:/bin \
      --chdir /src/scopebridge /bin/sh -c '
  gprbuild -q -p -P server/scopebridge_server.gpr scopebridge_server.adb -bargs -static -largs -static-libgcc &&
  gprbuild -q -p -P term/scopebridge_term.gpr -bargs -static -largs -static-libgcc'

#  -- Pack --------------------------------------------------------------------

#  The packing is the same on any computer: make package in the copy
make -C "$root/src/scopebridge" --no-print-directory package VERSION="$version" ARCH="$arch" > /dev/null
mkdir -p "$top/dist"
cp "$root/src/scopebridge/dist/scopebridge-$version-$arch.tar.gz" "$top/dist/"
echo "cross-build: dist/scopebridge-$version-$arch.tar.gz"
