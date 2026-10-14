#import <UIKit/UIKit.h>

// The share sheet for text TopRow hands out (diagnostics, setups): a .txt file for Save to
// Files, AirDrop, Mail and the rest, except Copy, which gets the plain text. Earlier files
// are removed first. Returns nil, or why the file couldn't be written.
NSString *TPRShareText(UIViewController *from, UIView *anchor, NSString *text, NSString *fileName, NSString *subject);
