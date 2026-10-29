# ios6-revival iOS Updates switch: blocks or allows the iOS update check. Build in WSL: see build.sh
ARCHS = armv7
TARGET = iphone:clang:9.3:6.0
THEOS_PLATFORM_DEB_COMPRESSION_TYPE = gzip
FINALPACKAGE = 1

include $(THEOS)/makefiles/common.mk

TOOL_NAME = revupdateblock
revupdateblock_FILES = revupdateblock.m
revupdateblock_FRAMEWORKS = Foundation
revupdateblock_CFLAGS = -fno-objc-arc -fno-objc-convert-messages-to-runtime-calls -Wall -Wno-deprecated-module-dot-map
revupdateblock_INSTALL_PATH = /usr/bin

include $(THEOS_MAKE_PATH)/tool.mk
