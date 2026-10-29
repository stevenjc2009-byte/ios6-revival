# ios6-revival Notify: SpringBoard banner tweak + revnotify command. Build in WSL: see build.sh
ARCHS = armv7
TARGET = iphone:clang:9.3:6.0
THEOS_PLATFORM_DEB_COMPRESSION_TYPE = gzip
FINALPACKAGE = 1

include $(THEOS)/makefiles/common.mk

RN_CFLAGS = -fno-objc-arc -fno-objc-convert-messages-to-runtime-calls -Wall -Wno-unused-function -Wno-deprecated-module-dot-map

TWEAK_NAME = RevivalNotify
RevivalNotify_FILES = Tweak.x
RevivalNotify_FRAMEWORKS = Foundation UIKit
RevivalNotify_CFLAGS = $(RN_CFLAGS)

TOOL_NAME = revnotify
revnotify_FILES = revnotify.m
revnotify_FRAMEWORKS = Foundation
revnotify_CFLAGS = $(RN_CFLAGS)
revnotify_INSTALL_PATH = /usr/bin

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/tool.mk
