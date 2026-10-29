# ios6-revival App Store logger (phase 1: observe only). Build in WSL: see build.sh
ARCHS = armv7
TARGET = iphone:clang:9.3:6.0
THEOS_PLATFORM_DEB_COMPRESSION_TYPE = gzip
FINALPACKAGE = 1

include $(THEOS)/makefiles/common.mk

AS_CFLAGS = -fno-objc-arc -fno-objc-convert-messages-to-runtime-calls -Wall -Wno-unused-function -Wno-deprecated-module-dot-map

TWEAK_NAME = RevivalAppStore
RevivalAppStore_FILES = Tweak.x ASLog.m ASDelegates.m ASBag.m ASAuth.x
RevivalAppStore_FRAMEWORKS = Foundation Security
RevivalAppStore_CFLAGS = $(AS_CFLAGS)

include $(THEOS_MAKE_PATH)/tweak.mk
