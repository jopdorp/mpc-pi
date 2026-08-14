################################################################################
#
# mame-mpc
#
# MAME built for the MPC2000XL only, with this project's ordered patch stack
# applied. The stack is the same one scripts/build-mame.sh applies on the
# desktop, read straight from patches/mame, so there is one source of truth.
#
################################################################################

# Must match the base revision the patch stack was generated against; see
# docs/mame-patch-stack.md. A different revision will fail the apply check
# below rather than silently building something the patches do not describe.
MAME_MPC_VERSION = f8c55f4cdad70fa5b7dfae9a26a15114aea70f9a
MAME_MPC_SITE = $(call github,mamedev,mame,$(MAME_MPC_VERSION))
MAME_MPC_LICENSE = BSD-3-Clause, GPL-2.0+
MAME_MPC_LICENSE_FILES = COPYING

MAME_MPC_DEPENDENCIES = \
	host-python3 host-pkgconf \
	sdl2 sdl2_ttf fontconfig freetype zlib expat flac sqlite \
	portmidi alsa-lib

ifeq ($(BR2_PACKAGE_PIPEWIRE),y)
MAME_MPC_DEPENDENCIES += pipewire
endif

MAME_MPC_SOURCES = \
	src/mame/akai/mpc60.cpp,src/mame/akai/mpc2000.cpp,src/mame/akai/mpc3000.cpp

# -ffp-contract=off is not optional. The DSP mixes in float, and letting the
# compiler contract multiply-add pairs changes the rendered PCM, which breaks
# comparability with the reference render this project gates against.
MAME_MPC_ARCHOPTS = -ffp-contract=off
ifeq ($(BR2_cortex_a76),y)
MAME_MPC_ARCHOPTS += -mcpu=cortex-a76
endif

MAME_MPC_MAKE_OPTS = \
	SUBTARGET=mpc \
	SOURCES=$(MAME_MPC_SOURCES) \
	TARGETOS=linux \
	OSD=sdl \
	NO_X11=1 \
	NO_USE_XINPUT=1 \
	USE_QTDEBUG=0 \
	DEBUG=0 \
	SYMBOLS=0 \
	REGENIE=1 \
	NOWERROR=1 \
	PTR64=1 \
	CROSS_BUILD=1 \
	OVERRIDE_CC="$(TARGET_CC)" \
	OVERRIDE_CXX="$(TARGET_CXX)" \
	OVERRIDE_LD="$(TARGET_CXX)" \
	AR="$(TARGET_AR)" \
	PYTHON_EXECUTABLE="$(HOST_DIR)/bin/python3" \
	ARCHOPTS="$(MAME_MPC_ARCHOPTS)"

# Apply the project's ordered stack. Refusing on the first failure matters:
# a partially patched tree still builds and produces a binary that silently
# lacks whichever optimisations came after the failure.
define MAME_MPC_APPLY_STACK
	set -e; \
	for patch in $(sort $(wildcard $(BR2_EXTERNAL_MPC_PI_PATH)/patches/mame/0*.patch)); do \
		echo "mame-mpc: applying $$(basename $$patch)"; \
		patch -p1 -d $(@D) -i $$patch; \
	done
endef
MAME_MPC_POST_PATCH_HOOKS += MAME_MPC_APPLY_STACK

define MAME_MPC_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) $(MAME_MPC_MAKE_OPTS)
endef

define MAME_MPC_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/mpc $(TARGET_DIR)/usr/bin/mpc
	$(INSTALL) -d -m 0755 $(TARGET_DIR)/usr/share/mpc-pi/roms
	$(INSTALL) -D -m 0644 $(BR2_EXTERNAL_MPC_PI_PATH)/roms/mpc2000xl.zip \
		$(TARGET_DIR)/usr/share/mpc-pi/roms/mpc2000xl.zip
endef

$(eval $(generic-package))
