TARGET := iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TapSimulator

TapSimulator_FILES = Tweak.xm
TapSimulator_CFLAGS = -fobjc-arc
TapSimulator_FRAMEWORKS = UIKit Foundation
TapSimulator_LDFLAGS = -ldl

include $(THEOS_MAKE_PATH)/tweak.mk
