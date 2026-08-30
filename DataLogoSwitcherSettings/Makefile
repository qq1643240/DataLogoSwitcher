BUNDLE_NAME = DataLogoSwitcher
DataLogoSwitcher_FILES = DataLogoSwitcher.m
DataLogoSwitcher_INSTALL_PATH = /Library/PreferenceBundles
DataLogoSwitcher_FRAMEWORKS = UIKit
DataLogoSwitcher_CFLAGS = -fobjc-arc
DataLogoSwitcher_PRIVATE_FRAMEWORKS = Preferences

SDKVERSION = 16.5
SYSROOT = $(THEOS)/sdks/iPhoneOS16.5.sdk

ifneq ($(filter rootless roothide,$(THEOS_PACKAGE_SCHEME)),)
	ARCHS = arm64 arm64e
	TARGET = iphone:16.5:12.0
else
	ARCHS = arm64 arm64e
	TARGET = iphone:12.1.2:11.0
endif


GO_EASY_ON_ME = 1

include theos/makefiles/common.mk
include $(THEOS_MAKE_PATH)/bundle.mk
