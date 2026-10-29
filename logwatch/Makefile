# ios6-revival Phone Log watcher: hourly size check of /var/log/syslog. Build in WSL: see build.sh
ARCHS = armv7
TARGET = iphone:clang:9.3:6.0
THEOS_PLATFORM_DEB_COMPRESSION_TYPE = gzip
FINALPACKAGE = 1

include $(THEOS)/makefiles/common.mk

TOOL_NAME = revlogwatch
revlogwatch_FILES = revlogwatch.m
revlogwatch_FRAMEWORKS = Foundation
revlogwatch_CFLAGS = -fno-objc-arc -fno-objc-convert-messages-to-runtime-calls -Wall -Wno-deprecated-module-dot-map
revlogwatch_INSTALL_PATH = /usr/bin

include $(THEOS_MAKE_PATH)/tool.mk
