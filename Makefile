export TARGET = iphone:clang:latest:12.0
export ARCHS = arm64

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = PowerM

PowerM_FILES = Tweak.m
PowerM_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function
PowerM_FRAMEWORKS = UIKit

SUBPROJECTS += prefs

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
