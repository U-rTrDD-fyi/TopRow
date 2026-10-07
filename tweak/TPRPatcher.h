#import <Foundation/Foundation.h>
@class TPRConfig;

// Returns a patched copy of `keyboard` with the extra row added, or nil if the
// keyboard should be used unchanged. Never mutates `keyboard` itself: the
// serializer caches and shares those nodes. *outcome receives a log line.
id TPRPatchKeyboard(id keyboard, NSString *name, TPRConfig *config, NSString **outcome);

// For the "lowercase row while auto-capitalized" option: relabel the extra row on a
// shifted letters keyplane UIKit is showing. Returns YES if anything changed.
BOOL TPRRelabelShiftedRow(id keyplane, BOOL autoShifted, BOOL landscape, TPRConfig *config);
// YES for landscape keyboard trees (by name or by design-frame aspect ratio).
BOOL TPRIsLandscapeKeyboard(id keyboard, NSString *name);
// YES for keyplanes of a keyboard TPRPatchKeyboard returned (custom 123/ABC labels go only there).
BOOL TPRIsPatchedKeyplane(id keyplane);
