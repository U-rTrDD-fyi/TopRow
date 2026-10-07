#import <AltList/ATLApplicationListMultiSelectionController.h>
#import "TPRPrefsStore.h"

// AltList's picker, storing its selection in the tweak's own prefs file.
@interface TPRExcludedAppsController : ATLApplicationListMultiSelectionController
@end

@implementation TPRExcludedAppsController

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    return TPRPrefsRead()[specifier.properties[@"key"]] ?: @[];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    TPRPrefsSet(specifier.properties[@"key"], value);
}

@end
