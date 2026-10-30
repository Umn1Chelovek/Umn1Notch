THEOS ?= $(HOME)/theos

# One rootless package for iOS 15.0 and newer.
# The SDK is selected by GitHub Actions; deployment target stays at 15.0.
ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DynamicNotch
DynamicNotch_FILES = DynamicNotch/Tweak.x
DynamicNotch_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
DynamicNotch_FRAMEWORKS = UIKit QuartzCore AVFoundation CoreTelephony MediaPlayer

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS_MAKE_PATH)/tweak.mk
