# ios6-revival Background Services: switches that turn Apple background services on or off. Build in WSL: see build.sh
ARCHS = armv7
TARGET = iphone:clang:9.3:6.0
THEOS_PLATFORM_DEB_COMPRESSION_TYPE = gzip
FINALPACKAGE = 1

include $(THEOS)/makefiles/common.mk

TOOL_NAME = revbgservices
revbgservices_FILES = revbgservices.m
revbgservices_FRAMEWORKS = Foundation
revbgservices_CFLAGS = -fno-objc-arc -fno-objc-convert-messages-to-runtime-calls -Wall -Wno-deprecated-module-dot-map
revbgservices_INSTALL_PATH = /usr/bin

include $(THEOS_MAKE_PATH)/tool.mk
