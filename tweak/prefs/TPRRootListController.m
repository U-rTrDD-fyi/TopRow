#import "TPRBaseListController.h"
#import "TPRPrefsStore.h"
#import <dlfcn.h>
#import <sys/sysctl.h>

@interface TPRRootListController : TPRBaseListController
@end

// Share sheet item for the diagnostics report: a .txt file (Save to Files, AirDrop, Mail),
// except Copy, which gets the report as plain text.
@interface TPRDiagnosticsItem : NSObject <UIActivityItemSource>
@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy) NSURL *file;
@end

@implementation TPRDiagnosticsItem

- (id)activityViewControllerPlaceholderItem:(UIActivityViewController *)controller {
    return self.file;
}

- (id)activityViewController:(UIActivityViewController *)controller itemForActivityType:(UIActivityType)type {
    return [type isEqualToString:UIActivityTypeCopyToPasteboard] ? self.text : self.file;
}

- (NSString *)activityViewController:(UIActivityViewController *)controller subjectForActivityType:(UIActivityType)type {
    return @"TopRow diagnostics";
}

@end

@implementation TPRRootListController

// The preview field is scratch space: never stored.
static BOOL IsPreview(PSSpecifier *specifier) {
    return [specifier.properties[@"key"] isEqual:@"Preview"];
}

- (NSArray *)specifiers {
    if (!_specifiers) _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    return _specifiers;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    // Behave like a normal text field so "Lowercase Row When Auto-Capitalized" can be previewed.
    PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
    if (IsPreview(specifier) && [cell respondsToSelector:@selector(textField)]) {
        UITextField *field = [cell performSelector:@selector(textField)];
        field.autocapitalizationType = UITextAutocapitalizationTypeSentences;
        field.autocorrectionType = UITextAutocorrectionTypeDefault;
    }
    return cell;
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    return IsPreview(specifier) ? nil : [super readPreferenceValue:specifier];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    if (IsPreview(specifier)) return;
    [super setPreferenceValue:value specifier:specifier];
}

- (void)shareDiagnostics:(PSSpecifier *)specifier {
    char model[64] = "?";
    size_t size = sizeof(model);
    sysctlbyname("hw.machine", model, &size, NULL, 0);
    // Which apps are excluded is the user's business; a count is enough for a bug report.
    NSMutableDictionary *settings = [TPRPrefsRead() mutableCopy];
    if ([settings[@"ExcludedApps"] isKindOfClass:[NSArray class]])
        settings[@"ExcludedApps"] = [NSString stringWithFormat:@"%lu apps", (unsigned long)[settings[@"ExcludedApps"] count]];
    NSMutableString *report = [NSMutableString stringWithFormat:@"TopRow %s\n%s, iOS %@\n\nSettings: %@\n",
                               TPR_VERSION, model, UIDevice.currentDevice.systemVersion, settings];
    // The tweak is loaded in Settings too; its recent decisions (patched / skipped, why).
    NSArray *(*recent)(void) = (NSArray *(*)(void))dlsym(RTLD_DEFAULT, "TPRRecentLog");
    [report appendString:@"\nRecent log (this Settings session):\n"];
    [report appendString:recent ? [recent() componentsJoinedByString:@"\n"] : @"(tweak not loaded here)"];

    NSFileManager *files = NSFileManager.defaultManager;
    for (NSString *old in [files contentsOfDirectoryAtPath:NSTemporaryDirectory() error:NULL])
        if ([old hasPrefix:@"TopRow-Diagnostics-"])
            [files removeItemAtPath:[NSTemporaryDirectory() stringByAppendingPathComponent:old] error:NULL];
    NSDateFormatter *stamp = [NSDateFormatter new];
    stamp.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    stamp.dateFormat = @"yyyy-MM-dd-HHmmss";
    NSString *name = [NSString stringWithFormat:@"TopRow-Diagnostics-%@.txt", [stamp stringFromDate:NSDate.date]];
    NSURL *file = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
    NSError *error;
    if (![report writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
        [self showMessage:error.localizedDescription title:@"Couldn't Save Diagnostics"];
        return;
    }
    TPRDiagnosticsItem *item = [TPRDiagnosticsItem new];
    item.text = report;
    item.file = file;
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[ item ]
                                                                        applicationActivities:nil];
    UIView *anchor = [self cachedCellForSpecifier:specifier] ?: self.view;   // popover anchor (iPad)
    share.popoverPresentationController.sourceView = anchor;
    share.popoverPresentationController.sourceRect = anchor.bounds;
    [self presentViewController:share animated:YES completion:nil];
}

- (void)resetDefaults:(PSSpecifier *)specifier {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Reset TopRow?"
                                                                   message:@"Every TopRow setting goes back to its default."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        TPRPrefsReset();
        [self reloadSpecifiers];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
