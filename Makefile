TARGET := iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = RealTouch

RealTouch_FILES = Tweak.xm
RealTouch_CFLAGS = -fobjc-arc
RealTouch_FRAMEWORKS = UIKit Foundation Accessibility
RealTouch_LDFLAGS = -ldl

include $(THEOS_MAKE_PATH)/tweak.mk
