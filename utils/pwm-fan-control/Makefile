# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 Georg Seema <georgseema@gmail.com>

include $(TOPDIR)/rules.mk

PKG_NAME:=pwm-fan-control
PKG_VERSION:=1.0.0
PKG_RELEASE:=2
PKG_MAINTAINER:=Georg Seema <georgseema@gmail.com>
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define Package/pwm-fan-control
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Standalone PWM fan controller
  DEPENDS:=+coreutils-stty +jsonfilter +uclient-fetch +kmod-hwmon-pwmfan
  PKGARCH:=all
endef

define Package/pwm-fan-control/description
 A small standalone PWM fan control daemon for OpenWrt. It supports kernel,
 PID auto, temperature curve, manual and disabled modes without requiring LuCI.
endef

define Package/pwm-fan-control/conffiles
/etc/pwm-fan.conf
endef

define Build/Compile
endef

define Package/pwm-fan-control/install
	$(INSTALL_DIR) $(1)/etc/init.d $(1)/usr/sbin $(1)/usr/lib/pwm-fan
	$(INSTALL_CONF) ./files/etc/pwm-fan.conf $(1)/etc/pwm-fan.conf
	$(INSTALL_BIN) ./files/etc/init.d/pwm-fan-control $(1)/etc/init.d/pwm-fan-control
	$(INSTALL_BIN) ./files/usr/sbin/pwm-fan-control $(1)/usr/sbin/pwm-fan-control
	$(INSTALL_DATA) ./files/usr/lib/pwm-fan/common.sh $(1)/usr/lib/pwm-fan/common.sh
	$(INSTALL_DATA) ./files/usr/lib/pwm-fan/config.sh $(1)/usr/lib/pwm-fan/config.sh
	$(INSTALL_DATA) ./files/usr/lib/pwm-fan/hardware.sh $(1)/usr/lib/pwm-fan/hardware.sh
	$(INSTALL_DATA) ./files/usr/lib/pwm-fan/policy.sh $(1)/usr/lib/pwm-fan/policy.sh
	$(INSTALL_DATA) ./files/usr/lib/pwm-fan/modem.sh $(1)/usr/lib/pwm-fan/modem.sh
	$(INSTALL_DATA) ./files/usr/lib/pwm-fan/fan_watch.sh $(1)/usr/lib/pwm-fan/fan_watch.sh
	$(INSTALL_DATA) ./files/usr/lib/pwm-fan/control.sh $(1)/usr/lib/pwm-fan/control.sh
	$(INSTALL_DATA) ./files/usr/lib/pwm-fan/runtime.sh $(1)/usr/lib/pwm-fan/runtime.sh
	$(INSTALL_DATA) ./files/usr/lib/pwm-fan/daemon.sh $(1)/usr/lib/pwm-fan/daemon.sh
	$(INSTALL_DATA) ./files/usr/lib/pwm-fan/api.sh $(1)/usr/lib/pwm-fan/api.sh
endef

$(eval $(call BuildPackage,pwm-fan-control))
