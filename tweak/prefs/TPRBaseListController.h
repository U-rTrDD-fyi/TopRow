#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

// Shared by the TopRow panes: values live in the tweak's own prefs file (with
// validation), and every pane gets a Respring button.
@interface TPRBaseListController : PSListController
- (void)showMessage:(NSString *)message title:(NSString *)title;
@end
