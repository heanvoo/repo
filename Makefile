export THEOS_PACKAGE_SCHEME = rootless
TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = StretchClock
StretchClock_FILES = Tweak.x
StretchClock_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
