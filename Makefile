# iOSPlus10 entry point (macOS and Linux). Long targets start a detached tmux job through
# scripts/bg.sh: check with `make status` or `scripts/bg.sh -s NAME`; logs in logs/NAME.log.
# Step order and details: docs/build-ios16.md.

BG := scripts/bg.sh
OS := $(shell uname -s)

.PHONY: help status tools op10tool colima image references backup-ota backup-dump mu mu-prepare mu-build mu-build-macos \
        kernel kernel-local kernel-ci xcode15 ssh devicetree dmgs boot root simg ios16 flash flash-boot flash-restore boot-debug flash-boot-debug usblog

help:
	@echo "setup:   make tools | op10tool | colima (macOS) | image"
	@echo "refs:    make references  (reference-only repos into external/, not submodules)"
	@echo "backup:  make backup-ota | backup-dump (adb root)"
	@echo "uefi:    make mu  (= setup-mu + mu-prepare + mu-build) | mu-build-macos (native, no container)"
	@echo "kernel:  make xcode15 (once) | kernel-local (our patches, Xcode 15) | kernel-ci | kernel (slop CI download)"
	@echo "ssh:     make ssh (dropbear/dash/toybox for iOS; added to the next root)"
	@echo "ios16:   make kernel | devicetree | dmgs | boot | root (sudo) | simg"
	@echo "build:   make ios16  (kernel devicetree dmgs boot root simg, in order)"
	@echo "flash:   make flash CONFIRM=yes | flash-boot CONFIRM=yes (no userdata) | flash-restore CONFIRM=yes"
	@echo "status:  make status"

status:
	@$(BG) -l
	@for f in logs/*.log; do [ -f "$$f" ] || continue; $(BG) -s $$(basename $$f .log) 2; done

# --- setup ---------------------------------------------------------------------------------
tools:
	$(BG) tools scripts/setup/native-tools.sh
op10tool:
	$(BG) op10tool scripts/setup/build-op10tool.sh
references:
	$(BG) references scripts/setup/get-references.sh
colima:
ifeq ($(OS),Darwin)
	scripts/setup/colima-up.sh
else
	@echo "colima is macOS only; on Linux use Docker directly"
endif
image:
	$(BG) docker-image scripts/setup/docker-image.sh

# --- stock backup --------------------------------------------------------------------------
backup-ota:
	$(BG) ota scripts/backup/fetch-stock-ota.sh
backup-dump:
	$(BG) dump scripts/backup/dump-partitions.sh

# --- Mu UEFI (container) -------------------------------------------------------------------
mu:
	$(BG) mu-all sh -c 'scripts/uefi/setup-mu.sh && scripts/uefi/prepare.sh && scripts/uefi/build.sh DEBUG'
mu-prepare:
	$(BG) mu-prepare scripts/uefi/prepare.sh
mu-build:
	$(BG) mu-build scripts/uefi/build.sh DEBUG
mu-build-macos:
	$(BG) mu-build-macos scripts/uefi/build-macos.sh DEBUG

# --- kernel (our patches/xnu on top of the negroni port) ------------------------------------
xcode15:
	$(BG) xcode15 scripts/kernel/install-xcode15.sh
kernel-local:
	$(BG) kernel-local scripts/kernel/build-local.sh
kernel-ci:
	$(BG) kernel-ci scripts/kernel/ci-build.sh

# --- SSH over USB (userland/ssh) -----------------------------------------------------------
ssh:
	$(BG) ssh-build sh -c 'userland/ssh/fetch.sh && userland/ssh/build.sh'

# --- iOS 16 --------------------------------------------------------------------------------
kernel:
	$(BG) kernel scripts/ios16/fetch-kernel.sh
devicetree:
	scripts/ios16/fetch-d22ap-adt.sh
dmgs:
	$(BG) dmgs scripts/ios16/fetch-dmgs.sh
boot:
	$(BG) ios16 scripts/ios16/build.sh
root:
	$(BG) root sudo scripts/ios16/root.sh
	@echo "type the sudo password: tmux attach -t root  (detach: Ctrl-b d)"
simg:
	$(BG) simg scripts/ios16/root-simg.sh
# refresh the root with the current add-ons + firmware areas from the sparse root alone (SUDO_PASS=... for tmux)
root-refresh:
	$(BG) root-refresh env SUDO_PASS=$(SUDO_PASS) scripts/ios16/root-refresh.sh

# all iOS 16 build steps after the Mu UEFI, in order, in one tmux job (root asks for sudo once)
ios16:
	$(BG) ios16-all sh -c 'scripts/ios16/fetch-kernel.sh && scripts/ios16/fetch-d22ap-adt.sh && scripts/ios16/fetch-dmgs.sh && scripts/ios16/build.sh && sudo scripts/ios16/root.sh && scripts/ios16/root-simg.sh'
	@echo "sudo password: tmux attach -t ios16-all  (detach: Ctrl-b d)"

# --- flash (phone connected; each target needs CONFIRM=yes) ---------------------------------
flash:
	$(BG) flash env CONFIRM=$(CONFIRM) scripts/flash/all.sh
flash-boot:
	$(BG) flash env CONFIRM=$(CONFIRM) scripts/flash/all.sh --skip-userdata
# debug variant: kernel log on the panel (negronifb_noconsole=0) and over USB (negroniusb=2,
# read it with `make usblog`) -> out/ios16-debug
boot-debug:
	$(BG) ios16-debug env IOS16_OUT=$(CURDIR)/out/ios16-debug BOOTARGS_DROP="negronifb_noconsole= negroniusb=" BOOTARGS_ADD="negronifb_noconsole=0 -enable_kprintf_spam negroniusb=2" sh -c 'mkdir -p $$IOS16_OUT && cp out/ios16/negroni.adt out/ios16/vendor_boot_a.img $$IOS16_OUT/ && scripts/ios16/build.sh payload && scripts/ios16/build.sh boot'
flash-boot-debug:
	$(BG) flash env CONFIRM=$(CONFIRM) IOS16_OUT=$(CURDIR)/out/ios16-debug scripts/flash/all.sh --skip-userdata
# live kernel log over USB Ethernet (debug image); needs sudo: tmux attach -t usblog
usblog:
	$(BG) usblog sudo scripts/debug/usblog.sh
	@echo "sudo password: tmux attach -t usblog  (detach: Ctrl-b d); log: logs/usblog-*.txt"
flash-restore:
	$(BG) flash-restore env CONFIRM=$(CONFIRM) scripts/flash/restore.sh
