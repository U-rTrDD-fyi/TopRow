#import "TPRBaseListController.h"
#import "TPRPrefsStore.h"
#import "../TPRPaths.h"
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
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

// Last `lines` lines of the shared TopRow log (and its rotated predecessor).
static NSString *LogFileTail(NSUInteger lines) {
    NSString *path = TPRRootPath(@"/var/mobile/Library/Logs/TopRow/TopRow.log");
    NSMutableString *text = [NSMutableString string];
    for (NSString *p in @[ [path stringByAppendingString:@".1"], path ]) {
        NSString *part = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:NULL];
        if (part) [text appendString:part];
    }
    if (!text.length) return @"(empty or unreadable)";
    NSArray *all = [text componentsSeparatedByString:@"\n"];
    NSRange keep = NSMakeRange(all.count > lines ? all.count - lines : 0, MIN(all.count, lines));
    return [[all subarrayWithRange:keep] componentsJoinedByString:@"\n"];
}

static NSSet<NSString *> *TopRowUUIDs(void);
static NSString *TopRowOnStack(NSString *ips, NSSet<NSString *> *ourUUIDs, NSString **summary);

// iOS crash and hang reports (.ips) from the last few days. TopRow is loaded into almost
// every app, so a report only counts if TopRow is on a thread's stack (the crashed or stuck
// code). Those get a summary of the threads TopRow is on, and the full report too when
// it isn't huge (hang stackshots cover every process); the rest are just listed.
static NSString *CrashReports(void) {
    NSMutableString *out = [NSMutableString stringWithString:@"Crash and hang reports (last 3 days):\n"];
    NSString *dir = @"/var/mobile/Library/Logs/CrashReporter";
    NSFileManager *files = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSError *error;
    for (NSString *sub in @[ @"", @"Retired" ]) {
        NSString *d = [dir stringByAppendingPathComponent:sub];
        NSArray *names = [files contentsOfDirectoryAtPath:d error:sub.length ? NULL : &error];
        for (NSString *n in names)
            if ([n.pathExtension isEqualToString:@"ips"]) [paths addObject:[d stringByAppendingPathComponent:n]];
    }
    if (error && !paths.count) return [out stringByAppendingFormat:@"(can't read %@: %@)\n", dir, error.localizedDescription];
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-3 * 86400];
    NSSet *ourUUIDs = TopRowUUIDs();
    NSMutableArray *recent = [NSMutableArray array];
    for (NSString *p in paths) {
        NSDate *date = [files attributesOfItemAtPath:p error:NULL].fileModificationDate;
        if (date && [date compare:cutoff] == NSOrderedDescending) [recent addObject:@[ date, p ]];
    }
    [recent sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { return [b[0] compare:a[0]]; }];
    NSMutableArray<NSString *> *full = [NSMutableArray array], *listed = [NSMutableArray array];
    for (NSArray *entry in recent) {
        NSString *p = entry[1];
        NSString *body = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:NULL];
        NSString *summary = nil;
        NSString *verdict = body ? TopRowOnStack(body, ourUUIDs, &summary) : @"unreadable";
        NSString *row = [NSString stringWithFormat:@"- %@ (%@)", p.lastPathComponent, verdict];
        if (summary) row = [row stringByAppendingFormat:@"\n%@", summary];
        if (summary && full.count < 3 && body.length < 600000)
            [full addObject:[NSString stringWithFormat:@"- %@\n%@", p.lastPathComponent, body]];
        [listed addObject:row];
    }
    if (!recent.count) [out appendString:@"(none)\n"];
    if (listed.count) [out appendFormat:@"%@\n", [listed componentsJoinedByString:@"\n"]];
    for (NSString *f in full) [out appendFormat:@"\n===== %@\n", f];
    return out;
}

// Whether TopRow.dylib appears in any thread's frames of an .ips report (crash: usedImages +
// threads; hang/stackshot: per-process images + thread frames). Falls back to a text check.
// UUIDs (lowercase) of TopRow builds; hang reports name images only by UUID. The loaded build,
// every build that logged "uuid ..." since the log began (1.0.1 on), and the 1.0.0 builds
// (APT and GitHub releases, arm64 and arm64e), which didn't log it.
static NSSet<NSString *> *TopRowUUIDs(void) {
    NSMutableSet *uuids = [NSMutableSet setWithArray:@[
        @"f54c0697-cc19-3c01-88d5-6f62489fce3d", @"adcb2a9f-92dc-3379-9978-78151f55325c",
        @"fe37dbdb-cbde-33e8-99c1-28276134f7b2", @"034312cc-94aa-3429-b48b-f62013f7cfed" ]];
    NSString *log = LogFileTail(NSUIntegerMax);
    NSRegularExpression *logged = [NSRegularExpression regularExpressionWithPattern:@"uuid ([0-9A-F-]{36})" options:0 error:NULL];
    for (NSTextCheckingResult *m in [logged matchesInString:log options:0 range:NSMakeRange(0, log.length)])
        [uuids addObject:[[log substringWithRange:[m rangeAtIndex:1]] lowercaseString]];
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name || !strstr(name, "/TopRow.dylib")) continue;
        const struct mach_header_64 *mh = (const struct mach_header_64 *)_dyld_get_image_header(i);
        const struct load_command *lc = (const struct load_command *)(mh + 1);
        for (uint32_t c = 0; c < mh->ncmds; c++, lc = (const struct load_command *)((const char *)lc + lc->cmdsize))
            if (lc->cmd == LC_UUID)
                [uuids addObject:[[[NSUUID alloc] initWithUUIDBytes:((const struct uuid_command *)lc)->uuid].UUIDString lowercaseString]];
    }
    return uuids;
}

static NSString *TopRowOnStack(NSString *ips, NSSet<NSString *> *ourUUIDs, NSString **summary) {
    NSRange split = [ips rangeOfString:@"\n"];
    NSData *json = split.location == NSNotFound ? nil : [[ips substringFromIndex:NSMaxRange(split)] dataUsingEncoding:NSUTF8StringEncoding];
    id root = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:NULL] : nil;
    BOOL mentioned = [ips containsString:@"TopRow"];
    NSString *lower = ips.lowercaseString;
    for (NSString *u in ourUUIDs) mentioned = mentioned || [lower containsString:u];
    if (!mentioned) return @"TopRow not loaded";
    if (![root isKindOfClass:[NSDictionary class]]) return @"TopRow loaded; stack not parsed";
    // The threads with TopRow on them, one frame per line: enough to read a report too
    // large to include in full (hang stackshots cover every process).
    NSMutableString *threadsText = [NSMutableString string];
    // TopRow's image indexes: crash reports name images ({name, path, uuid}); hang
    // stackshots list them as [uuid, loadAddress, ...]. Frames are {imageIndex, ...} or [index, offset].
    void (^scan)(id, NSArray *, NSString *) = ^(id threads, NSArray *images, NSString *process) {
        NSMutableIndexSet *ours = [NSMutableIndexSet indexSet];
        NSMutableArray *labels = [NSMutableArray array];
        [images enumerateObjectsUsingBlock:^(id img, NSUInteger i, BOOL *stop) {
            NSString *name = nil, *uuid = nil;
            if ([img isKindOfClass:[NSDictionary class]]) { name = img[@"name"] ?: img[@"path"]; uuid = img[@"uuid"]; }
            else if ([img isKindOfClass:[NSArray class]] && [img count]) uuid = [img[0] description];
            if (![name isKindOfClass:[NSString class]]) name = nil;
            if (![uuid isKindOfClass:[NSString class]]) uuid = nil;
            BOOL ourImage = [name containsString:@"TopRow"] || [ourUUIDs containsObject:uuid.lowercaseString];
            if (ourImage) [ours addIndex:i];
            [labels addObject:ourImage ? [NSString stringWithFormat:@"TopRow(%@)", uuid ?: name] : name ?: uuid ?: @"?"];
        }];
        NSDictionary *byID = [threads isKindOfClass:[NSDictionary class]] ? threads : nil;
        NSArray *list = byID ? byID.allKeys : [threads isKindOfClass:[NSArray class]] ? threads : @[];
        for (id key in list) {
            id t = byID ? byID[key] : key;
            NSArray *frames = [t isKindOfClass:[NSDictionary class]] ? (t[@"frames"] ?: t[@"userFrames"]) : nil;
            NSMutableString *text = [NSMutableString string];
            BOOL hit = NO;
            for (id f in [frames isKindOfClass:[NSArray class]] ? frames : @[]) {
                BOOL dict = [f isKindOfClass:[NSDictionary class]], pair = [f isKindOfClass:[NSArray class]] && [f count] > 1;
                id index = dict ? f[@"imageIndex"] : pair ? f[0] : nil;
                id offset = dict ? f[@"imageOffset"] : pair ? f[1] : nil;
                if (![index isKindOfClass:[NSNumber class]]) continue;
                NSUInteger i = [index unsignedIntegerValue];
                if ([ours containsIndex:i]) hit = YES;
                NSString *symbol = dict && [f[@"symbol"] isKindOfClass:[NSString class]] ? f[@"symbol"] : @"";
                [text appendFormat:@"    %@ +0x%llx %@\n", i < labels.count ? labels[i] : @"?",
                                   [offset isKindOfClass:[NSNumber class]] ? [offset unsignedLongLongValue] : 0ULL, symbol];
            }
            if (!hit) continue;
            [threadsText appendFormat:@"  %@thread %@:\n%@", process ? [process stringByAppendingString:@" "] : @"",
                                      byID ? key : t[@"id"] ?: @"?", text];
        }
    };
    NSDictionary *r = root;
    if (r[@"threads"]) scan(r[@"threads"], r[@"usedImages"], nil);
    // Stackshot (hangs): stackshot -> processByPid -> { threadById, ... } with a shared binaryImages list.
    NSDictionary *shot = [r[@"stackshot"] isKindOfClass:[NSDictionary class]] ? r[@"stackshot"] : r;
    NSDictionary *procs = [shot[@"processByPid"] isKindOfClass:[NSDictionary class]] ? shot[@"processByPid"] : nil;
    for (NSString *pid in procs) {
        NSDictionary *proc = procs[pid];
        if ([proc isKindOfClass:[NSDictionary class]])
            scan(proc[@"threadById"], shot[@"binaryImages"], [NSString stringWithFormat:@"%@[%@]", proc[@"procname"] ?: @"?", pid]);
    }
    if (!threadsText.length) return @"TopRow loaded, not on stack";
    if (summary) {
        id why = r[@"termination"] ?: r[@"exception"];
        *summary = [NSString stringWithFormat:@"%@%@", why ? [NSString stringWithFormat:@"  reason: %@\n", why] : @"", threadsText];
    }
    return @"TopRow on stack";
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
    [report appendString:@"\n\nTopRow log (all processes that could write it):\n"];
    [report appendString:LogFileTail(300)];
    [report appendString:@"\n\n"];
    [report appendString:CrashReports()];

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
