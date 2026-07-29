TARGET := iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = SpringBoard
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ChatGBeFree

ChatGBeFree_FILES = Tweak.x
ChatGBeFree_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
