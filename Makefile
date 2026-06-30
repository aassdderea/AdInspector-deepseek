TARGET := iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = IOKitTapper

IOKitTapper_FILES = Tweak.xm
IOKitTapper_CFLAGS = -fobjc-arc
IOKitTapper_FRAMEWORKS = UIKit Foundation
IOKitTapper_LDFLAGS = -ldl

include $(THEOS_MAKE_PATH)/tweak.mk
