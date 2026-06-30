TARGET := iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BSTest

BSTest_FILES = Tweak.xm
BSTest_CFLAGS = -fobjc-arc
BSTest_FRAMEWORKS = UIKit Foundation
BSTest_LDFLAGS = -ldl -lbsm

include $(THEOS_MAKE_PATH)/tweak.mk
