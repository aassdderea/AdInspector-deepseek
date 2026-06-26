# 使用 Xcode 自带 SDK，不依赖 Theos 的 patched SDK
TARGET = iphone:clang:latest:16.6
ARCHS = arm64 arm64e

# 关键：指向 Xcode 的 SDK
SYSROOT = $(shell xcrun --sdk iphoneos --show-sdk-path)
PREFIX = $(SYSROOT)/usr

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
	@echo "✅ dylib 已生成: ./AdInspector.dylib"
	@file ./AdInspector.dylib || echo "检查文件是否存在"
