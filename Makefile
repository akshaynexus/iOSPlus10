# iOSPlus10 entry point (macOS and Linux). Long targets start a detached tmux job through
# scripts/bg.sh: check with `make status` or `scripts/bg.sh -s NAME`; logs in logs/NAME.log.
# Step order and details: docs/build-ios16.md.

BG := scripts/bg.sh
OS := $(shell uname -s)

.PHONY: help status tools op10tool colima image backup-ota backup-dump mu mu-prepare mu-build \
        kernel devicetree dmgs boot root simg

help:
	@echo "setup:   make tools | op10tool | colima (macOS) | image"
	@echo "backup:  make backup-ota | backup-dump (adb root)"
	@echo "uefi:    make mu  (= setup-mu + mu-prepare + mu-build)"
	@echo "ios16:   make kernel | devicetree | dmgs | boot | root (sudo) | simg"
	@echo "status:  make status"

status:
	@$(BG) -l
	@for f in logs/*.log; do [ -f "$$f" ] || continue; $(BG) -s $$(basename $$f .log) 2; done

# --- setup ---------------------------------------------------------------------------------
tools:
	$(BG) tools scripts/setup/native-tools.sh
op10tool:
	$(BG) op10tool scripts/setup/build-op10tool.sh
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
