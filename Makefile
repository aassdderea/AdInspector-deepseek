# 只编译 arm64，避免 lipo 合并步骤出错
ARCHS = arm64
TARGET = iphone:clang:latest

# 强制使用当前 Xcode 的工具链
SDKROOT   := $(shell xcrun --sdk iphoneos --show-sdk-path)
PREFIX    := $(SDKROOT)/usr/
TARGET_CC  := $(shell xcrun --find clang)
TARGET_CXX := $(shell xcrun --find clang++)
TARGET_LD  := $(shell xcrun --find clang++)
TARGET_STRIP := $(shell xcrun --find strip)
TARGET_LIPO  := $(shell xcrun --find lipo)

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AdInspector
AdInspector_FILES = Tweak.xm
AdInspector_CFLAGS = -fobjc-arc
AdInspector_FRAMEWORKS = UIKit
AdInspector_LIBRARIES = objc

include $(THEOS_MAKE_PATH)/tweak.mk

after-package::
	@cp .theos/obj/AdInspector.dylib ./AdInspector.dylib 2>/dev/null || \
	 cp .theos/obj/$(ARCHS)/AdInspector.dylib ./AdInspector.dylib 2>/dev/null || true
	@echo "✅ dylib ready: ./AdInspector.dylib"
	@file ./AdInspector.dylib
