#!/bin/sh
#  What ScopeBridge needs to build, what of it is missing on this computer,
#  and how to get it.  Used by the Makefile:
#
#    check-deps.sh                  the report               (make deps-check)
#    check-deps.sh --install        the report, then offers to install what
#                                   is missing, with apt     (make deps)
#    check-deps.sh --targets        the make targets that can be built, on
#                                   stdout; the report on stderr if
#                                   something is missing     (make)
#    check-deps.sh --skipped TARGETS  after make: what was not built
#    check-deps.sh --need gnat|gnatcoll|gtkada ...
#                                   fails with the report if one of them is
#                                   missing                  (make server ...)
#
#  GNATCOLL and GtkAda are looked for the way the build finds them: by
#  gprbuild, through the project files gnatcoll.gpr and gtkada.gpr.
#
# Copyright (C) 2026 By Ulrik Hørlyk Hjort; MIT licence, see LICENSE.

mode=${1:-report}

have() { command -v "$1" > /dev/null 2>&1; }

#  Can gprbuild find the project file NAME.gpr?
find_gpr() {
  dir=$(mktemp -d) || return 1
  printf 'with "%s";\nproject Probe is\n   for Source_Dirs use ();\nend Probe;\n' "$1" \
    > "$dir/probe.gpr"
  gprbuild -q -P "$dir/probe.gpr" > /dev/null 2>&1
  status=$?
  rm -rf "$dir"
  return $status
}

#  The Debian or Ubuntu package with NAME's project file; the names carry
#  version numbers that change between releases
apt_package() {
  have apt-cache || return 0
  case $1 in
    gnatcoll) apt-cache pkgnames libgnatcoll | grep -E '^libgnatcoll(-core)?[0-9]*-dev$' | sort | tail -1 ;;
    gtkada)   apt-cache pkgnames libgtkada | grep -E '^libgtkada[0-9.]*-dev$' | sort | tail -1 ;;
  esac
}

installed() {
  [ "$(dpkg-query -W -f='${Status}' "$1" 2> /dev/null)" = "install ok installed" ]
}

#  After make: no probing needed
if [ "$mode" = --skipped ]; then
  skipped=
  for t in server term gui; do
    case " $2 " in *" $t "*) ;; *) skipped="$skipped scopebridge-$t" ;; esac
  done
  [ -z "$skipped" ] ||
    echo "Not built:$skipped; make deps-check tells why"
  exit 0
fi

#  --- What is here --------------------------------------------------------

gnat_ok=no gnatcoll_ok=no gtkada_ok=no
probe() {
  for lib in "$@"; do
    find_gpr $lib && eval "${lib}_ok=yes"
  done
}
ok() { eval "[ \"\$${1}_ok\" = yes ]"; }

if have gnat && have gprbuild; then
  gnat_ok=yes
  if [ "$mode" = --need ]; then
    #  Only what was asked for, unless it is missing
    shift
    for lib in "$@"; do
      [ $lib = gnat ] || probe $lib
    done
    for lib in "$@"; do
      ok $lib || break
    done
    ok $lib && exit 0
    ok gnatcoll || probe gnatcoll
    ok gtkada || probe gtkada
  else
    probe gnatcoll gtkada
  fi
fi

#  --- What is missing, and the packages that have it ----------------------

packages= notes=
if [ $gnat_ok = no ]; then
  have gnat || packages="$packages gnat"
  have gprbuild || packages="$packages gprbuild"
fi
for lib in gnatcoll gtkada; do
  ok $lib && continue
  pkg=$(apt_package $lib)
  if [ -z "$pkg" ]; then
    have apt-cache &&
      notes="$notes
  No package for $lib.gpr in this system's package sources."
  elif installed "$pkg"; then
    #  Installed, so a gprbuild that is not the system's own (from AdaCore
    #  or Alire) is not looking there
    if [ $gnat_ok = yes ]; then
      gpr=$(dpkg -L "$pkg" | grep "/$lib\.gpr\$" | head -1)
      notes="$notes
  $pkg is installed, but $(command -v gprbuild) does not look where it
  put $lib.gpr; tell it: export GPR_PROJECT_PATH=$(dirname "${gpr:-/usr/share/gpr/x}")"
    fi
  else
    packages="$packages $pkg"
  fi
done
#  apt only where there is apt
have apt-cache || packages=

#  --- The report -----------------------------------------------------------

state() { [ "$1" = yes ] && echo "found  " || echo "MISSING"; }

report() {
  if [ $gnat_ok = yes ]; then
    version=$(gnat --version 2> /dev/null | head -1)
    echo "  GNAT and gprbuild   found    ($version)"
    echo "  GNATCOLL            $(state $gnatcoll_ok)  (scopebridge-server, scopebridge-term)"
    echo "  GtkAda              $(state $gtkada_ok)  (scopebridge-gui)"
  else
    echo "  GNAT and gprbuild   MISSING  (everything)"
    echo "  GNATCOLL, GtkAda    looked for once gprbuild is here"
  fi
  [ -z "$notes" ] || echo "$notes"
  if [ -n "$packages" ]; then
    . /etc/os-release 2> /dev/null
    echo
    echo "To install what is missing${PRETTY_NAME:+ ($PRETTY_NAME)}:"
    echo "  sudo apt install$packages"
    [ "$mode" = --install ] || echo "or: make deps, which asks before it runs that."
  elif ! have apt-cache && [ "$gnat_ok$gnatcoll_ok$gtkada_ok" != yesyesyes ]; then
    echo
    echo "Install what is missing from your distribution's packages (the names"
    echo "vary; tested on Debian and Ubuntu only), or build it from source.  If"
    echo "a .gpr file is somewhere gprbuild does not look, add its folder to"
    echo "GPR_PROJECT_PATH."
  fi
}

case $mode in
  report)
    echo "What ScopeBridge needs to build:"
    report ;;

  --install)
    echo "What ScopeBridge needs to build:"
    report
    if [ -z "$packages" ]; then
      have apt-cache && printf '\nNothing to install with apt.\n'
      exit 0
    fi
    echo
    printf "Run sudo apt install%s now? [y/N] " "$packages"
    read -r answer
    case $answer in
      [yY]*) sudo apt install$packages ;;
      *)     echo "Not installed." ;;
    esac ;;

  --targets)
    if [ $gnat_ok = no ]; then
      { echo "Cannot build: GNAT and gprbuild are needed."; report; } >&2
      exit 1
    fi
    targets="lib examples"
    [ $gnatcoll_ok = yes ] && targets="$targets server term"
    [ $gtkada_ok = yes ] && [ $gnatcoll_ok = yes ] && targets="$targets gui"
    if [ "$gnatcoll_ok$gtkada_ok" != yesyes ]; then
      { echo "Not everything can be built here:"; report;
        echo; echo "Building what can be built."; echo; } >&2
    fi
    echo "$targets" ;;

  --need)
    { echo "Cannot build this: something it needs is missing."; report; } >&2
    exit 1 ;;

  *)
    echo "usage: $0 [--install | --targets | --skipped TARGETS | --need gnat|gnatcoll|gtkada ...]" >&2
    exit 2 ;;
esac
