// TPRHost — simulator-only test bench for the TopRow tweak.
//
// Shows a focused text field so the stock keyboard is up, then executes
// commands from <tmp>/tpr-cmd.txt whenever the Darwin notification
// "dev.rtrdd.tprhost.cmd" is posted (xcrun simctl spawn <udid> notifyutil -p ...).
// Results are appended to <tmp>/tpr-out.txt; tree dumps go to <tmp>/tpr-tree-<label>.txt.
//
// Commands (one per line):
//   plane <keyplane-name>     switch the layout to a keyplane
//   shift <0|1>               -[UIKeyboardImpl setShift:]
//   autoshift                 -[UIKeyboardImpl setShift:YES autoshift:YES]
//   capslock <0|1>            -[UIKeyboardImpl setShiftLocked:]
//   dump <label>              dump keyboard tree + current keyplane name
//   tapkey <key-name>         simulate a touch at the centre of the named key
//   tapchar <string>          simulateTouchForCharacter:
//   text                      log the text field contents
//   clear                     clear the text field
//   info                      log keyboard name, keyplane name, layout frame

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach/mach_time.h>

static NSString *TmpPath(NSString *name) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:name];
}

static void Out(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void Out(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[TPRHost] %@", line);
    NSString *path = TmpPath(@"tpr-out.txt");
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:path];
    }
    [fh seekToEndOfFile];
    [fh writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

static id Call(id obj, NSString *selName) {
    SEL sel = NSSelectorFromString(selName);
    if (!obj || ![obj respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(obj, sel);
}

static id KeyboardImpl(void) {
    return Call(NSClassFromString(@"UIKeyboardImpl"), @"activeInstance");
}

static id LayoutStar(void) {
    return Call(KeyboardImpl(), @"_layout");
}

// ---- tree dump --------------------------------------------------------------

static BOOL ShapeFrame(id shape, NSString *selName, CGRect *out) {
    SEL sel = NSSelectorFromString(selName);
    if (!shape || ![shape respondsToSelector:sel]) return NO;
    *out = ((CGRect (*)(id, SEL))objc_msgSend)(shape, sel);
    return YES;
}

static NSString *DescribeValue(id v) {
    if ([v isKindOfClass:[NSString class]]) return [NSString stringWithFormat:@"\"%@\"", v];
    if ([v isKindOfClass:[NSNumber class]]) return [v description];
    if ([v isKindOfClass:NSClassFromString(@"UIKBShape")]) {
        CGRect f, p;
        BOOL hf = ShapeFrame(v, @"frame", &f), hp = ShapeFrame(v, @"paddedFrame", &p);
        return [NSString stringWithFormat:@"<shape %p f=%@ p=%@>", v,
                hf ? NSStringFromCGRect(f) : @"?", hp ? NSStringFromCGRect(p) : @"?"];
    }
    if ([v isKindOfClass:[NSArray class]]) return [NSString stringWithFormat:@"<array %lu>", (unsigned long)[v count]];
    if ([v isKindOfClass:[NSDictionary class]]) {
        NSMutableArray *parts = [NSMutableArray array];
        for (id k in v) [parts addObject:[NSString stringWithFormat:@"%@=%@", k, DescribeValue(v[k])]];
        return [NSString stringWithFormat:@"{%@}", [parts componentsJoinedByString:@", "]];
    }
    return [NSString stringWithFormat:@"<%@ %p>", NSStringFromClass([v class]), v];
}

static void DumpNode(id node, int depth, NSMutableString *out, NSHashTable *seen) {
    NSString *pad = [@"" stringByPaddingToLength:(NSUInteger)depth * 2 withString:@" " startingAtIndex:0];
    if (![node isKindOfClass:NSClassFromString(@"UIKBTree")]) {
        [out appendFormat:@"%@- %@\n", pad, DescribeValue(node)];
        return;
    }
    BOOL again = [seen containsObject:node];
    [seen addObject:node];
    int type = -1;
    if ([node respondsToSelector:NSSelectorFromString(@"type")])
        type = ((int (*)(id, SEL))objc_msgSend)(node, NSSelectorFromString(@"type"));
    [out appendFormat:@"%@[%d] %@ %p%@\n", pad, type, Call(node, @"name"), node, again ? @" (SHARED, seen before)" : @""];
    if (again) return;
    NSDictionary *props = Call(node, @"properties");
    NSArray *keys = [[props allKeys] sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        return [[a description] compare:[b description]];
    }];
    for (id k in keys)
        [out appendFormat:@"%@    . %@ = %@\n", pad, k, DescribeValue(props[k])];
    for (id child in Call(node, @"subtrees"))
        DumpNode(child, depth + 1, out, seen);
}

static void DumpTree(NSString *label) {
    id layout = LayoutStar();
    id keyboard = Call(layout, @"keyboard");
    id keyplane = Call(layout, @"keyplane");
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"keyboardName=%@ keyplane=%@ keyplaneObj=%p layoutFrame=%@\n",
     Call(layout, @"keyboardName"), Call(keyplane, @"name"), keyplane,
     layout ? NSStringFromCGRect([(UIView *)layout frame]) : @"?"];
    DumpNode(keyboard, 0, s, [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality]);
    NSString *path = TmpPath([NSString stringWithFormat:@"tpr-tree-%@.txt", label]);
    [s writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    Out(@"dumped %@ (%lu bytes)", path, (unsigned long)s.length);
}

// ---- real touch synthesis (KIF-style: UITouch + IOHIDEvent through UIApplication) ----

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef IOHIDEventRef (*CreateDigitizerEventFn)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t,
                                                uint32_t, double, double, double, double, double, Boolean, Boolean,
                                                uint32_t);
typedef IOHIDEventRef (*CreateFingerEventFn)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, double, double,
                                             double, double, double, double, double, double, double, double, Boolean,
                                             Boolean, uint32_t);
typedef void (*AppendEventFn)(IOHIDEventRef, IOHIDEventRef, uint32_t);
typedef void (*SetIntegerValueFn)(IOHIDEventRef, uint32_t, long);

static IOHIDEventRef HIDEventForTouch(CGPoint p, BOOL touching) {
    static CreateDigitizerEventFn createHand;
    static CreateFingerEventFn createFinger;
    static AppendEventFn append;
    static SetIntegerValueFn setInt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        createHand = (CreateDigitizerEventFn)dlsym(iokit, "IOHIDEventCreateDigitizerEvent");
        createFinger = (CreateFingerEventFn)dlsym(iokit, "IOHIDEventCreateDigitizerFingerEventWithQuality");
        append = (AppendEventFn)dlsym(iokit, "IOHIDEventAppendEvent");
        setInt = (SetIntegerValueFn)dlsym(iokit, "IOHIDEventSetIntegerValue");
    });
    const uint32_t kIsDisplayIntegrated = (11 << 16) | 25;   // kIOHIDEventFieldDigitizerIsDisplayIntegrated
    uint64_t now = mach_absolute_time();
    IOHIDEventRef hand = createHand(kCFAllocatorDefault, now, 3 /* hand */, 0, 0, 2 /* touch */, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    setInt(hand, kIsDisplayIntegrated, 1);
    IOHIDEventRef finger = createFinger(kCFAllocatorDefault, now, 1, 2, 1 | 2 /* range|touch */, p.x, p.y, 0, 0, 0,
                                        5, 5, 1, 1, 1, touching, touching, 0);
    setInt(finger, kIsDisplayIntegrated, 1);
    append(hand, finger, 0);
    CFRelease(finger);
    return hand;
}

static void SendTouch(UITouch *touch, UITouchPhase phase, CGPoint pInWindow) {
    UIApplication *app = UIApplication.sharedApplication;
    ((void (*)(id, SEL, double))objc_msgSend)(touch, NSSelectorFromString(@"setTimestamp:"), NSProcessInfo.processInfo.systemUptime);
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(touch, NSSelectorFromString(@"setPhase:"), phase);
    IOHIDEventRef hid = HIDEventForTouch(pInWindow, phase != UITouchPhaseEnded);
    ((void (*)(id, SEL, IOHIDEventRef))objc_msgSend)(touch, NSSelectorFromString(@"_setHidEvent:"), hid);
    UIEvent *event = Call(app, @"_touchesEvent");
    ((void (*)(id, SEL))objc_msgSend)(event, NSSelectorFromString(@"_clearTouches"));
    ((void (*)(id, SEL, IOHIDEventRef))objc_msgSend)(event, NSSelectorFromString(@"_setHIDEvent:"), hid);
    ((void (*)(id, SEL, id, BOOL))objc_msgSend)(event, NSSelectorFromString(@"_addTouch:forDelayedDelivery:"), touch, NO);
    [app sendEvent:event];
    CFRelease(hid);
}

// Swipe down from a point (layout coordinates) by dy points.
static void SwipeLayoutPoint(UIView *layout, CGPoint p, CGFloat dy) {
    UIWindow *window = layout.window;
    CGPoint w = [layout convertPoint:p toView:window];
    UITouch *touch = [UITouch new];
    UIView *hit = [window hitTest:w withEvent:nil];
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(touch, NSSelectorFromString(@"setTapCount:"), 1);
    ((void (*)(id, SEL, CGPoint, BOOL))objc_msgSend)(touch, NSSelectorFromString(@"_setLocationInWindow:resetPrevious:"), w, YES);
    ((void (*)(id, SEL, id))objc_msgSend)(touch, NSSelectorFromString(@"setWindow:"), window);
    ((void (*)(id, SEL, id))objc_msgSend)(touch, NSSelectorFromString(@"setView:"), hit);
    SendTouch(touch, UITouchPhaseBegan, w);
    for (int i = 1; i <= 6; i++) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.016]];
        CGPoint q = CGPointMake(w.x, w.y + dy * i / 6);
        ((void (*)(id, SEL, CGPoint, BOOL))objc_msgSend)(touch, NSSelectorFromString(@"_setLocationInWindow:resetPrevious:"), q, NO);
        SendTouch(touch, UITouchPhaseMoved, q);
    }
    SendTouch(touch, UITouchPhaseEnded, CGPointMake(w.x, w.y + dy));
}

// Tap at a point given in keyboard-layout coordinates.
static void TapLayoutPoint(UIView *layout, CGPoint p) {
    UIWindow *window = layout.window;
    CGPoint w = [layout convertPoint:p toView:window];
    UITouch *touch = [UITouch new];
    UIView *hit = [window hitTest:w withEvent:nil];
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(touch, NSSelectorFromString(@"setTapCount:"), 1);
    ((void (*)(id, SEL, CGPoint, BOOL))objc_msgSend)(touch, NSSelectorFromString(@"_setLocationInWindow:resetPrevious:"), w, YES);
    ((void (*)(id, SEL, id))objc_msgSend)(touch, NSSelectorFromString(@"setWindow:"), window);
    ((void (*)(id, SEL, id))objc_msgSend)(touch, NSSelectorFromString(@"setView:"), hit);
    if ([touch respondsToSelector:NSSelectorFromString(@"setGestureView:")])
        ((void (*)(id, SEL, id))objc_msgSend)(touch, NSSelectorFromString(@"setGestureView:"), hit);
    for (NSString *name in @[ @"_setIsFirstTouchForView:", @"setIsTap:" ]) {
        SEL sel = NSSelectorFromString(name);
        if ([touch respondsToSelector:sel]) ((void (*)(id, SEL, BOOL))objc_msgSend)(touch, sel, YES);
        else Out(@"UITouch lacks %@", name);
    }
    SendTouch(touch, UITouchPhaseBegan, w);
    SendTouch(touch, UITouchPhaseEnded, w);
}

// ---- view controller ----------------------------------------------------------

@interface TPRHostViewController : UIViewController
@property (nonatomic, strong) UITextField *field;
- (void)runCommands;
@end

@implementation TPRHostViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.field = [[UITextField alloc] initWithFrame:CGRectMake(20, 120, self.view.bounds.size.width - 40, 44)];
    self.field.borderStyle = UITextBorderStyleRoundedRect;
    self.field.placeholder = @"TopRow test field";
    self.field.autocorrectionType = UITextAutocorrectionTypeNo;
    [self.view addSubview:self.field];
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskAllButUpsideDown;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.field becomeFirstResponder];
}

- (void)runCommands {
    NSString *cmds = [NSString stringWithContentsOfFile:TmpPath(@"tpr-cmd.txt") encoding:NSUTF8StringEncoding error:nil];
    for (NSString *raw in [cmds componentsSeparatedByString:@"\n"]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!line.length) continue;
        NSRange sp = [line rangeOfString:@" "];
        NSString *verb = sp.location == NSNotFound ? line : [line substringToIndex:sp.location];
        NSString *arg = sp.location == NSNotFound ? @"" : [line substringFromIndex:sp.location + 1];
        [self run:verb arg:arg];
    }
}

- (void)run:(NSString *)verb arg:(NSString *)arg {
    id impl = KeyboardImpl();
    id layout = LayoutStar();
    if ([verb isEqualToString:@"plane"]) {
        ((void (*)(id, SEL, id))objc_msgSend)(layout, NSSelectorFromString(@"setKeyplaneName:"), arg);
        Out(@"plane -> %@ (now %@)", arg, Call(Call(layout, @"keyplane"), @"name"));
    } else if ([verb isEqualToString:@"shift"]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(impl, NSSelectorFromString(@"setShift:"), arg.boolValue);
        Out(@"shift %d (now %@)", arg.boolValue, Call(Call(layout, @"keyplane"), @"name"));
    } else if ([verb isEqualToString:@"autoshift"]) {
        ((void (*)(id, SEL, BOOL, BOOL))objc_msgSend)(impl, NSSelectorFromString(@"setShift:autoshift:"), YES, YES);
        Out(@"autoshift (now %@)", Call(Call(layout, @"keyplane"), @"name"));
    } else if ([verb isEqualToString:@"capslock"]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(impl, NSSelectorFromString(@"setShiftLocked:"), arg.boolValue);
        Out(@"capslock %d (now %@)", arg.boolValue, Call(Call(layout, @"keyplane"), @"name"));
    } else if ([verb isEqualToString:@"dump"]) {
        DumpTree(arg.length ? arg : @"current");
    } else if ([verb isEqualToString:@"tapkey"]) {
        id keyplane = Call(layout, @"keyplane");
        id found = nil;
        NSMutableArray *stack = [NSMutableArray arrayWithObject:keyplane];
        while (stack.count && !found) {
            id n = stack.lastObject;
            [stack removeLastObject];
            if ([Call(n, @"name") isEqual:arg]) found = n;
            for (id c in Call(n, @"subtrees")) [stack addObject:c];
        }
        CGRect f;
        if (!found || !ShapeFrame(found, @"frame", &f)) { Out(@"tapkey %@: not found", arg); return; }
        CGPoint pt = CGPointMake(CGRectGetMidX(f), CGRectGetMidY(f));
        ((void (*)(id, SEL, CGPoint))objc_msgSend)(layout, NSSelectorFromString(@"simulateTouch:"), pt);
        Out(@"tapkey %@ at %@ -> field=\"%@\"", arg, NSStringFromCGPoint(pt), self.field.text);
    } else if ([verb isEqualToString:@"touch"]) {
        // touch <x> <y> in layout coordinates (real UITouch through UIApplication)
        NSArray *xy = [arg componentsSeparatedByString:@" "];
        CGPoint p = CGPointMake([xy[0] doubleValue], [xy[1] doubleValue]);
        TapLayoutPoint(layout, p);
        Out(@"touch %@ sent", NSStringFromCGPoint(p));
    } else if ([verb isEqualToString:@"kbtype"]) {
        // kbtype <UIKeyboardType raw value>: switch the field's keyboard type
        [self.field resignFirstResponder];
        self.field.keyboardType = (UIKeyboardType)arg.integerValue;
        [self.field becomeFirstResponder];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
        Out(@"kbtype %@ -> keyboardName=%@ keyplane=%@ layoutFrame=%@", arg, Call(LayoutStar(), @"keyboardName"),
            Call(Call(LayoutStar(), @"keyplane"), @"name"),
            LayoutStar() ? NSStringFromCGRect([(UIView *)LayoutStar() frame]) : @"?");
    } else if ([verb isEqualToString:@"rotate"]) {
        // rotate <portrait|landscape>
        UIInterfaceOrientationMask mask = [arg isEqualToString:@"portrait"] ? UIInterfaceOrientationMaskPortrait
                                                                           : UIInterfaceOrientationMaskLandscapeRight;
        if (@available(iOS 16.0, *)) {
            UIWindowSceneGeometryPreferencesIOS *prefs = [[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:mask];
            [self.view.window.windowScene requestGeometryUpdateWithPreferences:prefs errorHandler:^(NSError *error) {
                Out(@"rotate error %@", error);
            }];
            [self setNeedsUpdateOfSupportedInterfaceOrientations];
        }
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.5]];
        Out(@"rotate %@ -> keyboardName=%@ keyplane=%@ layoutFrame=%@", arg, Call(LayoutStar(), @"keyboardName"),
            Call(Call(LayoutStar(), @"keyplane"), @"name"),
            LayoutStar() ? NSStringFromCGRect([(UIView *)LayoutStar() frame]) : @"?");
    } else if ([verb isEqualToString:@"dockheight"]) {
        // dockheight <h>: probe whether UIKeyboardDockView's intrinsic height drives the dock area
        static CGFloat gDockHeight;
        gDockHeight = arg.doubleValue;
        Class cls = NSClassFromString(@"UIKeyboardDockView");
        Method mth = class_getInstanceMethod(cls, @selector(intrinsicContentSize));
        static IMP origImp;
        if (!origImp) origImp = method_getImplementation(mth);
        method_setImplementation(mth, imp_implementationWithBlock(^CGSize(id me) {
            CGSize sz = ((CGSize (*)(id, SEL))origImp)(me, @selector(intrinsicContentSize));
            Out(@"dock intrinsicContentSize orig=%@", NSStringFromCGSize(sz));
            sz.height = gDockHeight;
            return sz;
        }));
        [self.field resignFirstResponder];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.8]];
        [self.field becomeFirstResponder];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.2]];
        Out(@"dockheight %@ applied", arg);
    } else if ([verb isEqualToString:@"altconfig"]) {
        // Swap the tweak's config in-process (test only): +[TPRConfig current] -> an alternate config.
        Class cfg = NSClassFromString(@"TPRConfig");
        static id gAlt;
        gAlt = ((id (*)(id, SEL, id, id, id, BOOL))objc_msgSend)([cfg alloc],
            NSSelectorFromString(@"initWithLetters:shifted:symbols:landscape:"),
            @[ @"0", @"9", @"8", @"7", @"6", @"5", @"4", @"3", @"2", @"1" ],
            @[ @"<", @">", @"{", @"}", @"[", @"]", @"|", @"~", @"`", @"+" ],
            @[ @"<", @">", @"{", @"}", @"[", @"]", @"|", @"~", @"`", @"+" ], YES);
        method_setImplementation(class_getClassMethod(cfg, NSSelectorFromString(@"current")),
                                 imp_implementationWithBlock(^id(id me) { return gAlt; }));
        Out(@"altconfig fingerprint=%@", Call(gAlt, @"fingerprint"));
    } else if ([verb isEqualToString:@"tokenfix"]) {
        // Experiment: suffix the keyplane render-cache token name with the tweak's config fingerprint.
        Class star = NSClassFromString(@"UIKeyboardLayoutStar");
        SEL sel = NSSelectorFromString(@"cacheTokenForKeyplane:caseAlternates:");
        Method mth = class_getInstanceMethod(star, sel);
        static IMP orig;
        if (!orig) orig = method_getImplementation(mth);
        method_setImplementation(mth, imp_implementationWithBlock(^id(id me, id keyplane, BOOL alts) {
            id token = ((id (*)(id, SEL, id, BOOL))orig)(me, sel, keyplane, alts);
            NSString *fp = Call(Call(NSClassFromString(@"TPRConfig"), @"current"), @"fingerprint");
            NSString *name = Call(token, @"name");
            if (fp && name && ![name hasSuffix:fp])
                ((void (*)(id, SEL, id))objc_msgSend)(token, NSSelectorFromString(@"setName:"),
                                                     [name stringByAppendingFormat:@"-TopRow-%@", fp]);
            return token;
        }));
        Out(@"tokenfix installed");
    } else if ([verb isEqualToString:@"reshow"]) {
        [self.field resignFirstResponder];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.8]];
        [self.field becomeFirstResponder];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.2]];
        Out(@"reshow done");
    } else if ([verb isEqualToString:@"call"]) {
        // call <impl|layout|ClassName> <zero-arg selector>
        NSArray *p = [arg componentsSeparatedByString:@" "];
        id target = [p[0] isEqualToString:@"impl"] ? impl : [p[0] isEqualToString:@"layout"] ? layout : NSClassFromString(p[0]);
        if ([p[0] hasPrefix:@"shared:"]) target = Call(NSClassFromString([p[0] substringFromIndex:7]), @"sharedInstance");
        SEL sel = NSSelectorFromString(p[1]);
        if (![target respondsToSelector:sel]) { Out(@"call %@: not supported", arg); return; }
        ((void (*)(id, SEL))objc_msgSend)(target, sel);
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
        Out(@"call %@ done", arg);
    } else if ([verb isEqualToString:@"kbname"]) {
        // kbname <keyboard name>: load a keyboard by name through UIKit (and the tweak's hook)
        SEL sel = NSSelectorFromString(@"keyboardWithName:screenTraits:");
        id kb = ((id (*)(id, SEL, id, id))objc_msgSend)(NSClassFromString(@"UIKeyboardLayoutStar"), sel, arg,
                                                        Call(layout, @"screenTraits"));
        CGRect frame = CGRectZero;
        if ([kb respondsToSelector:NSSelectorFromString(@"frame")])
            frame = ((CGRect (*)(id, SEL))objc_msgSend)(kb, NSSelectorFromString(@"frame"));
        Out(@"kbname %@ -> %@ frame %@", arg, kb ? Call(kb, @"name") : @"nil", NSStringFromCGRect(frame));
        for (id plane in Call(kb, @"subtrees")) {
            BOOL alpha = [plane respondsToSelector:NSSelectorFromString(@"isAlphabeticPlane")] &&
                         ((BOOL (*)(id, SEL))objc_msgSend)(plane, NSSelectorFromString(@"isAlphabeticPlane"));
            Out(@"  plane %@ alpha=%d props=%@", Call(plane, @"name"), alpha,
                [[Call(plane, @"properties") description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "]);
        }
    } else if ([verb isEqualToString:@"kbinventory"]) {
        // kbinventory <names file> <KBLayouts_*.dat> ... (all in tmp): load every candidate name from each data file
        // (first file that has it wins); each keyplane's flags and its key layouts' rows (key name,
        // display, represented, display/interaction type) go to <tmp>/tpr-inventory.json
        NSArray *args = [arg componentsSeparatedByString:@" "];
        NSArray *names = [[NSString stringWithContentsOfFile:TmpPath(args[0]) encoding:NSUTF8StringEncoding error:nil]
                          componentsSeparatedByString:@"\n"];
        NSMutableArray *sers = [NSMutableArray array];
        for (NSString *file in [args subarrayWithRange:NSMakeRange(1, args.count - 1)]) {
            id ser = [NSClassFromString(@"TUIKBGraphSerialization") new];
            ((void (*)(id, SEL, id))objc_msgSend)(ser, NSSelectorFromString(@"setSerializedData:"),
                [NSData dataWithContentsOfFile:TmpPath(file) options:NSDataReadingMappedIfSafe error:nil]);
            [sers addObject:ser];
        }
        NSMutableDictionary *all = [NSMutableDictionary dictionary];
        SEL kfn = NSSelectorFromString(@"keyboardForName:");
        for (NSString *name in names) {
            if (!name.length) continue;
            id kb = nil;
            for (id ser in sers) {
                @try { kb = ((id (*)(id, SEL, id))objc_msgSend)(ser, kfn, name); } @catch (NSException *e) { kb = nil; }
                if (kb) break;
            }
            if (!kb) continue;
            CGRect kf = CGRectZero;
            ShapeFrame(Call(kb, @"properties")[@"KBshape"], @"frame", &kf);
            NSMutableArray *planes = [NSMutableArray array];
            for (id plane in Call(kb, @"subtrees")) {
                int ptype = ((int (*)(id, SEL))objc_msgSend)(plane, NSSelectorFromString(@"type"));
                if (ptype != 2) continue;
                BOOL alpha = ((BOOL (*)(id, SEL))objc_msgSend)(plane, NSSelectorFromString(@"isAlphabeticPlane"));
                BOOL shift = ((BOOL (*)(id, SEL))objc_msgSend)(plane, NSSelectorFromString(@"isShiftKeyplane"));
                NSMutableArray *layouts = [NSMutableArray array];
                for (id layout in Call(plane, @"subtrees")) {
                    if (((int (*)(id, SEL))objc_msgSend)(layout, NSSelectorFromString(@"type")) != 3) continue;
                    NSMutableArray *rows = [NSMutableArray array];
                    for (id set in Call(layout, @"subtrees")) {
                        if (((int (*)(id, SEL))objc_msgSend)(set, NSSelectorFromString(@"type")) != 4) continue;
                        for (id row in Call(set, @"subtrees")) {
                            NSMutableArray *keys = [NSMutableArray array];
                            for (id key in Call(row, @"subtrees")) {
                                NSDictionary *p = Call(key, @"properties");
                                [keys addObject:@[ Call(key, @"name") ?: @"", p[@"KBdisplayString"] ?: @"", p[@"KBrepresentedString"] ?: @"",
                                                   p[@"KBdisplayType"] ?: @-1, p[@"KBinteractionType"] ?: @-1 ]];
                            }
                            [rows addObject:keys];
                        }
                    }
                    [layouts addObject:@{ @"name": Call(layout, @"name") ?: @"", @"rows": rows }];
                }
                [planes addObject:@{ @"name": Call(plane, @"name") ?: @"", @"alpha": @(alpha), @"shift": @(shift),
                                     @"props": [[Call(plane, @"properties") description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "] ?: @"",
                                     @"layouts": layouts }];
            }
            all[name] = @{ @"frame": NSStringFromCGRect(kf), @"planes": planes, @"loadedName": Call(kb, @"name") ?: @"" };
        }
        NSData *json = [NSJSONSerialization dataWithJSONObject:all options:0 error:nil];
        NSString *path = TmpPath(@"tpr-inventory.json");
        [json writeToFile:path atomically:YES];
        Out(@"kbinventory -> %@ (%lu keyboards)", path, (unsigned long)all.count);
    } else if ([verb isEqualToString:@"prefs"]) {
        // prefs <controller class>: present a TopRow Settings pane (TopRowPrefs.bundle, see tpr-sim.sh build)
        static NSBundle *bundle;
        if (!bundle) {
            bundle = [NSBundle bundleWithPath:[NSString stringWithUTF8String:getenv("TPR_PREFS_BUNDLE") ?: ""]];
            if (![bundle load]) { Out(@"prefs: bundle didn't load (%@)", bundle.bundlePath); return; }
            // Panes find their plists through -bundle, which Settings sets from the specifier.
            Method m = class_getInstanceMethod(NSClassFromString(@"PSListController"), NSSelectorFromString(@"bundle"));
            method_setImplementation(m, imp_implementationWithBlock(^id(id me) { return bundle; }));
        }
        if (self.presentedViewController) [self dismissViewControllerAnimated:NO completion:nil];
        UIViewController *pane = [NSClassFromString(arg) new];
        if (!pane) { Out(@"prefs: no class %@", arg); return; }
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:pane];
        nav.modalPresentationStyle = UIModalPresentationFullScreen;
        [self presentViewController:nav animated:NO completion:nil];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.8]];
        Out(@"prefs %@ presented", arg);
    } else if ([verb isEqualToString:@"prefsread"] || [verb isEqualToString:@"prefsset"]) {
        // prefsread: every keyed specifier's value as the pane reads it
        // prefsset <key> <value...>: what typing <value> into that field does
        UIViewController *pane = ((UINavigationController *)self.presentedViewController).topViewController;
        NSString *key = [arg componentsSeparatedByString:@" "].firstObject;
        NSString *value = arg.length > key.length ? [arg substringFromIndex:key.length + 1] : @"";
        NSMutableArray *parts = [NSMutableArray array];
        for (id spec in Call(pane, @"specifiers")) {
            NSString *k = ((NSDictionary *)Call(spec, @"properties"))[@"key"];
            if (!k) continue;
            if ([verb isEqualToString:@"prefsset"]) {
                if (![k isEqualToString:key]) continue;
                ((void (*)(id, SEL, id, id))objc_msgSend)(pane, NSSelectorFromString(@"setPreferenceValue:specifier:"), value, spec);
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.6]];
                Out(@"prefsset %@ = \"%@\"", k, value);
                return;
            }
            id v = ((id (*)(id, SEL, id))objc_msgSend)(pane, NSSelectorFromString(@"readPreferenceValue:"), spec);
            [parts addObject:[NSString stringWithFormat:@"%@=\"%@\"", k, v ?: @""]];
        }
        if ([verb isEqualToString:@"prefsset"]) Out(@"prefsset: no specifier %@", key);
        else Out(@"prefsread %@", [parts componentsJoinedByString:@" | "]);
    } else if ([verb isEqualToString:@"prefslist"]) {
        // prefslist: the top pane's rows as "[group] name = value" (title-value rows use their getter)
        UIViewController *pane = ((UINavigationController *)self.presentedViewController).topViewController;
        NSMutableArray *lines = [NSMutableArray arrayWithObject:[NSString stringWithFormat:@"pane %@ \"%@\"", pane.class, pane.title]];
        for (id spec in Call(pane, @"specifiers")) {
            NSDictionary *props = Call(spec, @"properties");
            NSInteger type = ((NSInteger (*)(id, SEL))objc_msgSend)(spec, NSSelectorFromString(@"cellType"));
            NSString *name = Call(spec, @"name") ?: @"";
            if (type == 0) { [lines addObject:[NSString stringWithFormat:@"[%@] %@", name, props[@"footerText"] ?: @""]]; continue; }
            id value = props[@"key"] ? ((id (*)(id, SEL, id))objc_msgSend)(pane, NSSelectorFromString(@"readPreferenceValue:"), spec)
                                     : Call(spec, @"performGetter");
            [lines addObject:[NSString stringWithFormat:@"  %@%@", name, value ? [NSString stringWithFormat:@" = %@", value] : @""]];
        }
        Out(@"%@", [lines componentsJoinedByString:@"\n"]);
    } else if ([verb isEqualToString:@"prefstap"]) {
        // prefstap <row name>: what tapping that row does (push a page, run a button, open a setup's actions)
        UINavigationController *nav = (UINavigationController *)self.presentedViewController;
        UIViewController *pane = nav.topViewController;
        for (id spec in Call(pane, @"specifiers")) {
            if (![Call(spec, @"name") isEqual:arg]) continue;
            NSIndexPath *ip = ((id (*)(id, SEL, id))objc_msgSend)(pane, NSSelectorFromString(@"indexPathForSpecifier:"), spec);
            UITableView *table = Call(pane, @"table");
            ((void (*)(id, SEL, id, id))objc_msgSend)(pane, @selector(tableView:didSelectRowAtIndexPath:), table, ip);
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
            Out(@"prefstap %@ -> %@", arg, nav.topViewController.class);
            return;
        }
        Out(@"prefstap: no row %@", arg);
    } else if ([verb isEqualToString:@"prefsback"]) {
        [(UINavigationController *)self.presentedViewController popViewControllerAnimated:NO];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.6]];
        Out(@"prefsback -> %@", ((UINavigationController *)self.presentedViewController).topViewController.class);
    } else if ([verb isEqualToString:@"prefscall"]) {
        // prefscall <selector> [string argument]: call the top pane
        UIViewController *pane = ((UINavigationController *)self.presentedViewController).topViewController;
        NSRange sp = [arg rangeOfString:@" "];
        NSString *sel = sp.location == NSNotFound ? arg : [arg substringToIndex:sp.location];
        NSString *value = sp.location == NSNotFound ? nil : [[arg substringFromIndex:sp.location + 1] stringByReplacingOccurrencesOfString:@"\\n" withString:@"\n"];
        if (![pane respondsToSelector:NSSelectorFromString(sel)]) { Out(@"prefscall: %@ doesn't respond to %@", pane.class, sel); return; }
        ((void (*)(id, SEL, id))objc_msgSend)(pane, NSSelectorFromString(sel), value);
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
        Out(@"prefscall %@ done", sel);
    } else if ([verb isEqualToString:@"alert"] || [verb isEqualToString:@"alerttap"]) {
        // alert: the alert on screen; alerttap <button>[|<text for its field>]: fill in, then press that button
        UIViewController *top = self;
        while (top.presentedViewController) top = top.presentedViewController;
        if (![top isKindOfClass:[UIAlertController class]]) { Out(@"alert: none (top is %@)", top.class); return; }
        UIAlertController *alert = (UIAlertController *)top;
        if ([verb isEqualToString:@"alert"]) {
            Out(@"alert \"%@\" message \"%@\" buttons [%@] fields [%@]", alert.title, alert.message,
                [[alert.actions valueForKey:@"title"] componentsJoinedByString:@", "], [[alert.textFields valueForKey:@"text"] componentsJoinedByString:@", "]);
            return;
        }
        NSArray *parts = [arg componentsSeparatedByString:@"|"];
        if (parts.count > 1) alert.textFields.firstObject.text = parts[1];
        for (UIAlertAction *action in alert.actions) {
            if (![action.title isEqualToString:parts[0]]) continue;
            void (^handler)(UIAlertAction *) = [action valueForKey:@"handler"];
            [alert.presentingViewController dismissViewControllerAnimated:NO completion:^{ if (handler) handler(action); }];
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.2]];
            Out(@"alerttap %@ done", parts[0]);
            return;
        }
        Out(@"alerttap: no button %@", parts[0]);
    } else if ([verb isEqualToString:@"dismisstop"]) {
        // dismisstop: close whatever the pane presented (share sheet, file picker, alert)
        UIViewController *top = self;
        while (top.presentedViewController) top = top.presentedViewController;
        if (top == self.presentedViewController) { Out(@"dismisstop: nothing over the pane"); return; }
        [top.presentingViewController dismissViewControllerAnimated:NO completion:nil];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.8]];
        Out(@"dismissed %@", top.class);
    } else if ([verb isEqualToString:@"pbset"]) {
        UIPasteboard.generalPasteboard.string = [arg stringByReplacingOccurrencesOfString:@"\\n" withString:@"\n"];
        Out(@"pbset %lu chars", (unsigned long)UIPasteboard.generalPasteboard.string.length);
    } else if ([verb isEqualToString:@"pbget"]) {
        Out(@"pb: %@", UIPasteboard.generalPasteboard.string);
    } else if ([verb isEqualToString:@"prefsclose"]) {
        [self dismissViewControllerAnimated:NO completion:nil];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
        [self.field becomeFirstResponder];
        Out(@"prefs closed");
    } else if ([verb isEqualToString:@"imp"]) {
        // imp <Class> <selector>: implementation address as an offset into its image (for disassembly)
        NSArray *p = [arg componentsSeparatedByString:@" "];
        Class cls = NSClassFromString(p[0]);
        Method m = class_getInstanceMethod(cls, NSSelectorFromString(p[1])) ?: class_getClassMethod(cls, NSSelectorFromString(p[1]));
        IMP imp = m ? method_getImplementation(m) : NULL;
        Dl_info info = {0};
        if (imp) dladdr((void *)imp, &info);
        Out(@"imp %@ -> %s +0x%lx", arg, info.dli_fname ?: "?", imp ? (unsigned long)((char *)imp - (char *)info.dli_fbase) : 0UL);
    } else if ([verb isEqualToString:@"kbroot"]) {
        // kbroot <KBLayouts_*.dat in tmp>: what the serializer finds at offset 0 (its root index), to tmp/tpr-root.txt
        id ser = [NSClassFromString(@"TUIKBGraphSerialization") new];
        ((void (*)(id, SEL, id))objc_msgSend)(ser, NSSelectorFromString(@"setSerializedData:"),
            [NSData dataWithContentsOfFile:TmpPath(arg) options:NSDataReadingMappedIfSafe error:nil]);
        NSMutableString *s = [NSMutableString string];
        id offsets = Call(ser, @"keyboardOffsets");
        [s appendFormat:@"keyboardOffsets %@ count %lu\n", NSStringFromClass([offsets class]), (unsigned long)[offsets count]];
        if ([offsets isKindOfClass:[NSDictionary class]])
            for (id k in [[offsets allKeys] sortedArrayUsingSelector:@selector(compare:)]) [s appendFormat:@"K %@ = %@\n", k, offsets[k]];
        [s appendFormat:@"statistics %@\n", Call(ser, @"statistics")];
        [s appendFormat:@"cache %@\n", NSStringFromClass([Call(ser, @"deserializationCache") class])];
        [s writeToFile:TmpPath(@"tpr-root.txt") atomically:YES encoding:NSUTF8StringEncoding error:nil];
        Out(@"kbroot %@ -> %lu bytes", arg, (unsigned long)s.length);
    } else if ([verb isEqualToString:@"forcerebuild"]) {
        ((void (*)(id, SEL, BOOL, BOOL))objc_msgSend)(impl, NSSelectorFromString(@"setInHardwareKeyboardMode:forceRebuild:"), NO, YES);
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
        Out(@"forcerebuild done");
    } else if ([verb isEqualToString:@"ident"]) {
        NSString *plane = Call(Call(layout, @"keyplane"), @"name");
        id ident = ((id (*)(id, SEL, id))objc_msgSend)(layout, NSSelectorFromString(@"cacheIdentifierForKeyplaneNamed:"), plane);
        Out(@"ident %@ -> %@ keyplaneView=%@", plane, ident, Call(layout, @"currentKeyplaneView"));
        id token = ((id (*)(id, SEL, id, BOOL))objc_msgSend)(layout, NSSelectorFromString(@"cacheTokenForKeyplane:caseAlternates:"),
                                                        Call(layout, @"keyplane"), NO);
        id kp = Call(layout, @"keyplane");
        id firstKey = nil;
        for (id k in Call(kp, @"keys")) if ([Call(k, @"name") hasPrefix:@"TopRow"]) { firstKey = k; break; }
        Out(@"token name=%@ string=%@", Call(token, @"name"), Call(token, @"string"));
        if (firstKey && [token respondsToSelector:NSSelectorFromString(@"stringForKey:state:")])
            Out(@"token forKey(%@)=%@", Call(firstKey, @"name"),
                ((id (*)(id, SEL, id, int))objc_msgSend)(token, NSSelectorFromString(@"stringForKey:state:"), firstKey, 2));
        Out(@"token class=%@ desc=%@ str=%@", NSStringFromClass([token class]), [token description],
            [token respondsToSelector:NSSelectorFromString(@"stringForKey:")]
                ? ((id (*)(id, SEL, id))objc_msgSend)(token, NSSelectorFromString(@"stringForKey:"), Call(layout, @"keyplane")) : @"-");
    } else if ([verb isEqualToString:@"hints"]) {
        // hints: the symbol-hint labels currently on the keyboard (tag 0x5C10)
        NSMutableArray *found = [NSMutableArray array], *stack = [NSMutableArray array];
        if (LayoutStar()) [stack addObject:LayoutStar()];
        while (stack.count) {
            UIView *v = stack.lastObject; [stack removeLastObject];
            if (v.tag == 0x5C10 && !v.hidden && [v isKindOfClass:UILabel.class]) [found addObject:((UILabel *)v).text ?: @"?"];
            [stack addObjectsFromArray:v.subviews];
        }
        Out(@"hints %lu [%@]", (unsigned long)found.count, [[found sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@" "]);
    } else if ([verb isEqualToString:@"bottom"]) {
        // bottom: the inputView.bottom gap and each dock item's transform scale
        NSArray *wins = ((id (*)(id, SEL, BOOL, BOOL))objc_msgSend)(UIWindow.class,
            NSSelectorFromString(@"allWindowsIncludingInternalWindows:onlyVisibleWindows:"), YES, NO);
        NSMutableArray *stack = [wins mutableCopy];
        UIView *dock = nil;
        while (stack.count && !dock) {
            UIView *v = stack.lastObject; [stack removeLastObject];
            if ([v isKindOfClass:NSClassFromString(@"UIKeyboardDockView")]) dock = v;
            [stack addObjectsFromArray:v.subviews];
        }
        CGFloat gap = 0;
        for (NSLayoutConstraint *c in dock.superview.constraints)
            if ([c.identifier isEqualToString:@"inputView.bottom"]) gap = c.constant;
        NSMutableArray *items = [NSMutableArray array];
        for (UIView *item in dock.subviews)
            [items addObject:[NSString stringWithFormat:@"%@ s=%.2f ty=%.1f", NSStringFromClass(item.class), item.transform.a, item.transform.ty]];
        Out(@"bottom dock=%@ gap=%.1f items=[%@]", dock ? @"yes" : @"no", gap, [items componentsJoinedByString:@", "]);
    } else if ([verb isEqualToString:@"dockinfo"]) {
        // Print UIKeyboardDockView's ancestry with frames and height-related constraints.
        NSMutableString *outStr = [NSMutableString string];
        NSArray *wins = ((id (*)(id, SEL, BOOL, BOOL))objc_msgSend)(UIWindow.class,
            NSSelectorFromString(@"allWindowsIncludingInternalWindows:onlyVisibleWindows:"), YES, NO);
        NSMutableArray *stack = [wins mutableCopy];
        UIView *dock = nil;
        while (stack.count && !dock) {
            UIView *v = stack.lastObject; [stack removeLastObject];
            if ([v isKindOfClass:NSClassFromString(@"UIKeyboardDockView")]) dock = v;
            [stack addObjectsFromArray:v.subviews];
        }
        for (UIView *v = dock; v; v = v.superview) {
            [outStr appendFormat:@"%@ frame=%@\n", NSStringFromClass(v.class), NSStringFromCGRect(v.frame)];
            for (NSLayoutConstraint *c in v.constraints)
                if (c.firstAttribute == NSLayoutAttributeHeight || c.firstAttribute == NSLayoutAttributeBottom ||
                    c.firstAttribute == NSLayoutAttributeTop)
                    [outStr appendFormat:@"    %@\n", c];
        }
        [outStr writeToFile:TmpPath(@"tpr-dock.txt") atomically:YES encoding:NSUTF8StringEncoding error:nil];
        Out(@"dockinfo -> %@", dock ? @"found" : @"no dock view");
    } else if ([verb isEqualToString:@"dockgap"]) {
        // dockgap <points>: set the 'inputView.bottom' constraint's gap under the keys
        NSArray *wins = ((id (*)(id, SEL, BOOL, BOOL))objc_msgSend)(UIWindow.class,
            NSSelectorFromString(@"allWindowsIncludingInternalWindows:onlyVisibleWindows:"), YES, NO);
        NSMutableArray *stack = [wins mutableCopy];
        NSLayoutConstraint *found = nil; UIView *owner = nil;
        while (stack.count && !found) {
            UIView *v = stack.lastObject; [stack removeLastObject];
            for (NSLayoutConstraint *c in v.constraints) if ([c.identifier isEqual:@"inputView.bottom"]) { found = c; owner = v; }
            [stack addObjectsFromArray:v.subviews];
        }
        found.constant = -arg.doubleValue;
        [owner setNeedsLayout]; [owner layoutIfNeeded];
        Out(@"dockgap %@ -> %@ ownerFrame=%@", arg, found ? @"set" : @"not found", NSStringFromCGRect(owner.frame));
    } else if ([verb isEqualToString:@"props"]) {
        // props <name prefix>: properties of matching keys on the current keyplane
        NSMutableArray *parts = [NSMutableArray array];
        for (id key in Call(Call(layout, @"keyplane"), @"keys")) {
            NSString *name = Call(key, @"name");
            if (![name hasPrefix:arg]) continue;
            NSDictionary *props = Call(key, @"properties");
            NSMutableArray *kv = [NSMutableArray array];
            for (NSString *k in [props.allKeys sortedArrayUsingSelector:@selector(compare:)])
                if (![k isEqualToString:@"KBshape"]) [kv addObject:[NSString stringWithFormat:@"%@=%@", k, props[k]]];
            [parts addObject:[NSString stringWithFormat:@"%@{%@}", name, [kv componentsJoinedByString:@","]]];
        }
        Out(@"props %@: %@", arg, [parts componentsJoinedByString:@"  "]);
    } else if ([verb isEqualToString:@"variants"]) {
        // variants <name prefix>: long-press variants UIKit would show for matching keys
        id keyplane = Call(layout, @"keyplane");
        NSMutableArray *parts = [NSMutableArray array];
        for (id key in Call(keyplane, @"keys")) {
            NSString *name = Call(key, @"name");
            if (![name hasPrefix:arg]) continue;
            BOOL has = ((BOOL (*)(id, SEL, id))objc_msgSend)(layout, NSSelectorFromString(@"keyHasAccentedVariants:"), key);
            ((void (*)(id, SEL, id, id))objc_msgSend)(layout, NSSelectorFromString(@"preparePopupVariantsForKey:onKeyplane:"), key, keyplane);
            NSMutableArray *v = [NSMutableArray array];
            for (id sub in Call(key, @"subtrees")) [v addObject:Call(sub, @"displayString") ?: @"?"];
            [parts addObject:[NSString stringWithFormat:@"%@%@[%@]", Call(key, @"displayString"), has ? @"*" : @"",
                              [v componentsJoinedByString:@" "]]];
        }
        Out(@"variants %@: %@", arg, [parts componentsJoinedByString:@"  "]);
    } else if ([verb isEqualToString:@"inputmode"]) {
        // inputmode <identifier, e.g. de_DE@sw=QWERTZ-German;hw=Automatic>
        ((void (*)(id, SEL, id, BOOL))objc_msgSend)(impl, NSSelectorFromString(@"setInputMode:userInitiated:"), arg, YES);
        [self.field resignFirstResponder];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
        [self.field becomeFirstResponder];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
        Out(@"inputmode %@ -> keyboardName=%@ layoutFrame=%@", arg, Call(LayoutStar(), @"keyboardName"),
            LayoutStar() ? NSStringFromCGRect([(UIView *)LayoutStar() frame]) : @"?");
    } else if ([verb isEqualToString:@"appearance"]) {
        // appearance <0 default | 1 dark | 2 light>: the field's keyboardAppearance
        [self.field resignFirstResponder];
        self.field.keyboardAppearance = (UIKeyboardAppearance)arg.integerValue;
        [self.field becomeFirstResponder];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
        Out(@"appearance %@", arg);
    } else if ([verb isEqualToString:@"secure"]) {
        [self.field resignFirstResponder];
        self.field.secureTextEntry = arg.boolValue;
        [self.field becomeFirstResponder];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
        Out(@"secure %@ -> keyboardName=%@ layoutFrame=%@", arg, Call(LayoutStar(), @"keyboardName"),
            LayoutStar() ? NSStringFromCGRect([(UIView *)LayoutStar() frame]) : @"?");
    } else if ([verb isEqualToString:@"swipe"]) {
        // swipe <x> <y> <dy>
        NSArray *a = [arg componentsSeparatedByString:@" "];
        SwipeLayoutPoint(layout, CGPointMake([a[0] doubleValue], [a[1] doubleValue]), [a[2] doubleValue]);
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.4]];
        Out(@"swipe %@ -> field=\"%@\"", arg, self.field.text);
    } else if ([verb isEqualToString:@"wait"]) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:arg.doubleValue ?: 0.3]];
    } else if ([verb isEqualToString:@"hitrow"]) {
        // hitrow <y>: hit-test 10 evenly spaced points across the keyplane at height y
        CGFloat y = arg.doubleValue, w = [(UIView *)layout frame].size.width;
        NSMutableArray *parts = [NSMutableArray array];
        for (int i = 0; i < 10; i++) {
            CGPoint pt = CGPointMake(w * (i + 0.5) / 10.0, y);
            id key = ((id (*)(id, SEL, CGPoint))objc_msgSend)(layout, NSSelectorFromString(@"keyHitTest:"), pt);
            NSDictionary *props = Call(key, @"properties");
            [parts addObject:[NSString stringWithFormat:@"%@=>%@", Call(key, @"name") ?: @"nil",
                              props[@"KBrepresentedString"] ?: @"?"]];
        }
        Out(@"hitrow y=%.0f [%@] %@", y, Call(Call(layout, @"keyplane"), @"name"), [parts componentsJoinedByString:@" "]);
    } else if ([verb isEqualToString:@"tapchar"]) {
        SEL sel = NSSelectorFromString(@"simulateTouchForCharacter:errorVector:shouldTypeVariants:baseKeyForVariants:");
        CGPoint pt = ((CGPoint (*)(id, SEL, id, CGPoint, BOOL, BOOL))objc_msgSend)(layout, sel, arg, CGPointZero, NO, NO);
        Out(@"tapchar %@ at %@ -> field=\"%@\"", arg, NSStringFromCGPoint(pt), self.field.text);
    } else if ([verb isEqualToString:@"methods"]) {
        Class cls = NSClassFromString(arg);
        NSMutableString *s = [NSMutableString stringWithFormat:@"%@ : %@\n", arg, NSStringFromClass(class_getSuperclass(cls))];
        for (int meta = 0; meta < 2; meta++) {
            unsigned int n = 0;
            Method *list = class_copyMethodList(meta ? object_getClass((id)cls) : cls, &n);
            for (unsigned int i = 0; i < n; i++)
                [s appendFormat:@"%@%@ %s\n", meta ? @"+" : @"-", NSStringFromSelector(method_getName(list[i])),
                 method_getTypeEncoding(list[i])];
            free(list);
        }
        NSString *path = TmpPath([NSString stringWithFormat:@"tpr-methods-%@.txt", arg]);
        [s writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        Out(@"methods %@ -> %@", arg, path);
    } else if ([verb isEqualToString:@"text"]) {
        Out(@"field=\"%@\"", self.field.text);
    } else if ([verb isEqualToString:@"clear"]) {
        self.field.text = @"";
        Out(@"cleared");
    } else if ([verb isEqualToString:@"info"]) {
        Out(@"keyboardName=%@ keyplane=%@ layoutFrame=%@", Call(layout, @"keyboardName"),
            Call(Call(layout, @"keyplane"), @"name"), layout ? NSStringFromCGRect([(UIView *)layout frame]) : @"?");
    } else {
        Out(@"unknown command %@", verb);
    }
}

@end

// ---- app ----------------------------------------------------------------------

@interface TPRHostAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

static TPRHostViewController *gVC;

static void OnCommand(CFNotificationCenterRef c, void *o, CFNotificationName n, const void *obj, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{ [gVC runCommands]; });
}

@implementation TPRHostAppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    gVC = [TPRHostViewController new];
    self.window.rootViewController = gVC;
    [self.window makeKeyAndVisible];
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, OnCommand,
                                    CFSTR("dev.rtrdd.tprhost.cmd"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    Out(@"TPRHost launched; tmp=%@", NSTemporaryDirectory());
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([TPRHostAppDelegate class]));
    }
}
