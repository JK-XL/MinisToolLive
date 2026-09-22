TARGET := iphone:clang:latest:15.0
ARCHS := arm64 arm64e

# Dopamine / RootHide 无根越狱：装到 /var/jb 下
THEOS_PACKAGE_SCHEME := rootless

TWEAK_NAME := MinisToolLive
MinisToolLive_FILES := Tweak.xm MinisLiveOverlay.m
MinisToolLive_CFLAGS := -fobjc-arc -Wno-deprecated-declarations
MinisToolLive_FRAMEWORKS := UIKit Foundation QuartzCore

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk

# Dopamine(TweakInject) + RootHide 双通道安装
after-install::
	install.exec "mkdir -p /var/jb/usr/lib/TweakInject"
	install.exec "cp -f $(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/MinisToolLive.dylib /var/jb/usr/lib/TweakInject/ 2>/dev/null || true"
	install.exec "cp -f $(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/MinisToolLive.plist /var/jb/usr/lib/TweakInject/ 2>/dev/null || true"
	install.exec "sbreload 2>/dev/null || killall -9 SpringBoard 2>/dev/null || true"
