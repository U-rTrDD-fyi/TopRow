include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = TopRowPrefs
TopRowPrefs_FILES = TPRPrefsStore.m TPRBaseListController.m TPRRootListController.m TPRSliderCell.m TPRKeyboardTypesController.m TPRExcludedAppsController.m
TopRowPrefs_CFLAGS = -fobjc-arc -DTPR_VERSION=\"$(TPR_VERSION)\"
TopRowPrefs_FRAMEWORKS = UIKit
TopRowPrefs_PRIVATE_FRAMEWORKS = Preferences
TopRowPrefs_EXTRA_FRAMEWORKS = AltList
TopRowPrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences"$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/TopRow.plist"$(ECHO_END)
