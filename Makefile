# 使用系统最新 SDK，不指定具体版本号
TARGET = iphone:clang:latest
ARCHS = arm64 arm64e

# 强制使用当前 Xcode 的 SDK 和编译器路径
SDKROOT := $(shell xcrun --sdk iphoneos --show-sdk-path)
PREFIX  := $(SDKROOT)/usr/
TARGET_CC  := $(shell xcrun --find clang)
TARGET_CXX := $(shell xcrun --find clang++)
TARGET_LD  := $(shell xcrun --find clang++)

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
	@file ./AdInspector.dylib || echo "Check if file exists"
