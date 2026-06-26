TARGET := iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AdInspector

AdInspector_FILES = Tweak.xm
AdInspector_CFLAGS = -fobjc-arc
AdInspector_FRAMEWORKS = UIKit

include $(THEOS_MAKE_PATH)/tweak.mk