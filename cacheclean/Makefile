# ios6-revival Clear Caches: a Settings pane with a Clear button, plus the revcacheclean tool. Build in WSL: see build.sh
ARCHS = armv7
TARGET = iphone:clang:9.3:6.0
THEOS_PLATFORM_DEB_COMPRESSION_TYPE = gzip
FINALPACKAGE = 1

include $(THEOS)/makefiles/common.mk

RCC_CFLAGS = -fno-objc-arc -fno-objc-convert-messages-to-runtime-calls -Wall -Wno-deprecated-module-dot-map

TOOL_NAME = revcacheclean
revcacheclean_FILES = revcacheclean.m RCCClean.m
revcacheclean_FRAMEWORKS = Foundation
revcacheclean_CFLAGS = $(RCC_CFLAGS)
revcacheclean_INSTALL_PATH = /usr/bin

BUNDLE_NAME = CacheCleaner
CacheCleaner_FILES = RCCListController.m RCCClean.m
CacheCleaner_FRAMEWORKS = Foundation UIKit
CacheCleaner_PRIVATE_FRAMEWORKS = Preferences
CacheCleaner_CFLAGS = $(RCC_CFLAGS)
CacheCleaner_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/tool.mk
include $(THEOS_MAKE_PATH)/bundle.mk
