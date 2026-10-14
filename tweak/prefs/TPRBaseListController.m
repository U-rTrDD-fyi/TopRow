#import "TPRBaseListController.h"
#import "TPRPrefsStore.h"
#import "TPRSetups.h"
#import "../TPRPaths.h"
#import <crt_externs.h>
#import <spawn.h>
#import <sys/wait.h>

static NSString *const kSettingsChanged = @"TPRSettingsChanged";

// Darwin notifications arrive for every write, this process's own included; pages sort it out.
static void OnDarwinChange(CFNotificationCenterRef center, void *observer, CFNotificationName name,
                           const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:kSettingsChanged object:nil];
    });
}

@implementation TPRBaseListController {
    NSData *_shownPrefs, *_shownSetups;   // the files as they were when the rows were last loaded
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Respring"
                                                                              style:UIBarButtonItemStylePlain
                                                                             target:self action:@selector(confirmRespring)];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CFNotificationCenterRef darwin = CFNotificationCenterGetDarwinNotifyCenter();
        for (NSString *name in @[ TPRPrefsReloadNotification, TPRSetupsChangedNotification ])
            CFNotificationCenterAddObserver(darwin, NULL, OnDarwinChange, (__bridge CFStringRef)name, NULL,
                                            CFNotificationSuspensionBehaviorDeliverImmediately);
    });
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(settingsChanged) name:kSettingsChanged object:nil];
    [center addObserver:self selector:@selector(settingsChanged) name:UIApplicationWillEnterForegroundNotification object:nil];
    [self noteShown];
}

// ---- refreshing ------------------------------------------------------------------

- (void)noteShown {
    _shownPrefs = TPRPrefsFileData();
    _shownSetups = TPRSetupsFileData();
}

- (void)reloadSpecifiers {
    [super reloadSpecifiers];
    [self noteShown];
}

- (BOOL)isEditingText {
    for (UITableViewCell *cell in self.table.visibleCells)
        if ([cell respondsToSelector:@selector(textField)] && [[cell performSelector:@selector(textField)] isFirstResponder])
            return YES;
    return NO;
}

// Coming back to a page (from one of its own sub-pages, or another app): show what's stored now.
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (![TPRPrefsFileData() isEqualToData:_shownPrefs] || ![TPRSetupsFileData() isEqualToData:_shownSetups])
        [self reloadSpecifiers];
}

// While a page is on screen, only another app's change refreshes it: reloading after its own
// writes would yank a slider or text field out from under the finger.
- (void)settingsChanged {
    if (!self.isViewLoaded || !self.view.window || self.isEditingText) return;
    NSData *prefs = TPRPrefsFileData(), *setups = TPRSetupsFileData();
    BOOL prefsElsewhere = ![prefs isEqualToData:_shownPrefs] && ![prefs isEqualToData:TPRPrefsLastWrittenData()];
    BOOL setupsElsewhere = ![setups isEqualToData:_shownSetups] && ![setups isEqualToData:TPRSetupsLastWrittenData()];
    if (prefsElsewhere || setupsElsewhere) [self reloadSpecifiers];
}

// ---- values ----------------------------------------------------------------------

static BOOL IsPreview(PSSpecifier *specifier) {
    return [specifier.properties[@"key"] isEqual:@"Preview"];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    // Behave like a normal text field so "Lowercase Row When Auto-Capitalized" can be previewed.
    if (IsPreview([self specifierAtIndexPath:indexPath]) && [cell respondsToSelector:@selector(textField)]) {
        UITextField *field = [cell performSelector:@selector(textField)];
        field.autocapitalizationType = UITextAutocapitalizationTypeSentences;
        field.autocorrectionType = UITextAutocorrectionTypeDefault;
    }
    return cell;
}

- (void)showMessage:(NSString *)message title:(NSString *)title {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message
                                                             preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    if (IsPreview(specifier)) return nil;
    id value = TPRPrefsRead()[specifier.properties[@"key"]];
    return value ?: specifier.properties[@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    if (IsPreview(specifier)) return;
    NSString *key = specifier.properties[@"key"];
    NSString *problem = nil;
    if ([key hasSuffix:@"Row"]) problem = TPRPrefsRowProblem(value);
    else if ([key hasPrefix:@"Label"] && [value isKindOfClass:[NSString class]] &&
             TPRPrefsCharacterCount([value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]) > 5)
        problem = @"Labels can be at most 5 characters.";
    else if (TPRPrefsSizeRange(key).length) {
        NSNumber *number = nil;
        problem = TPRPrefsSizeProblem(key, value, &number);
        value = number;
    }
    if (problem) {
        [self showMessage:problem title:@"Not saved"];
        [self reloadSpecifier:specifier];
        return;
    }
    TPRPrefsSet(key, value);
}

// ---- respring -------------------------------------------------------------------

- (void)confirmRespring {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Respring?"
                                                                   message:@"Restarts SpringBoard. TopRow's changes already apply without it."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Respring" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [self respring];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

// Runs a tool and waits for it; YES if it exited with status 0.
static BOOL RunTool(NSString *path, NSArray<NSString *> *arguments) {
    NSMutableArray<NSString *> *args = [NSMutableArray arrayWithObject:path.lastPathComponent];
    [args addObjectsFromArray:arguments];
    char *argv[args.count + 1];
    for (NSUInteger i = 0; i < args.count; i++) argv[i] = (char *)args[i].UTF8String;
    argv[args.count] = NULL;
    pid_t pid;
    if (posix_spawn(&pid, path.fileSystemRepresentation, NULL, NULL, argv, *_NSGetEnviron()) != 0) return NO;
    int status = 0;
    if (waitpid(pid, &status, 0) != pid) return NO;
    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

- (void)respring {
    // Settings can't ask SpringBoard to relaunch itself (iOS 17 kills the asking app
    // instead), but it can run the jailbreak's own tools.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL ok = RunTool(TPRRootPath(@"/usr/bin/sbreload"), @[]) ||
                  RunTool(TPRRootPath(@"/usr/bin/killall"), @[ @"-9", @"SpringBoard" ]);
        if (!ok) dispatch_async(dispatch_get_main_queue(), ^{
            [self showMessage:@"Respring from your package manager instead." title:@"Couldn't Respring"];
        });
    });
}

@end
