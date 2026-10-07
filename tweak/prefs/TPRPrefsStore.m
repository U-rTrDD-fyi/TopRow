#import "TPRPrefsStore.h"
#import "../TPRPaths.h"

static NSString *const kReloadNotification = @"dev.rtrdd.toprow/reload";

// Coalesced: a slider drag writes many values; the keyboard reloads once it settles.
static void PostReload(void) {
    static NSUInteger pending;
    NSUInteger mine = ++pending;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (mine != pending) return;
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             (__bridge CFStringRef)kReloadNotification, NULL, NULL, true);
    });
}

NSDictionary *TPRPrefsRead(void) {
    NSData *data = [NSData dataWithContentsOfFile:TPRPrefsFile];
    id prefs = data ? [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL] : nil;
    return [prefs isKindOfClass:[NSDictionary class]] ? prefs : @{};
}

void TPRPrefsSet(NSString *key, id value) {
    if (!key) return;
    NSMutableDictionary *prefs = [TPRPrefsRead() mutableCopy];
    if (value) prefs[key] = value;
    else [prefs removeObjectForKey:key];
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:prefs format:NSPropertyListXMLFormat_v1_0
                                                             options:0 error:NULL];
    if ([data writeToFile:TPRPrefsFile atomically:YES]) PostReload();
    else NSLog(@"[TopRow] failed to write %@", TPRPrefsFile);
}

void TPRPrefsReset(void) {
    [[NSFileManager defaultManager] removeItemAtPath:TPRPrefsFile error:NULL];
    PostReload();
}

NSUInteger TPRPrefsCharacterCount(NSString *text) {
    __block NSUInteger count = 0;
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length) options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *s, NSRange r, NSRange e, BOOL *stop) { count++; }];
    return count;
}

NSString *TPRPrefsRowProblem(NSString *text) {
    NSUInteger count = 0;
    for (NSString *part in [text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]) {
        if (!part.length) continue;
        if (TPRPrefsCharacterCount(part) > 8) return [NSString stringWithFormat:@"\"%@\" is longer than 8 characters.", part];
        count++;
    }
    return count > 10 ? @"A row can have at most 10 keys." : nil;
}

NSRange TPRPrefsSizeRange(NSString *key) {
    if ([key isEqualToString:@"KeyHeight"]) return NSMakeRange(80, 50);
    if ([key isEqualToString:@"BottomAreaHeight"]) return NSMakeRange(60, 70);
    return NSMakeRange(0, 0);
}

NSString *TPRPrefsSizeProblem(NSString *key, id value, NSNumber **number) {
    NSRange range = TPRPrefsSizeRange(key);
    double percent;
    if ([value isKindOfClass:[NSNumber class]]) {
        percent = [value doubleValue];
    } else {
        NSScanner *scanner = [NSScanner scannerWithString:[value description] ?: @""];
        NSInteger whole;
        if (![scanner scanInteger:&whole] || !scanner.isAtEnd) return @"Enter a whole number, like 95.";
        percent = whole;
    }
    percent = round(percent);
    if (percent < range.location || percent > NSMaxRange(range))
        return [NSString stringWithFormat:@"Enter a value from %lu to %lu.", (unsigned long)range.location,
                (unsigned long)NSMaxRange(range)];
    *number = @(percent);
    return nil;
}
