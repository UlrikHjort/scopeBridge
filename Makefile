# =============================================================================
# ScopeBridge - Makefile
# =============================================================================
#
#   make                 build everything into bin/
#   make check           mock-based library tests (no instrument needed)
#   make check-server    FFT, decoding and timing tests, then protocol,
#                        scripting, terminal and web tests on the simulated
#                        scope
#   make check-web       the web interface in headless Firefox
#   make install         bin/ (the programs built), man pages, docs, Python
#                        client, web interface and a systemd user unit,
#                        under PREFIX
#                        (default /usr/local); build
#                        first, as yourself, then install (with sudo for a
#                        system prefix).  DESTDIR is honoured for packaging.
#   make install-udev    as root: a udev rule for the scope on USB without
#                        root (group UDEV_GROUP, default plugdev)
#   make uninstall       (and uninstall-udev)
#   make package         what is built, as a tarball to install on another
#                        computer of the same kind (sudo ./install.sh);
#                        contrib/cross-build.sh makes one for a Raspberry Pi
#   make clean
#
# Everything is built with gprbuild; the library (rigol_lib.gpr) is compiled
# once, into obj/lib, and shared by the examples, tests and server.
#
# Copyright (C) 2026 By Ulrik Hørlyk Hjort; MIT licence, see LICENSE.

GPRBUILD := gprbuild -q -p
BIN_DIR  := bin

.PHONY: all lib examples server gui term check check-server check-web install uninstall \
        install-udev uninstall-udev package clean

PREFIX           ?= /usr/local
BINDIR           := $(PREFIX)/bin
DATADIR          := $(PREFIX)/share/scopebridge
PYDIR            := $(DATADIR)/python
DOCDIR           := $(PREFIX)/share/doc/scopebridge
MANDIR           := $(PREFIX)/share/man/man1
#  Where systemd looks for user units: fine for /usr/local and /usr; for a
#  PREFIX in your home, use SYSTEMD_USER_DIR=~/.config/systemd/user
SYSTEMD_USER_DIR ?= $(PREFIX)/lib/systemd/user
#  The udev rule: /etc, as rules there are the machine's own
UDEV_DIR         ?= /etc/udev/rules.d
UDEV_GROUP       ?= plugdev

#  make package: named for the version and the Debian architecture
VERSION ?= $(shell git describe --always --dirty 2> /dev/null || date +%Y%m%d)
ARCH    ?= $(shell dpkg --print-architecture 2> /dev/null || uname -m)
PACKAGE := scopebridge-$(VERSION)-$(ARCH)
DIST    := dist

PROGRAMS := scopebridge-server scopebridge-gui scopebridge-term
PYTHON   := scopebridge.py scopebridge_client.py scopebridge_run.py scopebridge_tk.py
MANPAGES := scopebridge-server.1 scopebridge-gui.1 scopebridge-term.1 scopebridge-run.1

all: lib examples server gui term

#  Every library unit, including those no program happens to use, so none
#  can silently rot.
lib:
	$(GPRBUILD) -c -U -P rigol_lib.gpr

#  basic_demo, lan_demo, capture_demo and the test suite test_scpi
examples:
	$(GPRBUILD) -P rigol.gpr

#  scopebridge-server (docs/PROTOCOL.md), and its FFT and decoding tests.  Needs
#  GNATCOLL.
server:
	$(GPRBUILD) -P server/scopebridge_server.gpr

#  The GtkAda front end for the server.  Needs GtkAda (libgtkada-dev).
gui:
	$(GPRBUILD) -P gui/scopebridge_gui.gpr

#  scopebridge-term, the terminal client.  Needs GNATCOLL.
term:
	$(GPRBUILD) -P term/scopebridge_term.gpr

check: examples
	$(BIN_DIR)/test_scpi

check-server: server term
	$(BIN_DIR)/test_spectrum
	$(BIN_DIR)/test_decode
	$(BIN_DIR)/test_timing
	python3 tests/test_server.py
	python3 tests/test_scripting.py
	python3 tests/test_term.py
	python3 tests/test_web.py

#  The web interface in headless Firefox (skipped without Firefox)
check-web: server
	python3 tests/test_web_browser.py

#  Paths in the man pages and the unit are those of the installed files
SUBST := sed -e 's|@BINDIR@|$(BINDIR)|g' -e 's|@DOCDIR@|$(DOCDIR)|g' \
             -e 's|@PYDIR@|$(PYDIR)|g' -e 's|@DATADIR@|$(DATADIR)|g'

install:
	@[ -x $(BIN_DIR)/scopebridge-server ] || \
	  { echo "build first: make, or on a computer without GtkAda (a Raspberry Pi) make server term"; exit 1; }
	install -d $(DESTDIR)$(BINDIR) $(DESTDIR)$(PYDIR) $(DESTDIR)$(MANDIR) \
	  $(DESTDIR)$(DATADIR)/web \
	  $(DESTDIR)$(DOCDIR)/images $(DESTDIR)$(SYSTEMD_USER_DIR)
	#  The programs built: a Raspberry Pi serving the scope may have no GUI
	for p in $(PROGRAMS); do [ ! -x $(BIN_DIR)/$$p ] || \
	  install -m 755 $(BIN_DIR)/$$p $(DESTDIR)$(BINDIR); done
	install -m 755 scopebridge.sh $(DESTDIR)$(BINDIR)/scopebridge
	for f in $(PYTHON); do install -m 644 clients/python/$$f $(DESTDIR)$(PYDIR); done
	install -m 644 web/*.html web/*.js web/*.css $(DESTDIR)$(DATADIR)/web
	chmod 755 $(DESTDIR)$(PYDIR)/scopebridge_run.py $(DESTDIR)$(PYDIR)/scopebridge_tk.py
	printf '#!/bin/sh\nexec python3 %s/scopebridge_run.py "$$@"\n' $(PYDIR) \
	  > $(DESTDIR)$(BINDIR)/scopebridge-run
	printf '#!/bin/sh\nexec python3 %s/scopebridge_tk.py "$$@"\n' $(PYDIR) \
	  > $(DESTDIR)$(BINDIR)/scopebridge-tk
	chmod 755 $(DESTDIR)$(BINDIR)/scopebridge-run $(DESTDIR)$(BINDIR)/scopebridge-tk
	for m in $(MANPAGES); do \
	  $(SUBST) docs/man/$$m > $(DESTDIR)$(MANDIR)/$$m; chmod 644 $(DESTDIR)$(MANDIR)/$$m; done
	echo '.so man1/scopebridge-gui.1' > $(DESTDIR)$(MANDIR)/scopebridge.1
	install -m 644 README.md docs/MANUAL.md docs/PROTOCOL.md $(DESTDIR)$(DOCDIR)
	install -m 644 docs/images/*.png $(DESTDIR)$(DOCDIR)/images
	cp -r examples/scripts $(DESTDIR)$(DOCDIR)/examples
	$(SUBST) contrib/scopebridge-server.service.in \
	  > $(DESTDIR)$(SYSTEMD_USER_DIR)/scopebridge-server.service
	chmod 644 $(DESTDIR)$(SYSTEMD_USER_DIR)/scopebridge-server.service
	@echo "Installed under $(DESTDIR)$(PREFIX).  Start with: scopebridge [--lan HOST | --sim]"
	@echo "For the scope on USB without root, once: sudo make install-udev"

#  The group is made if the system has none (Fedora, Arch); the user who
#  ran sudo is told if they still have to join it
install-udev:
	install -d $(DESTDIR)$(UDEV_DIR)
	sed -e 's|@UDEV_GROUP@|$(UDEV_GROUP)|g' contrib/70-rigol.rules.in \
	  > $(DESTDIR)$(UDEV_DIR)/70-rigol.rules
	chmod 644 $(DESTDIR)$(UDEV_DIR)/70-rigol.rules
	#  The rule the README once had you write by hand
	rm -f $(DESTDIR)$(UDEV_DIR)/99-rigol.rules
	@if [ -z "$(DESTDIR)" ]; then \
	  getent group $(UDEV_GROUP) > /dev/null || groupadd --system $(UDEV_GROUP); \
	  udevadm control --reload && udevadm trigger --subsystem-match=usbmisc; \
	  user=$${SUDO_USER:-$$(id -un)}; \
	  if id -nG "$$user" | grep -qw $(UDEV_GROUP); then \
	    echo "Rule installed; $$user is in $(UDEV_GROUP).  Check: ls -l /dev/usbtmc*"; \
	  else \
	    echo "Rule installed.  Now: sudo usermod -aG $(UDEV_GROUP) $$user, and log in again"; \
	  fi; \
	fi

uninstall-udev:
	rm -f $(DESTDIR)$(UDEV_DIR)/70-rigol.rules $(DESTDIR)$(UDEV_DIR)/99-rigol.rules
	@[ -n "$(DESTDIR)" ] || udevadm control --reload

uninstall:
	rm -f $(addprefix $(DESTDIR)$(BINDIR)/,$(PROGRAMS) scopebridge scopebridge-run scopebridge-tk)
	rm -f $(addprefix $(DESTDIR)$(MANDIR)/,$(MANPAGES) scopebridge.1)
	rm -rf $(DESTDIR)$(DATADIR) $(DESTDIR)$(DOCDIR)
	rm -f $(DESTDIR)$(SYSTEMD_USER_DIR)/scopebridge-server.service

#  install and install-udev into a staging tree, with install.sh,
#  uninstall.sh and the lists of what they install; owned by root in the
#  tarball, and not writable by group or others
package:
	@[ -x $(BIN_DIR)/scopebridge-server ] || { echo "build first: make, or make server term"; exit 1; }
	rm -rf $(DIST)/$(PACKAGE) $(DIST)/$(PACKAGE).tar.gz
	umask 022 && $(MAKE) --no-print-directory install DESTDIR=$(abspath $(DIST))/$(PACKAGE)/root > /dev/null
	umask 022 && $(MAKE) --no-print-directory install-udev DESTDIR=$(abspath $(DIST))/$(PACKAGE)/root > /dev/null
	sed -e 's|@PREFIX@|$(PREFIX)|g' -e 's|@ARCH@|$(ARCH)|g' -e 's|@UDEV_GROUP@|$(UDEV_GROUP)|g' \
	  contrib/package-install.sh.in > $(DIST)/$(PACKAGE)/install.sh
	install -m 644 /dev/null $(DIST)/$(PACKAGE)/files
	cd $(DIST)/$(PACKAGE)/root && find . ! -type d | sed 's|^\.||' | sort > ../files
	cd $(DIST)/$(PACKAGE)/root && find . -mindepth 1 -depth -type d -path '*scopebridge*' | sed 's|^\.||' > ../dirs
	install -m 755 contrib/package-uninstall.sh $(DIST)/$(PACKAGE)/uninstall.sh
	chmod 755 $(DIST)/$(PACKAGE)/install.sh
	tar -czf $(DIST)/$(PACKAGE).tar.gz --owner=0 --group=0 --mode=go-w -C $(DIST) $(PACKAGE)
	@echo "$(DIST)/$(PACKAGE).tar.gz: copy it over, then tar -xzf it and sudo ./install.sh"

clean:
	rm -rf obj $(BIN_DIR)
