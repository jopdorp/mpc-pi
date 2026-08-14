################################################################################
#
# mpc-mk1-display
#
################################################################################

MPC_MK1_DISPLAY_VERSION = 1.0.0
MPC_MK1_DISPLAY_SITE = $(BR2_EXTERNAL_MPC_PI_PATH)/scripts/maschine
MPC_MK1_DISPLAY_SITE_METHOD = local
MPC_MK1_DISPLAY_LICENSE = BSD-3-Clause
MPC_MK1_DISPLAY_DEPENDENCIES = python3 python-pyusb

define MPC_MK1_DISPLAY_BUILD_CMDS
endef

define MPC_MK1_DISPLAY_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/mpc-mk1-display.py \
		$(TARGET_DIR)/usr/bin/mpc-mk1-display
endef

$(eval $(generic-package))
