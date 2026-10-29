# ios6-revival AutoClose tweak. Build in WSL: see build.sh
ARCHS = armv7
TARGET = iphone:clang:9.3:6.0
THEOS_PLATFORM_DEB_COMPRESSION_TYPE = gzip
FINALPACKAGE = 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AutoClose
AutoClose_FILES = Tweak.x
AutoClose_FRAMEWORKS = Foundation UIKit
AutoClose_CFLAGS = -fno-objc-arc -fno-objc-convert-messages-to-runtime-calls -Wall -Wno-unused-function -Wno-deprecated-module-dot-map

include $(THEOS_MAKE_PATH)/tweak.mk
