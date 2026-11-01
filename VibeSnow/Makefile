export THEOS_PACKAGE_SCHEME = rootless

TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SnowOverlay
VibeSnow_FILES = Tweak.x
VibeSnow_FRAMEWORKS = UIKit QuartzCore
VibeSnow_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
