#import "TPRBaseListController.h"

// "Keyboard Types": which special keyboards (email, web, Twitter) get the extra row.
@interface TPRKeyboardTypesController : TPRBaseListController
@end

@implementation TPRKeyboardTypesController

- (NSArray *)specifiers {
    if (!_specifiers) _specifiers = [self loadSpecifiersFromPlistName:@"KeyboardTypes" target:self];
    return _specifiers;
}

@end
