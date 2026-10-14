#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

// Shared by the TopRow panes: values live in the tweak's own prefs file (with
// validation), every pane gets a Respring button, a "Preview" field is scratch space
// (never stored), and a pane refreshes when another app (Settings, TweakSettings)
// changes the settings or setups.
@interface TPRBaseListController : PSListController
- (void)showMessage:(NSString *)message title:(NSString *)title;
@end
