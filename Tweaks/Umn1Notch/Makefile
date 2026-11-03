
THEOS ?= $(HOME)/theos

# Rootless iOS 15+
TARGET = iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

# Main tweak
TWEAK_NAME = Umn1Notch
Umn1Notch_FILES = DynamicNotch/Tweak.x
Umn1Notch_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
Umn1Notch_FRAMEWORKS = UIKit Foundation QuartzCore AVFoundation CoreTelephony MediaPlayer
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS_MAKE_PATH)/tweak.mk

# Settings preference bundle
BUNDLE_NAME = Umn1NotchPrefs

Umn1NotchPrefs_FILES = Preferences/RootListController.m
Umn1NotchPrefs_INSTALL_PATH = /Library/PreferenceBundles
Umn1NotchPrefs_FRAMEWORKS = UIKit Foundation
Umn1NotchPrefs_PRIVATE_FRAMEWORKS = Preferences

# Explicit private framework search path for the iOS 16.5 SDK
UMN1_PRIVATE_FRAMEWORKS = $(THEOS)/sdks/iPhoneOS16.5.sdk/System/Library/PrivateFrameworks
Umn1NotchPrefs_LDFLAGS += -F$(UMN1_PRIVATE_FRAMEWORKS)

Umn1NotchPrefs_CFLAGS = -fobjc-arc
Umn1NotchPrefs_RESOURCE_DIRS = Preferences/Resources

include $(THEOS_MAKE_PATH)/bundle.mk
