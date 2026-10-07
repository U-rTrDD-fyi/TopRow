#import <Foundation/Foundation.h>

// The prefs file the tweak reads (see tweak/TPRConfig.m). Written directly, not via
// cfprefsd, so sandboxed apps can read it; every write posts the reload notification.
NSDictionary *TPRPrefsRead(void);
void TPRPrefsSet(NSString *key, id value);
void TPRPrefsReset(void);

// Characters as shown: an emoji counts as one.
NSUInteger TPRPrefsCharacterCount(NSString *text);
// nil if `text` is a valid row (<= 10 space-separated keys, each <= 8 characters), else why not.
NSString *TPRPrefsRowProblem(NSString *text);

// Allowed percentages for a size key (location = min, length = max - min), or {0, 0}.
NSRange TPRPrefsSizeRange(NSString *key);
// nil if `value` (number or text) is a whole percentage in range; *number gets it.
NSString *TPRPrefsSizeProblem(NSString *key, id value, NSNumber **number);
