#import "TPRBaseListController.h"
#import "TPRPrefsStore.h"
#import "TPRSetups.h"
#import "../TPRKeyRows.h"

// "Keys": every row of the letters, Shift / Caps Lock, 123 and #+= pages, and the labels
// of the keys that switch between them. A row is stored only when it differs from what
// the keyboard would show anyway, so clearing it (or typing Apple's row back) restores it.
@interface TPRKeysController : TPRBaseListController
@end

@implementation TPRKeysController

- (NSArray *)specifiers {
    if (!_specifiers) _specifiers = [self loadSpecifiersFromPlistName:@"Keys" target:self];
    return _specifiers;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    TPRSetupsSetFlag(@"KeysPageSeen");   // retires the "NEW" badge on the main page
}

static BOOL ParseRowKey(NSString *key, TPRKeyPlane *plane, NSUInteger *row) {
    for (TPRKeyPlane p = 0; p < TPRKeyPlaneCount; p++)
        for (NSUInteger r = 0; r < TPRKeyRowCount; r++)
            if ([TPRKeyRowPrefsKey(p, r) isEqualToString:key]) {
                *plane = p;
                *row = r;
                return YES;
            }
    return NO;
}

static NSString *Normalized(id value) {
    return [value isKindOfClass:[NSString class]] ? [TPRSplitKeys(value) componentsJoinedByString:@" "] : @"";
}

// What the keyboard shows for a row when nothing is stored for it.
static NSString *DefaultRow(TPRKeyPlane plane, NSUInteger row, NSDictionary *prefs) {
    if (plane == TPRKeyPlaneShifted) {
        NSString *letters = Normalized(prefs[TPRKeyRowPrefsKey(TPRKeyPlaneLetters, row)]);
        if (letters.length) return letters.uppercaseString;
    }
    return TPRStockKeyRow(plane, row);
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    TPRKeyPlane plane;
    NSUInteger row;
    if (!ParseRowKey(specifier.properties[@"key"], &plane, &row)) return [super readPreferenceValue:specifier];
    NSDictionary *prefs = TPRPrefsRead();
    NSString *stored = Normalized(prefs[specifier.properties[@"key"]]);
    return stored.length ? stored : DefaultRow(plane, row, prefs);
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = specifier.properties[@"key"];
    TPRKeyPlane plane;
    NSUInteger row;
    if (!ParseRowKey(key, &plane, &row)) {
        [super setPreferenceValue:value specifier:specifier];
        return;
    }
    NSString *text = Normalized(value);
    NSString *problem = TPRPrefsKeyRowProblem(text);
    if (problem) {
        [self showMessage:problem title:@"Not saved"];
        [self reloadSpecifier:specifier];
        return;
    }
    // Store only a real change, so a cleared or unchanged row keeps following its default.
    // (Apple's capitals typed into a Shift row under edited letters is a change: it's kept.)
    BOOL isDefault = !text.length || [text isEqualToString:DefaultRow(plane, row, TPRPrefsRead())];
    TPRPrefsSet(key, isDefault ? nil : text);
    // Shift rows show the letters rows in capitals until changed: refresh them.
    if (plane == TPRKeyPlaneLetters) [self reloadSpecifiers];
    else if (!text.length) [self reloadSpecifier:specifier];
}

- (void)resetKeys:(PSSpecifier *)specifier {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Reset Keys?"
                                                                   message:@"Every row and switch-key label goes back to Apple's. Your current settings are saved in Setups first."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        NSMutableArray *keys = [NSMutableArray arrayWithObjects:@"Label123", @"LabelABC", @"LabelSymbols", nil];
        for (TPRKeyPlane p = 0; p < TPRKeyPlaneCount; p++)
            for (NSUInteger r = 0; r < TPRKeyRowCount; r++) [keys addObject:TPRKeyRowPrefsKey(p, r)];
        TPRSetupsBackUp(@"Before Reset Keys");
        TPRPrefsRemove(keys);
        [self reloadSpecifiers];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
