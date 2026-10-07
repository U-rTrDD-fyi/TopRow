// TopRow — adds a number/symbol row to the stock iOS keyboard.
//
// Injection point: -[TUIKBGraphSerialization keyboardForName:]
// returns the UIKBTree a keyboard is built from. We hand back a patched copy
// with one extra row. The cacheIdentifierForKeyplaneNamed: suffix only keys
// UIKeyboardLayoutStar's in-memory keyplane-view map; rendered keyplane images
// are keyed by UIKBCacheToken_Keyplane (plane name, frame, keyset/geometry set
// names; not labels), so the patcher folds the config fingerprint into the
// keyset/geometry-set names.

#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "TPRConfig.h"
#import "TPRPaths.h"
#import "TPRPatcher.h"
#import "TPRTree.h"

// Logs to the system log and keeps the last few lines in memory for the Settings
// pane's "Share Diagnostics" (plain text, by design).
static NSMutableArray<NSString *> *gRecentLog;

static void TPRRecord(NSString *line) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gRecentLog = [NSMutableArray array]; });
    NSString *entry = [NSString stringWithFormat:@"%@ %@", [NSDate date], line];
    @synchronized(gRecentLog) {
        [gRecentLog addObject:entry];
        if (gRecentLog.count > 40) [gRecentLog removeObjectAtIndex:0];
    }
}

// Looked up with dlsym by the Settings pane (same process).
__attribute__((visibility("default"))) NSArray<NSString *> *TPRRecentLog(void) {
    if (!gRecentLog) return @[];
    @synchronized(gRecentLog) { return [gRecentLog copy]; }
}

#define TPRLog(fmt, ...) do { NSString *_l = [NSString stringWithFormat:fmt, ##__VA_ARGS__]; \
    NSLog(@"[TopRow] %@", _l); TPRRecord(_l); } while (0)


static id (*orig_keyboardForName)(id, SEL, NSString *);
static id (*orig_cacheIdentifierForKeyplaneNamed)(id, SEL, NSString *);

static id hook_keyboardForName(id self, SEL _cmd, NSString *name) {
    id keyboard = orig_keyboardForName(self, _cmd, name);
    if (!keyboard) return keyboard;
#if TPR_SIMULATOR
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"tpr-raw"];
    NSString *path = [dir stringByAppendingPathComponent:[name stringByAppendingString:@".txt"]];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path])
        [TPRDescribeTree(keyboard) writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    TPRLog(@"keyboardForName:%@ returned %p", name, keyboard);
#endif
    NSString *outcome = nil;
    id patched = TPRPatchKeyboard(keyboard, name, [TPRConfig current], &outcome);
    // Only decisions: UIKit asks many times per keyboard, and "cached" lines would push the
    // useful ones out of the diagnostics buffer.
    if (![outcome isEqualToString:@"cached"]) TPRLog(@"keyboardForName:%@ -> %@", name, outcome);
    return patched ?: keyboard;
}

static id hook_cacheIdentifierForKeyplaneNamed(id self, SEL _cmd, NSString *planeName) {
    id identifier = orig_cacheIdentifierForKeyplaneNamed(self, _cmd, planeName);
    if (![identifier isKindOfClass:[NSString class]]) return identifier;
    NSString *patched = [identifier stringByAppendingFormat:@"-TopRow-%@", [TPRConfig current].fingerprint];
    static dispatch_once_t once;
    dispatch_once(&once, ^{ TPRLog(@"cache identifier %@", patched); });
    return patched;
}

// Settings changed: take the new snapshot and make the current process rebuild its
// keyboard. -[UIKeyboardImpl clearLayouts] drops UIKit's cached layouts (which
// otherwise keep the old tree by name); if a keyboard is on screen, dismissing and
// re-showing it makes UIKit ask keyboardForName: again. Suspended apps get this
// when they resume; apps that went to the background already dropped their layouts.
static id CallObject(id target, NSString *selName) {
    SEL sel = NSSelectorFromString(selName);
    return [target respondsToSelector:sel] ? ((id (*)(id, SEL))objc_msgSend)(target, sel) : nil;
}

static void CallVoid(id target, NSString *selName) {
    SEL sel = NSSelectorFromString(selName);
    if ([target respondsToSelector:sel]) ((void (*)(id, SEL))objc_msgSend)(target, sel);
}

static void ApplyConfigChange(void) {
    if (![TPRConfig reload]) return;
    TPRLog(@"config changed -> %@", [TPRConfig current].fingerprint);
    id impl = CallObject(NSClassFromString(@"UIKeyboardImpl"), @"activeInstance");
    CallVoid(impl, @"clearLayouts");
    UIResponder *responder = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows)
            if (window.isKeyWindow) responder = CallObject(window, @"firstResponder");
    }
    if (responder.isFirstResponder && [responder canResignFirstResponder] && [responder resignFirstResponder])
        dispatch_async(dispatch_get_main_queue(), ^{ [responder becomeFirstResponder]; });
}

static void OnReloadNotification(CFNotificationCenterRef center, void *observer, CFNotificationName name,
                                 const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{ ApplyConfigChange(); });
}

// ---- "lowercase row while auto-capitalized" ------------------------------------

static void (*orig_setShift)(id, SEL, BOOL);
static void (*orig_setAutoshift)(id, SEL, BOOL);
static void (*orig_setKeyplaneName)(id, SEL, NSString *);
static BOOL gRelabeling;

static BOOL CallBool(id target, NSString *selName) {
    SEL sel = NSSelectorFromString(selName);
    return [target respondsToSelector:sel] && ((BOOL (*)(id, SEL))objc_msgSend)(target, sel);
}

static void UpdateShiftedRow(id layout) {
    TPRConfig *config = [TPRConfig current];
    if (gRelabeling || !config.lowercaseRowWhenAutoShifted) return;
    id impl = CallObject(NSClassFromString(@"UIKeyboardImpl"), @"activeInstance");
    BOOL autoShifted = CallBool(layout, @"autoShift") && !CallBool(impl, @"isShiftLocked");
    BOOL landscape = TPRIsLandscapeKeyboard(CallObject(layout, @"keyboard"), CallObject(layout, @"keyboardName"));
    if (!TPRRelabelShiftedRow(CallObject(layout, @"keyplane"), autoShifted, landscape, config)) return;
    gRelabeling = YES;
    CallVoid(layout, @"reloadCurrentKeyplane");
    gRelabeling = NO;
}

static void hook_setShift(id self, SEL _cmd, BOOL shift) {
    orig_setShift(self, _cmd, shift);
    UpdateShiftedRow(self);
}

static void hook_setAutoshift(id self, SEL _cmd, BOOL autoshift) {
    orig_setAutoshift(self, _cmd, autoshift);
    UpdateShiftedRow(self);
}

static void hook_setKeyplaneName(id self, SEL _cmd, NSString *name) {
    orig_setKeyplaneName(self, _cmd, name);
    UpdateShiftedRow(self);
}

// ---- Bottom Area slider: the strip under the keys ------------------------------
//
// UIKit pins the keys' container above the bottom edge with a constraint named
// "inputView.bottom" (-58pt on an iPhone 15 Pro); the emoji/dictation buttons sit in
// that gap inside UIKeyboardDockView. Scale the gap, and scale its contents with it,
// keeping their distance from the bottom proportional so they stay inside the strip.

static void (*orig_dockLayoutSubviews)(id, SEL);
static char kOriginalConstantKey;

// What's actually drawn inside a dock item, in its own bounds: a button's image, a
// collection view's cells (the item's frame is often much taller than its icon).
static CGRect VisibleRect(UIView *item) {
    if ([item isKindOfClass:[UIButton class]] && ((UIButton *)item).imageView.image)
        return ((UIButton *)item).imageView.frame;
    if ([item isKindOfClass:[UICollectionView class]]) {
        CGRect cells = CGRectNull;
        for (UICollectionViewCell *cell in ((UICollectionView *)item).visibleCells) cells = CGRectUnion(cells, cell.frame);
        if (!CGRectIsNull(cells)) return cells;   // bounds coordinates, like item.bounds below
    }
    CGFloat h = MIN(item.bounds.size.height, 34);
    return CGRectMake(0, CGRectGetMidY(item.bounds) - h / 2, item.bounds.size.width, h);
}

static void ScaleBottomArea(UIView *dock, double scale) {
    for (NSLayoutConstraint *c in dock.superview.constraints) {
        if (![c.identifier isEqualToString:@"inputView.bottom"]) continue;
        // @[Apple's value, the value we last set]. If the constant no longer matches what we
        // set, UIKit has changed it (another keyboard type or orientation): that's the new
        // original. At 100% an untouched constraint is left alone.
        NSArray<NSNumber *> *state = objc_getAssociatedObject(c, &kOriginalConstantKey);
        if (!state || fabs(c.constant - state[1].doubleValue) > 0.5) state = @[ @(c.constant), @(c.constant) ];
        CGFloat wanted = state[0].doubleValue * scale;
        if (fabs(c.constant - wanted) > 0.5) c.constant = wanted;
        objc_setAssociatedObject(c, &kOriginalConstantKey, @[ state[0], @(c.constant) ], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // Every direct subview: Apple's emoji/dictation buttons, and bars other tweaks put
    // in the dock (e.g. KBApp's KBDockCollectionView). Two stages: first use up the
    // empty padding (move the item, full size); only when it no longer fits between
    // the home-indicator clearance and the keys, shrink it just enough.
    const CGFloat homeClearance = 12, gapUnderKeys = 4;
    CGFloat strip = 0;
    for (NSLayoutConstraint *c in dock.superview.constraints)
        if ([c.identifier isEqualToString:@"inputView.bottom"]) strip = -c.constant;
    for (UIView *item in dock.subviews) {
        CGAffineTransform t = CGAffineTransformIdentity;
        if (scale != 1 && strip > 0) {
            // Transforms scale about the item's center (center/bounds ignore transforms).
            CGRect visible = VisibleRect(item);
            CGFloat content = visible.size.height;
            CGFloat offset = CGRectGetMidY(visible) - CGRectGetMidY(item.bounds);   // + = below center
            CGFloat itemFromBottom = dock.bounds.size.height - item.center.y;
            CGFloat contentFromBottom = itemFromBottom - offset;
            CGFloat band = strip - homeClearance - gapUnderKeys;
            CGFloat fit = MAX(MIN(1, band / content), 0.5);
            CGFloat target = MIN(contentFromBottom, strip - gapUnderKeys - content * fit / 2);
            target = MAX(target, homeClearance + content * fit / 2);
            CGFloat down = itemFromBottom - offset * fit - target;
            t = CGAffineTransformScale(CGAffineTransformMakeTranslation(0, down), fit, fit);
        }
        if (!CGAffineTransformEqualToTransform(item.transform, t)) item.transform = t;
    }
}

static void hook_dockLayoutSubviews(UIView *self, SEL _cmd) {
    orig_dockLayoutSubviews(self, _cmd);
    TPRConfig *config = [TPRConfig current];
    NSString *app = NSBundle.mainBundle.bundleIdentifier;
    BOOL active = config.enabled && !(app && [config.excludedApps containsObject:app]);
    ScaleBottomArea(self, active ? config.bottomAreaScale : 1);
}

// ---- custom 123 / ABC labels -------------------------------------------------------
// UIKit localizes the keyplane-switch key ("More-Key") in updateLocalizedKeysOnKeyplane:;
// override its label afterwards. On letter planes it reads "123", elsewhere "ABC".

static void (*orig_updateLocalizedKeys)(id, SEL, id);

static void hook_updateLocalizedKeys(id self, SEL _cmd, id keyplane) {
    orig_updateLocalizedKeys(self, _cmd, keyplane);
    TPRConfig *config = [TPRConfig current];
    if (!config.enabled || (!config.label123 && !config.labelABC)) return;
    NSString *app = NSBundle.mainBundle.bundleIdentifier;
    if (app && [config.excludedApps containsObject:app]) return;
    if (!TPRIsPatchedKeyplane(keyplane)) return;   // Apple's own trees keep Apple's labels
    BOOL letters = CallBool(keyplane, @"isAlphabeticPlane");
    NSString *label = letters ? config.label123 : config.labelABC;
    if (!label) return;
    for (id key in CallObject(keyplane, @"keys")) {
        if (![TPRName(key) isEqualToString:@"More-Key"]) continue;
        NSMutableDictionary *props = [TPRProperties(key) mutableCopy];
        props[@"KBdisplayString"] = label;
        [(id<TPRKBTree>)key setProperties:props];
    }
}

// ---- symbol hints: small label in the top-right corner of row keys ---------------------
// UIKit draws a keyplane into one image, so overlay labels on the keyplane view, using
// each key's laid-out frame and the keyboard's text color.

static void (*orig_keyplaneLayoutSubviews)(id, SEL);
static const NSInteger kHintTag = 0x5C10;

static void hook_keyplaneLayoutSubviews(UIView *self, SEL _cmd) {
    orig_keyplaneLayoutSubviews(self, _cmd);
    // This runs on every layout pass: reuse the labels from the last one.
    NSMutableArray<UILabel *> *spare = [NSMutableArray array];
    for (UIView *v in self.subviews)
        if (v.tag == kHintTag && [v isKindOfClass:[UILabel class]]) [spare addObject:(UILabel *)v];
    NSMutableArray<UILabel *> *used = [NSMutableArray array];
    if ([TPRConfig current].symbolHints) {
        for (id key in CallObject(CallObject(self, @"keyplane"), @"keys")) {
            NSString *hint = TPRProperties(key)[@"TPRhint"];
            CGRect frame;
            if (![hint isKindOfClass:[NSString class]] || !TPRGetFrames(key, NULL, &frame) || CGRectIsEmpty(frame)) continue;
            UILabel *label = spare.firstObject;
            if (label) {
                [spare removeObjectAtIndex:0];
            } else {
                label = [UILabel new];
                label.tag = kHintTag;
                label.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
                label.adjustsFontSizeToFitWidth = YES;   // multi-character keys like ".com"
                label.minimumScaleFactor = 0.5;
                label.textColor = [UIColor.labelColor colorWithAlphaComponent:0.55];
                label.textAlignment = NSTextAlignmentRight;
                label.userInteractionEnabled = NO;
                [self addSubview:label];
            }
            if (![label.text isEqualToString:hint]) label.text = hint;
            CGRect target = CGRectMake(CGRectGetMaxX(frame) - 20, CGRectGetMinY(frame) + 2, 16, 13);
            if (!CGRectEqualToRect(label.frame, target)) label.frame = target;
            [used addObject:label];
        }
    }
    for (UILabel *label in spare) [label removeFromSuperview];
    // Keep them above the key artwork if UIKit added views since the last pass.
    if (used.count && self.subviews.lastObject.tag != kHintTag)
        for (UILabel *label in used) [self bringSubviewToFront:label];
}

static Method TargetMethod(NSString *className, SEL sel) {
    Class cls = NSClassFromString(className);
    Method method = cls ? class_getInstanceMethod(cls, sel) : NULL;
    if (!method) TPRLog(@"hook target missing: -[%@ %@]", className, NSStringFromSelector(sel));
    return method;
}

static void HookMethod(NSString *className, SEL sel, IMP replacement, IMP *original) {
    Class cls = NSClassFromString(className);
    Method method = class_getInstanceMethod(cls, sel);
    *original = method_getImplementation(method);
    // If the method is inherited, add an override on this class rather than
    // replacing the superclass implementation for every subclass.
    if (!class_addMethod(cls, sel, replacement, method_getTypeEncoding(method)))
        *original = method_setImplementation(method, replacement);
}

static BOOL ShouldLoadInProcess(void) {
    char exe[PATH_MAX];
    uint32_t size = sizeof(exe);
    if (_NSGetExecutablePath(exe, &size) != 0 || !strstr(exe, ".app/")) return NO;   // not daemons
    if (!strstr(exe, ".appex/")) return YES;   // real apps, incl. SpringBoard, InputUI, Spotlight
    // Extensions: only share sheets, action extensions and password managers' AutoFill
    // sheets (their text fields use the stock keyboard in-process). Never custom
    // keyboards, widgets, etc.
    NSString *point = NSBundle.mainBundle.infoDictionary[@"NSExtension"][@"NSExtensionPointIdentifier"];
    return [@[ @"com.apple.share-services", @"com.apple.ui-services",
               @"com.apple.authentication-services-credential-provider-ui" ] containsObject:point ?: @""];
}

__attribute__((constructor)) static void TPRInit(void) {
    @autoreleasepool {
        if (!ShouldLoadInProcess()) return;
        // iPhone only: iPad keyboards are laid out differently (and already put digits and
        // symbols on their letter keys).
        if (UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPhone) return;
        // Creating this file (e.g. over SSH) disables the tweak at next app launch.
        if ([[NSFileManager defaultManager] fileExistsAtPath:TPRKillSwitchFile]) {
            TPRLog(@"kill switch present, not hooking");
            return;
        }
        if (!NSClassFromString(@"TUIKBGraphSerialization"))
            dlopen("/System/Library/PrivateFrameworks/TextInputUI.framework/TextInputUI", RTLD_LAZY);

        SEL keyboardSel = NSSelectorFromString(@"keyboardForName:");
        SEL cacheSel = NSSelectorFromString(@"cacheIdentifierForKeyplaneNamed:");
        // All or nothing: a patched layout drawn from stale cached images is worse than no patch.
        if (!TargetMethod(@"TUIKBGraphSerialization", keyboardSel) || !TargetMethod(@"UIKeyboardLayoutStar", cacheSel)) {
            TPRLog(@"hooks NOT installed");
            return;
        }
        HookMethod(@"UIKeyboardLayoutStar", cacheSel, (IMP)hook_cacheIdentifierForKeyplaneNamed,
                   (IMP *)&orig_cacheIdentifierForKeyplaneNamed);
        HookMethod(@"TUIKBGraphSerialization", keyboardSel, (IMP)hook_keyboardForName, (IMP *)&orig_keyboardForName);
        if (TargetMethod(@"UIKBKeyplaneView", @selector(layoutSubviews)))
            HookMethod(@"UIKBKeyplaneView", @selector(layoutSubviews), (IMP)hook_keyplaneLayoutSubviews,
                       (IMP *)&orig_keyplaneLayoutSubviews);
        SEL localizeSel = NSSelectorFromString(@"updateLocalizedKeysOnKeyplane:");
        if (TargetMethod(@"UIKeyboardLayoutStar", localizeSel))
            HookMethod(@"UIKeyboardLayoutStar", localizeSel, (IMP)hook_updateLocalizedKeys, (IMP *)&orig_updateLocalizedKeys);
        if (TargetMethod(@"UIKeyboardDockView", @selector(layoutSubviews)))
            HookMethod(@"UIKeyboardDockView", @selector(layoutSubviews), (IMP)hook_dockLayoutSubviews,
                       (IMP *)&orig_dockLayoutSubviews);
        // Optional: only the auto-capitalization option depends on these.
        for (NSArray *hook in @[ @[ @"setShift:", [NSValue valueWithPointer:(void *)hook_setShift], [NSValue valueWithPointer:&orig_setShift] ],
                                 @[ @"setAutoshift:", [NSValue valueWithPointer:(void *)hook_setAutoshift], [NSValue valueWithPointer:&orig_setAutoshift] ],
                                 @[ @"setKeyplaneName:", [NSValue valueWithPointer:(void *)hook_setKeyplaneName], [NSValue valueWithPointer:&orig_setKeyplaneName] ] ]) {
            SEL sel = NSSelectorFromString(hook[0]);
            if (TargetMethod(@"UIKeyboardLayoutStar", sel))
                HookMethod(@"UIKeyboardLayoutStar", sel, (IMP)[hook[1] pointerValue], (IMP *)[hook[2] pointerValue]);
        }
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, OnReloadNotification,
                                        (__bridge CFStringRef)TPRReloadNotification, NULL,
                                        CFNotificationSuspensionBehaviorCoalesce);
        TPRLog(@"hooks installed, config %@", [TPRConfig current].fingerprint);
    }
}
