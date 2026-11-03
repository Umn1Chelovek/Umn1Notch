THEOS ?= $(HOME)/theos

TARGET = iphone:clang:latest:15.0
ARCHS = arm64 arm64e

THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Umn1Notch

Umn1Notch_FILES = DynamicNotch/Tweak.x

Umn1Notch_CFLAGS = \
    -fobjc-arc \
    -fblocks \
    -Wno-deprecated-declarations \
    -Wno-unused-variable

Umn1Notch_FRAMEWORKS = \
    UIKit \
    Foundation \
    QuartzCore \
    AVFoundation \
    CoreTelephony \
    MediaPlayer \
    AudioToolbox

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS_MAKE_PATH)/tweak.mk

BUNDLE_NAME = Umn1NotchPrefs

Umn1NotchPrefs_FILES = \
    Preferences/RootListController.m

Umn1NotchPrefs_INSTALL_PATH = /Library/PreferenceBundles

Umn1NotchPrefs_FRAMEWORKS = \
    UIKit \
    Foundation

Umn1NotchPrefs_PRIVATE_FRAMEWORKS = Preferences

Umn1NotchPrefs_CFLAGS = \
    -fobjc-arc

Umn1NotchPrefs_RESOURCE_DIRS = \
    Preferences/Resources

include $(THEOS_MAKE_PATH)/bundle.mk
