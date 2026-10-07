#import "TPRBaseListController.h"
#import "TPRPrefsStore.h"
#import "../TPRPaths.h"
#import <crt_externs.h>
#import <spawn.h>
#import <sys/wait.h>

@implementation TPRBaseListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Respring"
                                                                              style:UIBarButtonItemStylePlain
                                                                             target:self action:@selector(confirmRespring)];
}

- (void)showMessage:(NSString *)message title:(NSString *)title {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message
                                                             preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    id value = TPRPrefsRead()[specifier.properties[@"key"]];
    return value ?: specifier.properties[@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
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
