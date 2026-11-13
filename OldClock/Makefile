export THEOS_PACKAGE_SCHEME = rootless

TARGET := iphone:clang:latest:16.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = OldClock
OldClock_FILES = Tweak.x
OldClock_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
