#!/bin/sh
#  Removes what install.sh installed:  sudo ./uninstall.sh
# Copyright (C) 2026 By Ulrik Hørlyk Hjort; MIT licence, see LICENSE.
set -e
cd "$(dirname "$0")"

if [ "$(id -u)" != 0 ]; then
  echo "uninstall.sh: run it as root: sudo ./uninstall.sh" >&2
  exit 1
fi
while read -r f; do
  rm -f "$f"
done < files
#  Its own directories (share/scopebridge, share/doc/scopebridge), if nothing else
#  is in them now
while read -r d; do
  rmdir "$d" 2> /dev/null || true
done < dirs
udevadm control --reload || true
echo "Removed.  (A running scopebridge-server service: systemctl --user disable --now scopebridge-server)"
