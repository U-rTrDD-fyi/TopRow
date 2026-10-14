#import "TPRSetups.h"
#import "TPRPrefsStore.h"
#import "../TPRPaths.h"
#import "../TPRKeyRows.h"

NSString *const TPRSetupsChangedNotification = @"dev.rtrdd.toprow/setups";
static NSData *lastWritten;

// ---- the settings a setup holds -------------------------------------------------

typedef NS_ENUM(NSInteger, TPRSettingKind) {
    TPRSettingRow,            // top row: 0-10 keys, empty = no row on that plane
    TPRSettingLandscapeRow,   // 0-10 keys, empty = same as portrait
    TPRSettingKeyRow,         // Keys page: 1-12 keys, empty = Apple's row
    TPRSettingSwitch,
    TPRSettingPercent,
    TPRSettingLabel,          // up to 5 characters, empty = Apple's label
    TPRSettingApps,           // bundle IDs
};

// @[key, label (as shared), kind, default] in Settings order; Keys rows add plane and row.
static NSArray<NSArray *> *Specs(void) {
    static NSArray *specs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *top = @"1 2 3 4 5 6 7 8 9 0", *symbols = @"! @ # $ % ^ & * ( )";
        NSMutableArray *list = [@[
            @[ @"LowercaseRow", @"Top Row Lowercase", @(TPRSettingRow), top ],
            @[ @"ShiftedRow", @"Top Row Shift / Caps", @(TPRSettingRow), symbols ],
            @[ @"NumbersRow", @"Top Row 123 / #+=", @(TPRSettingRow), symbols ],
            @[ @"SymbolHints", @"Show Symbol Hints", @(TPRSettingSwitch), @NO ],
            @[ @"LowercaseRowWhenAutoShifted", @"Lowercase Row When Auto-Capitalized", @(TPRSettingSwitch), @NO ],
            @[ @"ShowInLandscape", @"Show in Landscape", @(TPRSettingSwitch), @YES ],
            @[ @"LandscapeLowercaseRow", @"Landscape Lowercase", @(TPRSettingLandscapeRow), @"" ],
            @[ @"LandscapeShiftedRow", @"Landscape Shift / Caps", @(TPRSettingLandscapeRow), @"" ],
            @[ @"LandscapeNumbersRow", @"Landscape 123 / #+=", @(TPRSettingLandscapeRow), @"" ],
        ] mutableCopy];
        NSArray *planes = @[ @"Letters", @"Shift", @"123", @"#+=" ];
        for (TPRKeyPlane p = 0; p < TPRKeyPlaneCount; p++)
            for (NSUInteger r = 0; r < TPRKeyRowCount; r++)
                [list addObject:@[ TPRKeyRowPrefsKey(p, r), [NSString stringWithFormat:@"%@ Row %lu", planes[p], (unsigned long)r + 1],
                                   @(TPRSettingKeyRow), @"", @(p), @(r) ]];
        [list addObjectsFromArray:@[
            @[ @"Label123", @"123 Key", @(TPRSettingLabel), @"" ],
            @[ @"LabelABC", @"ABC Key", @(TPRSettingLabel), @"" ],
            @[ @"LabelSymbols", @"#+= Key", @(TPRSettingLabel), @"" ],
            @[ @"KeyHeight", @"Key Height", @(TPRSettingPercent), @100 ],
            @[ @"BottomAreaHeight", @"Bottom Area", @(TPRSettingPercent), @100 ],
            @[ @"RowOnEmail", @"Use on Email Fields", @(TPRSettingSwitch), @YES ],
            @[ @"RowOnWeb", @"Use on Web Addresses & Search", @(TPRSettingSwitch), @YES ],
            @[ @"RowOnTwitter", @"Use on Twitter Fields", @(TPRSettingSwitch), @YES ],
            @[ @"ExcludedApps", @"Excluded Apps", @(TPRSettingApps), @[] ],
        ]];
        specs = list;
    });
    return specs;
}

static NSString *Joined(NSString *text) {
    return [TPRSplitKeys(text) componentsJoinedByString:@" "];
}

// The value as stored, or why it can't be. Accepts what the prefs file holds and what the
// shared text says ("On", "95%", "com.a, com.b").
static id Canonical(NSArray *spec, id value, NSString **problem) {
    TPRSettingKind kind = [spec[2] integerValue];
    NSString *text = [value isKindOfClass:[NSString class]] ? value : nil;
    switch (kind) {
    case TPRSettingRow:
    case TPRSettingLandscapeRow:
    case TPRSettingKeyRow:
        if (!text) break;
        *problem = kind == TPRSettingKeyRow ? TPRPrefsKeyRowProblem(text) : TPRPrefsRowProblem(text);
        return *problem ? nil : Joined(text);
    case TPRSettingSwitch: {
        if ([value isKindOfClass:[NSNumber class]]) return @([value boolValue]);
        NSString *word = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].lowercaseString;
        if ([@[ @"on", @"yes", @"true", @"1" ] containsObject:word ?: @""]) return @YES;
        if ([@[ @"off", @"no", @"false", @"0" ] containsObject:word ?: @""]) return @NO;
        *problem = @"Use On or Off.";
        return nil;
    }
    case TPRSettingPercent: {
        if (text) value = [[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
                           stringByReplacingOccurrencesOfString:@"%" withString:@""];
        NSNumber *number = nil;
        *problem = TPRPrefsSizeProblem(spec[0], value, &number);
        return number;
    }
    case TPRSettingLabel: {
        if (!text) break;
        NSString *label = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (TPRPrefsCharacterCount(label) <= 5) return label;
        *problem = @"Labels can be at most 5 characters.";
        return nil;
    }
    case TPRSettingApps: {
        NSArray *items = [value isKindOfClass:[NSArray class]] ? value
                       : [text componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@", \t"]];
        if (!items) break;
        NSCharacterSet *bad = [[NSCharacterSet characterSetWithCharactersInString:
                                @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-_"] invertedSet];
        NSMutableOrderedSet *apps = [NSMutableOrderedSet orderedSet];
        for (id item in items) {
            if (![item isKindOfClass:[NSString class]] || ![item length]) continue;
            if ([item rangeOfCharacterFromSet:bad].location != NSNotFound || [item length] > 255) {
                *problem = [NSString stringWithFormat:@"\"%@\" isn't an app ID.", item];
                return nil;
            }
            [apps addObject:item];
        }
        return apps.array;
    }
    }
    *problem = @"Not a valid value.";
    return nil;
}

// What the keyboard shows for a Keys row with nothing stored: Shift rows follow the letters.
static NSString *DefaultKeyRow(NSArray *spec, NSDictionary *settings) {
    TPRKeyPlane plane = [spec[4] integerValue];
    NSUInteger row = [spec[5] unsignedIntegerValue];
    NSString *letters = settings[TPRKeyRowPrefsKey(TPRKeyPlaneLetters, row)];
    if (plane == TPRKeyPlaneShifted && letters.length) return letters.uppercaseString;
    return TPRStockKeyRow(plane, row);
}

static BOOL IsDefault(NSArray *spec, id value, NSDictionary *settings) {
    switch ((TPRSettingKind)[spec[2] integerValue]) {
    case TPRSettingKeyRow: return ![value length] || [value isEqualToString:DefaultKeyRow(spec, settings)];
    case TPRSettingLandscapeRow:
    case TPRSettingLabel: return ![value length];
    case TPRSettingApps: return ![value count];
    default: return [value isEqual:spec[3]];
    }
}

// Only the valid values that differ from the defaults, canonical. Invalid ones are dropped
// (*problems says which); keys that aren't settings (Enabled, old leftovers) too.
static NSDictionary *Normalized(NSDictionary *input, NSMutableArray<NSString *> *problems) {
    NSMutableDictionary *settings = [NSMutableDictionary dictionary];
    for (NSArray *spec in Specs()) {   // letters before Shift: a Shift row's default depends on them
        id raw = input[spec[0]];
        if (!raw) continue;
        NSString *problem = nil;
        id value = Canonical(spec, raw, &problem);
        if (!value) {
            [problems addObject:[NSString stringWithFormat:@"%@: %@", spec[1], problem]];
            continue;
        }
        if (!IsDefault(spec, value, settings)) settings[spec[0]] = value;
    }
    return settings;
}

NSDictionary *TPRSetupCurrentSettings(void) {
    NSMutableDictionary *settings = [Normalized(TPRPrefsRead(), nil) mutableCopy];
    if (!settings[@"ExcludedApps"]) settings[@"ExcludedApps"] = @[];
    return settings;
}

// ---- the setups file ------------------------------------------------------------

NSData *TPRSetupsFileData(void) {
    return [NSData dataWithContentsOfFile:TPRSetupsFile] ?: [NSData data];
}

NSData *TPRSetupsLastWrittenData(void) {
    return lastWritten;
}

static NSDictionary *ReadFile(void) {
    NSData *data = [NSData dataWithContentsOfFile:TPRSetupsFile];
    id file = data ? [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL] : nil;
    return [file isKindOfClass:[NSDictionary class]] ? file : @{};
}

static void WriteFile(NSDictionary *file) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:file format:NSPropertyListXMLFormat_v1_0
                                                             options:0 error:NULL];
    if (![data writeToFile:TPRSetupsFile atomically:YES]) {
        NSLog(@"[TopRow] failed to write %@", TPRSetupsFile);
        return;
    }
    lastWritten = data;
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)TPRSetupsChangedNotification, NULL, NULL, true);
}

static NSArray<NSDictionary *> *List(NSDictionary *file, NSString *name) {
    NSMutableArray *list = [NSMutableArray array];
    for (id setup in [file[name] isKindOfClass:[NSArray class]] ? file[name] : @[])
        if ([setup isKindOfClass:[NSDictionary class]] && [setup[@"ID"] isKindOfClass:[NSString class]] &&
            [setup[@"Name"] isKindOfClass:[NSString class]] && [setup[@"Settings"] isKindOfClass:[NSDictionary class]])
            [list addObject:setup];
    return list;
}

NSArray<NSDictionary *> *TPRSetupsSaved(void) {
    return List(ReadFile(), @"Setups");
}

NSArray<NSDictionary *> *TPRSetupsBackups(void) {
    return List(ReadFile(), @"Backups");
}

NSDictionary *TPRSetupWithID(NSString *setupID) {
    NSDictionary *file = ReadFile();
    for (NSDictionary *setup in [List(file, @"Setups") arrayByAddingObjectsFromArray:List(file, @"Backups")])
        if ([setup[@"ID"] isEqualToString:setupID]) return setup;
    return nil;
}

BOOL TPRSetupIsBackup(NSString *setupID) {
    for (NSDictionary *setup in TPRSetupsBackups())
        if ([setup[@"ID"] isEqualToString:setupID]) return YES;
    return NO;
}

static NSString *Trimmed(NSString *name) {
    return [name isKindOfClass:[NSString class]]
         ? [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : @"";
}

NSString *TPRSetupNameProblem(NSString *name) {
    name = Trimmed(name);
    if (!name.length) return @"Enter a name.";
    if (TPRPrefsCharacterCount(name) > TPRMaxSetupNameLength)
        return [NSString stringWithFormat:@"Names can be at most %d characters.", TPRMaxSetupNameLength];
    return nil;
}

// The saved setup (other than `exceptID`) that already has this name, ignoring case.
static NSDictionary *Named(NSArray *saved, NSString *name, NSString *exceptID) {
    for (NSDictionary *setup in saved)
        if ([setup[@"Name"] caseInsensitiveCompare:name] == NSOrderedSame && ![setup[@"ID"] isEqualToString:exceptID])
            return setup;
    return nil;
}

NSString *TPRSetupsSave(NSString *name, NSDictionary *settings) {
    name = Trimmed(name);
    NSString *problem = TPRSetupNameProblem(name);
    if (problem) return problem;
    NSMutableDictionary *file = [ReadFile() mutableCopy];
    NSMutableArray *saved = [List(file, @"Setups") mutableCopy];
    if (Named(saved, name, nil)) return [NSString stringWithFormat:@"You already have a setup named “%@”.", name];
    if (saved.count >= TPRMaxSetups)
        return [NSString stringWithFormat:@"You have %d setups, the most TopRow keeps. Delete one first.", TPRMaxSetups];
    NSMutableDictionary *kept = [Normalized(settings, nil) mutableCopy];
    if ([settings[@"ExcludedApps"] isKindOfClass:[NSArray class]] && !kept[@"ExcludedApps"]) kept[@"ExcludedApps"] = @[];
    [saved insertObject:@{ @"ID": NSUUID.UUID.UUIDString, @"Name": name, @"Date": NSDate.date, @"Settings": kept } atIndex:0];
    file[@"Setups"] = saved;
    WriteFile(file);
    return nil;
}

NSString *TPRSetupsRename(NSString *setupID, NSString *name) {
    name = Trimmed(name);
    NSString *problem = TPRSetupNameProblem(name);
    if (problem) return problem;
    NSMutableDictionary *file = [ReadFile() mutableCopy];
    NSMutableArray *saved = [List(file, @"Setups") mutableCopy];
    if (Named(saved, name, setupID)) return [NSString stringWithFormat:@"You already have a setup named “%@”.", name];
    for (NSUInteger i = 0; i < saved.count; i++) {
        if (![saved[i][@"ID"] isEqualToString:setupID]) continue;
        NSMutableDictionary *setup = [saved[i] mutableCopy];
        setup[@"Name"] = name;
        saved[i] = setup;
        file[@"Setups"] = saved;
        WriteFile(file);
        return nil;
    }
    return @"That setup no longer exists.";
}

void TPRSetupsDelete(NSString *setupID) {
    NSMutableDictionary *file = [ReadFile() mutableCopy];
    for (NSString *list in @[ @"Setups", @"Backups" ]) {
        NSMutableArray *setups = [List(file, list) mutableCopy];
        [setups filterUsingPredicate:[NSPredicate predicateWithFormat:@"ID != %@", setupID]];
        file[list] = setups;
    }
    WriteFile(file);
}

NSString *TPRSetupsSuggestedName(void) {
    NSArray *saved = TPRSetupsSaved();
    for (NSUInteger n = saved.count + 1;; n++) {
        NSString *name = [NSString stringWithFormat:@"Setup %lu", (unsigned long)n];
        if (!Named(saved, name, nil)) return name;
    }
}

NSString *TPRSetupsUniqueName(NSString *name) {
    name = Trimmed(name);
    NSArray *saved = TPRSetupsSaved();
    if (!Named(saved, name, nil)) return name;
    for (NSUInteger n = 2;; n++) {
        NSString *suffix = [NSString stringWithFormat:@" %lu", (unsigned long)n];
        NSString *base = name;
        while (base.length && TPRPrefsCharacterCount(base) + suffix.length > TPRMaxSetupNameLength)
            base = [base substringToIndex:[base rangeOfComposedCharacterSequenceAtIndex:base.length - 1].location];
        NSString *candidate = [Trimmed(base) stringByAppendingString:suffix];
        if (!Named(saved, candidate, nil)) return candidate;
    }
}

BOOL TPRSetupsBackUp(NSString *reason) {
    NSDictionary *settings = TPRSetupCurrentSettings();
    if (!Normalized(settings, nil).count) return NO;   // all defaults: Reset to Defaults brings that back
    NSMutableDictionary *file = [ReadFile() mutableCopy];
    NSMutableArray *backups = [List(file, @"Backups") mutableCopy];
    if ([backups.firstObject[@"Settings"] isEqual:settings]) return NO;
    [backups insertObject:@{ @"ID": NSUUID.UUID.UUIDString, @"Name": reason, @"Date": NSDate.date, @"Settings": settings }
                  atIndex:0];
    while (backups.count > TPRMaxBackups) [backups removeLastObject];
    file[@"Backups"] = backups;
    WriteFile(file);
    return YES;
}

BOOL TPRSetupApply(NSDictionary *setup, NSString *backupReason) {
    NSDictionary *settings = [setup[@"Settings"] isKindOfClass:[NSDictionary class]] ? setup[@"Settings"] : @{};
    BOOL backedUp = TPRSetupsBackUp(backupReason);
    NSDictionary *current = TPRPrefsRead();
    NSMutableDictionary *prefs = [Normalized(settings, nil) mutableCopy];
    if (current[@"Enabled"]) prefs[@"Enabled"] = current[@"Enabled"];
    if (!settings[@"ExcludedApps"] && current[@"ExcludedApps"]) prefs[@"ExcludedApps"] = current[@"ExcludedApps"];
    TPRPrefsReplace(prefs);
    return backedUp;
}

BOOL TPRSetupsFlag(NSString *flag) {
    id flags = ReadFile()[@"Flags"];
    return [flags isKindOfClass:[NSDictionary class]] && [flags[flag] boolValue];
}

void TPRSetupsSetFlag(NSString *flag) {
    if (TPRSetupsFlag(flag)) return;
    NSMutableDictionary *file = [ReadFile() mutableCopy];
    NSMutableDictionary *flags = [file[@"Flags"] isKindOfClass:[NSDictionary class]] ? [file[@"Flags"] mutableCopy]
                                                                                       : [NSMutableDictionary dictionary];
    flags[flag] = @YES;
    file[@"Flags"] = flags;
    WriteFile(file);
}

// ---- sharing --------------------------------------------------------------------

static NSString *const kHeader = @"TopRow setup";

NSArray<NSString *> *TPRSetupLines(NSDictionary *settings, BOOL includeExcludedApps) {
    NSDictionary *values = Normalized(settings, nil);
    NSMutableArray *lines = [NSMutableArray array];
    for (NSArray *spec in Specs()) {
        id value = values[spec[0]];
        if (!value) continue;
        switch ((TPRSettingKind)[spec[2] integerValue]) {
        case TPRSettingSwitch: value = [value boolValue] ? @"On" : @"Off"; break;
        case TPRSettingPercent: value = [NSString stringWithFormat:@"%@%%", value]; break;
        case TPRSettingApps:
            if (!includeExcludedApps) continue;
            value = [value componentsJoinedByString:@", "];
            break;
        default: break;
        }
        // An empty top row ("no row on that plane") is just the label and its colon.
        [lines addObject:[value length] ? [NSString stringWithFormat:@"%@: %@", spec[1], value]
                                        : [NSString stringWithFormat:@"%@:", spec[1]]];
    }
    return lines;
}

NSString *TPRSetupText(NSString *name, NSDictionary *settings, BOOL includeExcludedApps) {
    NSArray *lines = TPRSetupLines(settings, includeExcludedApps);
    // The note has no colon, so reading the text back skips it.
    NSString *note = [NSString stringWithFormat:@"Made with TopRow %s. Anything not listed uses its default.", TPR_VERSION];
    if (!lines.count) note = [NSString stringWithFormat:@"Made with TopRow %s. Every setting is at its default.", TPR_VERSION];
    return [NSString stringWithFormat:@"%@: %@\n%@\n\n%@\n", kHeader, Trimmed(name), note,
            [lines componentsJoinedByString:@"\n"]];
}

NSDictionary *TPRSetupParse(NSString *text, NSString **name, NSArray<NSString *> **problems) {
    NSMutableDictionary *byLabel = [NSMutableDictionary dictionary];
    for (NSArray *spec in Specs()) {
        byLabel[[spec[1] lowercaseString]] = spec;
        byLabel[[spec[0] lowercaseString]] = spec;   // the prefs key works too
    }
    NSString *title = nil;
    BOOL header = NO;
    NSMutableDictionary *raw = [NSMutableDictionary dictionary];
    NSMutableArray *skipped = [NSMutableArray array];
    for (NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *t = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSRange colon = [t rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;
        NSString *label = Trimmed([t substringToIndex:colon.location]);
        NSString *value = Trimmed([t substringFromIndex:NSMaxRange(colon)]);
        if ([label caseInsensitiveCompare:kHeader] == NSOrderedSame) {
            header = YES;
            title = value;
            continue;
        }
        NSArray *spec = byLabel[label.lowercaseString];
        if (!spec) {
            // Other text around a pasted setup is fine; inside one it's worth mentioning.
            if (header) [skipped addObject:[NSString stringWithFormat:@"%@: not a TopRow setting", label]];
            continue;
        }
        raw[spec[0]] = value;
    }
    if (!header && !raw.count) return nil;
    NSDictionary *settings = Normalized(raw, skipped);
    if (name) {
        NSString *n = Trimmed(title);
        while (TPRPrefsCharacterCount(n) > TPRMaxSetupNameLength)
            n = [n substringToIndex:[n rangeOfComposedCharacterSequenceAtIndex:n.length - 1].location];
        *name = Trimmed(n).length ? Trimmed(n) : @"Imported Setup";
    }
    if (problems) *problems = skipped;
    return settings;
}
