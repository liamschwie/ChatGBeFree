TARGET := iphone:clang:latest:14.0
ARCHS := arm64
INSTALL_TARGET_PROCESSES = ChatGPT
THEOS_PACKAGE_SCHEME ?= rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ChatGBeFree

ChatGBeFree_FILES = \
	VoiceBridge/LegacyVoiceBridge.m \
	VoiceBridge/LegacyRealtimeVoice.m \
	VoiceBridge/LegacyNativeVoiceLifecycle.m \
	VoiceBridge/LegacySDPTransform.m \
	CopyBridge/LegacyCopyBridge.m \
	ImageBridge/LegacyImageBridge.m \
	ModelSwitcher/LegacyModelSwitcher.m \
	ModelSwitcher/LegacyModelSelectionPersistence.m \
	Runtime/ChatGPTRuntimeResolver.m
ChatGBeFree_CFLAGS = -fobjc-arc -fvisibility=hidden -Wall -Wextra
ChatGBeFree_FRAMEWORKS = Foundation UIKit AVFoundation
ChatGBeFree_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
