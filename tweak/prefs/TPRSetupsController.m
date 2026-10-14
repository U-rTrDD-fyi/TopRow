#import "TPRBaseListController.h"
#import "TPRSetups.h"
#import "TPRShareSheet.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// "Setups": save the current settings under a name; apply, share, rename or delete saved
// ones; restore an automatic backup; import a setup someone shared (pasted or as a file).
@interface TPRSetupsController : TPRBaseListController <UIDocumentPickerDelegate>
@end

@implementation TPRSetupsController

static const NSUInteger kMaxImportBytes = 64 * 1024;

static PSSpecifier *Group(NSString *name, NSString *footer) {
    PSSpecifier *group = [PSSpecifier groupSpecifierWithName:name];
    if (footer) [group setProperty:footer forKey:@"footerText"];
    return group;
}

- (PSSpecifier *)button:(NSString *)name action:(SEL)action {
    PSSpecifier *button = [PSSpecifier preferenceSpecifierNamed:name target:self set:NULL get:NULL detail:nil
                                                           cell:PSButtonCell edit:nil];
    button.buttonAction = action;
    return button;
}

- (PSSpecifier *)rowForSetup:(NSDictionary *)setup {
    PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:setup[@"Name"] target:self set:NULL
                                                         get:@selector(dateOfSetup:) detail:nil cell:PSTitleValueCell edit:nil];
    [row setProperty:setup[@"ID"] forKey:@"setupID"];
    return row;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *list = [NSMutableArray array];
        [list addObject:Group(nil, @"A setup holds every TopRow setting except Enabled: the top row, Keys, sizes, keyboard types and excluded apps.")];
        [list addObject:[self button:@"Save Current Settings…" action:@selector(saveCurrent:)]];
        [list addObject:[self button:@"Share Current Settings…" action:@selector(shareCurrent:)]];
        NSArray *saved = TPRSetupsSaved();
        [list addObject:Group(@"Saved Setups", saved.count
            ? [NSString stringWithFormat:@"Tap a setup to apply, share, rename or delete it. You can keep up to %d.", TPRMaxSetups]
            : @"None yet.")];
        for (NSDictionary *setup in saved) [list addObject:[self rowForSetup:setup]];
        NSArray *backups = TPRSetupsBackups();
        [list addObject:Group(@"Automatic Backups", [NSString stringWithFormat:@"%@TopRow saves your settings here before Reset to Defaults, Reset Keys or applying a setup, and keeps the %d newest.",
                                                     backups.count ? @"" : @"None yet. ", TPRMaxBackups])];
        for (NSDictionary *setup in backups) [list addObject:[self rowForSetup:setup]];
        [list addObject:Group(@"Import", @"Adds a setup someone shared with you to Saved Setups. You see what's in it first, and nothing changes until you apply it.")];
        [list addObject:[self button:@"Paste from Clipboard" action:@selector(importFromClipboard:)]];
        [list addObject:[self button:@"Choose File…" action:@selector(importFromFile:)]];
        _specifiers = list;
    }
    return _specifiers;
}

- (NSString *)dateOfSetup:(PSSpecifier *)specifier {
    NSDate *date = TPRSetupWithID([specifier propertyForKey:@"setupID"])[@"Date"];
    if (![date isKindOfClass:[NSDate class]]) return nil;
    static NSDateFormatter *format;
    if (!format) {
        format = [NSDateFormatter new];
        format.dateStyle = NSDateFormatterShortStyle;
        format.timeStyle = NSDateFormatterShortStyle;
        format.doesRelativeDateFormatting = YES;
    }
    return [format stringFromDate:date];
}

- (NSString *)setupIDAtIndexPath:(NSIndexPath *)indexPath {
    return [[self specifierAtIndexPath:indexPath] propertyForKey:@"setupID"];
}

// What's in a setup, for alerts: its first lines, then how many more.
static NSString *Summary(NSDictionary *settings, NSString *empty) {
    NSArray *lines = TPRSetupLines(settings, YES);
    if (!lines.count) return empty;
    NSUInteger shown = MIN(lines.count, (NSUInteger)8);
    NSString *text = [[lines subarrayWithRange:NSMakeRange(0, shown)] componentsJoinedByString:@"\n"];
    if (lines.count > shown) text = [text stringByAppendingFormat:@"\n…and %lu more", (unsigned long)(lines.count - shown)];
    return text;
}

// ---- rows: tap for actions, swipe to rename or delete -----------------------------

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    if ([self setupIDAtIndexPath:indexPath]) cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([self setupIDAtIndexPath:indexPath] || ![PSListController instancesRespondToSelector:_cmd]) return YES;
    return [super tableView:tableView shouldHighlightRowAtIndexPath:indexPath];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *setupID = [self setupIDAtIndexPath:indexPath];
    if (!setupID) {
        [super tableView:tableView didSelectRowAtIndexPath:indexPath];
        return;
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self showActionsForSetup:setupID anchor:[tableView cellForRowAtIndexPath:indexPath]];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return [self setupIDAtIndexPath:indexPath] != nil;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return [self setupIDAtIndexPath:indexPath] ? UITableViewCellEditingStyleDelete : UITableViewCellEditingStyleNone;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *setupID = [self setupIDAtIndexPath:indexPath];
    if (!setupID) return nil;
    NSMutableArray *actions = [NSMutableArray array];
    [actions addObject:[UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Delete"
                                                             handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        TPRSetupsDelete(setupID);
        [self reloadSpecifiers];
        done(YES);
    }]];
    if (!TPRSetupIsBackup(setupID)) {
        UIContextualAction *rename = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"Rename"
                                                                           handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
            [self renameSetup:setupID];
            done(YES);
        }];
        rename.backgroundColor = UIColor.systemBlueColor;
        [actions addObject:rename];
    }
    UISwipeActionsConfiguration *config = [UISwipeActionsConfiguration configurationWithActions:actions];
    config.performsFirstActionWithFullSwipe = NO;
    return config;
}

- (void)showActionsForSetup:(NSString *)setupID anchor:(UIView *)anchor {
    NSDictionary *setup = TPRSetupWithID(setupID);
    if (!setup) {
        [self reloadSpecifiers];
        return;
    }
    BOOL backup = TPRSetupIsBackup(setupID);
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:setup[@"Name"]
                                                                   message:Summary(setup[@"Settings"], @"Every setting at its default.")
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:backup ? @"Restore" : @"Apply" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) { [self applySetup:setupID]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Share…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self shareSettings:setup[@"Settings"] name:setup[@"Name"]];
    }]];
    if (backup)
        [sheet addAction:[UIAlertAction actionWithTitle:@"Save as Setup…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [self promptToSave:setup[@"Settings"] title:@"Save as Setup"];
        }]];
    else
        [sheet addAction:[UIAlertAction actionWithTitle:@"Rename…" style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) { [self renameSetup:setupID]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *a) { [self confirmDeleteSetup:setupID]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    anchor = anchor ?: self.view;   // popover anchor (iPad)
    sheet.popoverPresentationController.sourceView = anchor;
    sheet.popoverPresentationController.sourceRect = anchor.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

// ---- actions ----------------------------------------------------------------------

// Asks for a name; `use` returns nil when it's taken care of, else why not (then shown).
- (void)askForName:(NSString *)name title:(NSString *)title button:(NSString *)button use:(NSString *(^)(NSString *))use {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:@"Name this setup."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = name;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
        field.autocapitalizationType = UITextAutocapitalizationTypeWords;
        field.returnKeyType = UIReturnKeyDone;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UIAlertAction *ok = [UIAlertAction actionWithTitle:button style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *problem = use(alert.textFields.firstObject.text);
        if (problem) [self showMessage:problem title:@"Not Saved"];
    }];
    [alert addAction:ok];
    alert.preferredAction = ok;
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)promptToSave:(NSDictionary *)settings title:(NSString *)title {
    if (TPRSetupsSaved().count >= TPRMaxSetups) {
        [self showMessage:[NSString stringWithFormat:@"You have %d setups, the most TopRow keeps. Delete one first.", TPRMaxSetups]
                    title:@"Can't Save"];
        return;
    }
    [self askForName:TPRSetupsSuggestedName() title:title button:@"Save" use:^NSString *(NSString *name) {
        NSString *problem = TPRSetupsSave(name, settings);
        if (!problem) [self reloadSpecifiers];
        return problem;
    }];
}

- (void)saveCurrent:(PSSpecifier *)specifier {
    [self promptToSave:TPRSetupCurrentSettings() title:@"Save Current Settings"];
}

- (void)renameSetup:(NSString *)setupID {
    NSDictionary *setup = TPRSetupWithID(setupID);
    if (!setup) return;
    [self askForName:setup[@"Name"] title:@"Rename Setup" button:@"Rename" use:^NSString *(NSString *name) {
        NSString *problem = TPRSetupsRename(setupID, name);
        if (!problem) [self reloadSpecifiers];
        return problem;
    }];
}

- (void)confirmDeleteSetup:(NSString *)setupID {
    NSDictionary *setup = TPRSetupWithID(setupID);
    if (!setup) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Delete “%@”?", setup[@"Name"]]
                                                                   message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        TPRSetupsDelete(setupID);
        [self reloadSpecifiers];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)applySetup:(NSString *)setupID {
    NSDictionary *setup = TPRSetupWithID(setupID);
    if (!setup) return;
    BOOL backup = TPRSetupIsBackup(setupID);
    NSString *reason = backup ? @"Before restoring a backup" : [NSString stringWithFormat:@"Before applying “%@”", setup[@"Name"]];
    BOOL backedUp = TPRSetupApply(setup, reason);
    [self reloadSpecifiers];
    [self showMessage:backedUp ? @"Your previous settings are in Automatic Backups." : nil
                title:backup ? @"Backup Restored" : [NSString stringWithFormat:@"Applied “%@”", setup[@"Name"]]];
}

// Excluded Apps is a personal list (bundle IDs of your apps): asked about, left out by default.
- (void)shareSettings:(NSDictionary *)settings name:(NSString *)name {
    void (^share)(BOOL) = ^(BOOL includeApps) {
        NSString *problem = TPRShareText(self, nil, TPRSetupText(name, settings, includeApps),
                                         [NSString stringWithFormat:@"TopRow Setup - %@.txt", name],
                                         [NSString stringWithFormat:@"TopRow setup: %@", name]);
        if (problem) [self showMessage:problem title:@"Couldn't Share"];
    };
    NSArray *apps = settings[@"ExcludedApps"];
    if (![apps isKindOfClass:[NSArray class]] || !apps.count) {
        share(NO);
        return;
    }
    NSString *message = [NSString stringWithFormat:@"This setup turns TopRow off in %lu app%@. That list is personal and may not match someone else's apps.",
                         (unsigned long)apps.count, apps.count == 1 ? @"" : @"s"];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Include Excluded Apps?" message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *leaveOut = [UIAlertAction actionWithTitle:@"Leave Out" style:UIAlertActionStyleDefault
                                                     handler:^(UIAlertAction *a) { share(NO); }];
    [alert addAction:leaveOut];
    [alert addAction:[UIAlertAction actionWithTitle:@"Include" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { share(YES); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    alert.preferredAction = leaveOut;
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)shareCurrent:(PSSpecifier *)specifier {
    [self askForName:@"My Setup" title:@"Share Current Settings" button:@"Share" use:^NSString *(NSString *name) {
        NSString *problem = TPRSetupNameProblem(name);
        if (!problem)   // after this alert is gone
            dispatch_async(dispatch_get_main_queue(), ^{
                [self shareSettings:TPRSetupCurrentSettings()
                               name:[name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]];
            });
        return problem;
    }];
}

// ---- import -----------------------------------------------------------------------

- (void)importFromClipboard:(PSSpecifier *)specifier {
    NSString *text = UIPasteboard.generalPasteboard.string;
    if (!text.length) {
        [self showMessage:@"Copy a shared TopRow setup first (it starts with “TopRow setup:”), then allow pasting if iOS asks."
                    title:@"Nothing to Paste"];
        return;
    }
    [self importText:text];
}

- (void)importFromFile:(PSSpecifier *)specifier {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
                                              initForOpeningContentTypes:@[ UTTypePlainText, UTTypeText ] asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.firstObject) [self importFileAtPath:urls.firstObject.path];
}

- (void)importFileAtPath:(NSString *)path {
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:NULL];
    NSString *text = attributes.fileSize <= kMaxImportBytes
                   ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL] : nil;
    if (!text) {
        [self showMessage:@"TopRow can only import a setup's text file." title:@"Can't Import"];
        return;
    }
    [self importText:text];
}

- (void)importText:(NSString *)text {
    NSString *name = nil;
    NSArray *problems = nil;
    NSDictionary *settings = text.length <= kMaxImportBytes ? TPRSetupParse(text, &name, &problems) : nil;
    if (!settings) {
        [self showMessage:@"That isn't a TopRow setup. Copy all of it, starting with the line “TopRow setup:”."
                    title:@"Can't Import"];
        return;
    }
    NSMutableString *message = [Summary(settings, @"Every setting at its default.") mutableCopy];
    if (problems.count) [message appendFormat:@"\n\nSkipped:\n%@", [problems componentsJoinedByString:@"\n"]];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Import “%@”?", name]
                                                                   message:message preferredStyle:UIAlertControllerStyleAlert];
    void (^save)(BOOL) = ^(BOOL apply) {
        NSString *problem = TPRSetupsSave(TPRSetupsUniqueName(name), settings);
        if (problem) {
            [self showMessage:problem title:@"Not Saved"];
            return;
        }
        if (apply) [self applySetup:TPRSetupsSaved().firstObject[@"ID"]];
        else [self reloadSpecifiers];
    };
    UIAlertAction *saveOnly = [UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { save(NO); }];
    [alert addAction:saveOnly];
    [alert addAction:[UIAlertAction actionWithTitle:@"Save and Apply" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { save(YES); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    alert.preferredAction = saveOnly;
    [self presentViewController:alert animated:YES completion:nil];
}

@end
