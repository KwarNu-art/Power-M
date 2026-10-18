include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = PowerMPrefs

PowerMPrefs_FILES = PowerMRootListController.m
PowerMPrefs_INSTALL_PATH = /Library/PreferenceBundles
PowerMPrefs_FRAMEWORKS = UIKit
PowerMPrefs_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
# Preferences.framework is private and already loaded inside Settings, so resolve it at runtime.
PowerMPrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/bundle.mk
