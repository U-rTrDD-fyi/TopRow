export TARGET := iphone:clang:17.3.1:15.0
export ARCHS := arm64 arm64e
export THEOS_PACKAGE_SCHEME := rootless

export TPR_VERSION := $(shell grep '^Version:' $(CURDIR)/control | cut -d' ' -f2)

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TopRow
TopRow_FILES = Tweak.m TPRPatcher.m TPRConfig.m TPRTree.m
TopRow_CFLAGS = -fobjc-arc -DTPR_VERSION=\"$(TPR_VERSION)\"
TopRow_FRAMEWORKS = UIKit

SUBPROJECTS += prefs

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
