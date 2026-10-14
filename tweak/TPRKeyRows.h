// Apple's key rows on the four keyplanes TopRow lets you edit (US QWERTY), shared by
// the tweak and the Settings pane. Header-only so both targets build it in.

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, TPRKeyPlane) {
    TPRKeyPlaneLetters,   // small letters
    TPRKeyPlaneShifted,   // Shift / Caps Lock
    TPRKeyPlaneNumbers,   // 123
    TPRKeyPlaneSymbols,   // #+=
};
#define TPRKeyPlaneCount 4
#define TPRKeyRowCount 3
#define TPRMaxRowKeys 12
#define TPRMaxKeyLength 8

// The row as Settings shows it. A key typed there that is in Apple's row keeps
// Apple's key (accents on long-press, the region's currency sign, ...).
static inline NSString *TPRStockKeyRow(TPRKeyPlane plane, NSUInteger row) {
    static NSString *const rows[TPRKeyPlaneCount][TPRKeyRowCount] = {
        { @"q w e r t y u i o p", @"a s d f g h j k l", @"z x c v b n m" },
        { @"Q W E R T Y U I O P", @"A S D F G H J K L", @"Z X C V B N M" },
        { @"1 2 3 4 5 6 7 8 9 0", @"- / : ; ( ) $ & @ \"", @". , ? ! '" },
        { @"[ ] { } # % ^ * + =", @"_ \\ | ~ < > € £ ¥ •", @". , ? ! '" },
    };
    return (NSUInteger)plane < TPRKeyPlaneCount && row < TPRKeyRowCount ? rows[plane][row] : nil;
}

// What Apple's keys in that row type (KBrepresentedString), to recognize the row in a
// keyboard: "¤1" to "¤4" are the currency keys UIKit localizes. Other layouts (AZERTY,
// the email and URL 123 pages, ...) don't match and stay as they are.
static inline NSString *TPRStockKeySignature(TPRKeyPlane plane, NSUInteger row) {
    static NSString *const rows[TPRKeyPlaneCount][TPRKeyRowCount] = {
        { @"q w e r t y u i o p", @"a s d f g h j k l", @"z x c v b n m" },
        { @"Q W E R T Y U I O P", @"A S D F G H J K L", @"Z X C V B N M" },
        { @"1 2 3 4 5 6 7 8 9 0", @"- / : ; ( ) ¤1 & @ \"", @". , ? ! '" },
        { @"[ ] { } # % ^ * + =", @"_ \\ | ~ < > ¤2 ¤3 ¤4 •", @". , ? ! '" },
    };
    return (NSUInteger)plane < TPRKeyPlaneCount && row < TPRKeyRowCount ? rows[plane][row] : nil;
}

// Prefs key for a row, e.g. "KeyRowLetters1".
static inline NSString *TPRKeyRowPrefsKey(TPRKeyPlane plane, NSUInteger row) {
    static NSString *const names[TPRKeyPlaneCount] = { @"Letters", @"Shifted", @"Numbers", @"Symbols" };
    return [NSString stringWithFormat:@"KeyRow%@%lu", names[plane], (unsigned long)row + 1];
}

// "a  b c" -> @[@"a", @"b", @"c"].
static inline NSArray<NSString *> *TPRSplitKeys(NSString *text) {
    NSMutableArray *keys = [NSMutableArray array];
    for (NSString *part in [text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet])
        if (part.length) [keys addObject:part];
    return keys;
}
