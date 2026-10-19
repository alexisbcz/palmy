# Palmframe — build the distribution from this checkout.
#
#   make -C distro            everything: kernel and busybox (if missing), the
#                             Odin binaries, the packages, the signed
#                             repository and the bootable disk image
#   make -C distro repo       stop after distro/out/repo/x86_64/PALMINDEX
#   make -C distro image      distro/out/palmframe.img (from the repository)
#   make -C distro run        boot the image in QEMU, in a window
#   make -C distro test       boot it headless: greeter, login, desktop, term,
#                             launcher, palm verify/update/add, poweroff;
#                             screenshots in distro/out/shots/
#   make -C distro serve      serve distro/out/repo on :8080 for the guest's
#                             `palm update` (QEMU shows the host as 10.0.2.2)
#   make -C distro check-libs every shipped binary links only what glibc ships
#   make -C distro iso        distro/out/palmframe-live.iso, the live installer
#                             (UEFI and BIOS, runs from RAM; distro/live)
#   make -C distro run-iso    boot it in QEMU with a blank target disk
#   make -C distro test-installer  the installer's selftests (no disks touched)
#   make -C distro test-install    ISO -> GUI and CLI installs -> boot each
#                             installed disk, all in QEMU; distro/out/shots/
#   make -C distro clean      remove the packages, root and image (not the
#                             kernel, busybox or the keys)
#
# The order is the CONTRACT's: compile, then `palm build` every recipe in
# distro/recipes into the repository, sign its index, then let palm itself
# install the `palmframe` meta-package into an empty root — the image is
# assembled exactly the way a user's `palm add` would assemble it.
#
# The kernel and busybox take minutes and change rarely, so they are built
# only when their output is missing; delete distro/out/bzImage or
# distro/out/busybox to rebuild them. Odin binaries are rebuilt when their
# sources change.

ROOT   := $(abspath ..)
DISTRO := $(ROOT)/distro
OUT    := $(DISTRO)/out
BIN    := $(OUT)/bin
REPO   := $(OUT)/repo/x86_64
KEYS   := $(DISTRO)/build/keys
ODIN   ?= odin
PORT   ?= 8080
COLL   := -collection:palmy=palmy -collection:kit=apps/kit -collection:shadcn=shadcn
# The installer's two front ends also import install_core (INSTALLER.md).
ICOLL  := $(COLL) -collection:install=distro/installer

# What palm build substitutes for ${...} in the recipes.
export PALMFRAME_ROOT := $(ROOT)
export PALMFRAME_OUT  := $(OUT)
export PALMFRAME_KEYS := $(KEYS)
export SOURCE_DATE_EPOCH ?= 0

PALM := $(BIN)/palm

.PHONY: all recipes packages repo image run test serve check-libs clean binaries iso run-iso test-installer test-install
.DELETE_ON_ERROR:

all: image

# --- sources every palmy program is built from --------------------------------
TOOLKIT := $(shell find $(ROOT)/palmy $(ROOT)/apps/kit $(ROOT)/shadcn -name '*.odin' 2>/dev/null)
srcs = $(shell find $(ROOT)/$(1) -name '*.odin' 2>/dev/null)

# --- kernel and busybox: only when missing ------------------------------------
$(OUT)/bzImage:
	$(DISTRO)/kernel/build.sh
$(OUT)/kernel.config: | $(OUT)/bzImage
$(OUT)/busybox:
	$(DISTRO)/busybox/build.sh

# --- Odin binaries ------------------------------------------------------------
$(BIN)/palm: $(call srcs,distro/palm)
	@mkdir -p $(BIN)
	cd $(ROOT) && $(ODIN) build distro/palm -o:speed -out:$@

$(BIN)/palm-init: $(call srcs,distro/init)
	$(DISTRO)/init/build.sh

$(BIN)/palm-login: $(call srcs,distro/login)
	@mkdir -p $(BIN)
	cd $(ROOT) && $(ODIN) build distro/login -o:speed $(COLL) -out:$@

# doas and passwd share palm-login's auth package (distro/login/auth); the
# recipes install them setuid root.
$(BIN)/doas: $(call srcs,distro/doas) $(call srcs,distro/login/auth)
	@mkdir -p $(BIN)
	cd $(ROOT) && $(ODIN) build distro/doas -o:speed -out:$@

$(BIN)/passwd: $(call srcs,distro/passwd) $(call srcs,distro/login/auth)
	@mkdir -p $(BIN)
	cd $(ROOT) && $(ODIN) build distro/passwd -o:speed -out:$@

$(BIN)/palmd: $(call srcs,distro/palmd)
	@mkdir -p $(BIN)
	cd $(ROOT) && $(ODIN) build distro/palmd -o:speed -out:$@

$(BIN)/wm: $(call srcs,apps/wm) $(TOOLKIT)
	@mkdir -p $(BIN)
	cd $(ROOT) && $(ODIN) build apps/wm -o:speed $(COLL) -out:$@

# The applications: every distro/out/bin/<name> a recipe names, built by
# distro/apps/build.sh (which knows that palm-apps comes from apps/palm and
# prose from apps/prose/cli).
APP_BINS := $(filter-out palm palm-init palm-login doas passwd palmd wm palm-install installer, \
	$(sort $(shell grep -ho 'PALMFRAME_OUT}/bin/[a-z0-9-]*' $(DISTRO)/recipes/*/PALMBUILD | sed 's|.*/||')))
app_dir = $(if $(filter palm-apps,$(1)),palm,$(if $(filter prose,$(1)),prose,$(1)))
app_src = $(if $(filter palm-apps,$(1)),palm,$(if $(filter prose,$(1)),prose/cli,$(1)))

define app_rule
$(BIN)/$(1): $(call srcs,apps/$(call app_dir,$(1))) $(TOOLKIT)
	$(DISTRO)/apps/build.sh $(call app_src,$(1))
	@test -x $$@
endef
$(foreach a,$(APP_BINS),$(eval $(call app_rule,$(a))))

# The installer: palm-install (distro/installer/cli) and the graphical
# installer (apps/installer), both over install_core in distro/installer/core.
# A failed build stops make like any other binary: the live image must never
# ship a stale installer from an earlier good build.
INSTALLER_BINS := $(BIN)/palm-install $(BIN)/installer
$(BIN)/palm-install: $(call srcs,distro/installer)
	@mkdir -p $(BIN)
	cd $(ROOT) && $(ODIN) build distro/installer/cli -o:speed $(ICOLL) -out:$@
$(BIN)/installer: $(call srcs,apps/installer) $(call srcs,distro/installer/core) $(TOOLKIT)
	@mkdir -p $(BIN)
	cd $(ROOT) && $(ODIN) build apps/installer -o:speed $(ICOLL) -out:$@

binaries: $(BIN)/palm $(BIN)/palm-init $(BIN)/palm-login $(BIN)/doas $(BIN)/passwd $(BIN)/palmd $(BIN)/wm $(addprefix $(BIN)/,$(APP_BINS)) $(INSTALLER_BINS)

# --- the signing key ----------------------------------------------------------
# Made once per checkout and kept out of git (distro/build/ is ignored). The
# public half goes into palmframe-base's /etc/palm/keys, so every installed
# system trusts exactly the repository it was built from.
$(KEYS)/palmframe.sec: | $(PALM)
	@mkdir -p $(KEYS)
	$(PALM) keygen $(KEYS)/palmframe
$(KEYS)/palmframe.pub: $(KEYS)/palmframe.sec

# --- recipes, packages, the repository ----------------------------------------
recipes: $(OUT)/busybox
	$(DISTRO)/recipes/generate.sh

# Every package is rebuilt on each run: palm build is reproducible (same
# inputs, same bytes, same sha256 in the index) and takes seconds, and it is
# the only way to notice a host file such as glibc changing underneath.
packages: recipes binaries $(OUT)/bzImage $(OUT)/busybox $(KEYS)/palmframe.pub
	@mkdir -p $(REPO)
	rm -f $(REPO)/*.palm
	@set -e; for r in $(DISTRO)/recipes/*/PALMBUILD; do \
		$(PALM) build $$(dirname $$r) -o $(REPO) >/dev/null; \
	done
	@echo "packages: $$(ls $(REPO)/*.palm | wc -l) in $(REPO)"

repo: packages
	$(PALM) index $(REPO) --key $(KEYS)/palmframe.sec

# --- the disk image -----------------------------------------------------------
image: repo
	$(DISTRO)/image/build.sh

run:
	$(DISTRO)/run-qemu.sh

# --- the live installer -------------------------------------------------------
# A zstd initramfs of the live root (palmframe + palmframe-live, with the
# repository inside it) on an ISO that limine boots from UEFI and BIOS.
iso: repo
	$(DISTRO)/live/build.sh

run-iso:
	$(DISTRO)/run-qemu.sh --iso

test:
	python3 -I -u $(DISTRO)/image/test-boot.py

# The installer's own checks, none of which touch a host disk: install_core
# and palm-install's selftest (GPTs written into image files, an install into
# a directory) and the graphical installer's (demo backend only).
test-installer: $(BIN)/palm-install $(BIN)/installer
	@mkdir -p $(DISTRO)/build/installer-core
	cd $(ROOT) && TMPDIR=$(DISTRO)/build/installer-core $(BIN)/palm-install --selftest
	cd $(ROOT) && $(BIN)/installer --selftest

# End to end, all inside QEMU: the live ISO, the graphical installer driven
# over QMP onto a blank disk, palm-install onto a second one from the serial
# console, then each installed disk booted on its own (distro/live/test-install.py).
test-install: iso
	python3 -I -u $(DISTRO)/live/test-install.py

serve:
	@echo "serving $(OUT)/repo on http://0.0.0.0:$(PORT) (the guest uses http://10.0.2.2:$(PORT)/x86_64)"
	python3 -m http.server $(PORT) --directory $(OUT)/repo

# Every dynamic binary a recipe ships must need nothing beyond what the glibc
# and libxkbcommon packages carry.
check-libs: binaries
	@bad=0; for b in $(BIN)/palm $(BIN)/palm-login $(BIN)/doas $(BIN)/passwd $(BIN)/palmd $(BIN)/wm $(addprefix $(BIN)/,$(APP_BINS)) $(INSTALLER_BINS); do \
		for l in $$(ldd $$b | awk '/=>/ {print $$1} /^\t\// {print $$1}'); do \
			case "$$l" in libc.so.6|libm.so.6|/lib64/ld-linux-x86-64.so.2) ;; \
			*) echo "check-libs: $$b needs $$l"; bad=1 ;; esac; \
		done; \
	done; test $$bad = 0 && echo "check-libs: every binary links only glibc"

clean:
	rm -rf $(OUT)/repo $(OUT)/rootfs $(OUT)/palmframe.img $(OUT)/shots $(DISTRO)/build/image
	rm -rf $(OUT)/palmframe-live.iso $(DISTRO)/build/live/rootfs $(DISTRO)/build/live/iso
