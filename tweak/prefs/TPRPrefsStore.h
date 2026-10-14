#import <Foundation/Foundation.h>

// The prefs file the tweak reads (see tweak/TPRConfig.m). Written directly, not via
// cfprefsd, so sandboxed apps can read it; every write posts the reload notification.
NSDictionary *TPRPrefsRead(void);
void TPRPrefsSet(NSString *key, id value);
void TPRPrefsReset(void);
// Removes several keys with one write (and one reload).
void TPRPrefsRemove(NSArray<NSString *> *keys);
// Replaces every setting with one write (and one reload).
void TPRPrefsReplace(NSDictionary *prefs);

// The prefs file as bytes (empty if missing), and what this process last wrote there, so a
// page can tell another app's change (refresh) from its own (already on screen).
NSData *TPRPrefsFileData(void);
NSData *TPRPrefsLastWrittenData(void);
// Posted (Darwin) after every write, here and by the setups store.
extern NSString *const TPRPrefsReloadNotification;

// Characters as shown: an emoji counts as one.
NSUInteger TPRPrefsCharacterCount(NSString *text);
// nil if `text` is a valid row (<= 10 space-separated keys, each <= 8 characters), else why not.
NSString *TPRPrefsRowProblem(NSString *text);

// nil if `text` is a valid Keys-page row (<= 12 space-separated keys, each <= 8 characters), else why not.
NSString *TPRPrefsKeyRowProblem(NSString *text);

// Allowed percentages for a size key (location = min, length = max - min), or {0, 0}.
NSRange TPRPrefsSizeRange(NSString *key);
// nil if `value` (number or text) is a whole percentage in range; *number gets it.
NSString *TPRPrefsSizeProblem(NSString *key, id value, NSNumber **number);
