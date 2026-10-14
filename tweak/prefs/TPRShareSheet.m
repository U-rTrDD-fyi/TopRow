#import "TPRShareSheet.h"

@interface TPRShareItem : NSObject <UIActivityItemSource>
@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy) NSURL *file;
@property (nonatomic, copy) NSString *subject;
@end

@implementation TPRShareItem

- (id)activityViewControllerPlaceholderItem:(UIActivityViewController *)controller {
    return self.file;
}

- (id)activityViewController:(UIActivityViewController *)controller itemForActivityType:(UIActivityType)type {
    return [type isEqualToString:UIActivityTypeCopyToPasteboard] ? self.text : self.file;
}

- (NSString *)activityViewController:(UIActivityViewController *)controller subjectForActivityType:(UIActivityType)type {
    return self.subject;
}

@end

NSString *TPRShareText(UIViewController *from, UIView *anchor, NSString *text, NSString *fileName, NSString *subject) {
    NSFileManager *files = NSFileManager.defaultManager;
    for (NSString *old in [files contentsOfDirectoryAtPath:NSTemporaryDirectory() error:NULL])
        if ([old hasPrefix:@"TopRow"] && [old.pathExtension isEqualToString:@"txt"])
            [files removeItemAtPath:[NSTemporaryDirectory() stringByAppendingPathComponent:old] error:NULL];
    // File names can't hold "/" or ":" (a setup's name might).
    NSString *safe = [[fileName componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/:\\"]]
                      componentsJoinedByString:@"-"];
    NSURL *file = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:safe]];
    NSError *error;
    if (![text writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:&error]) return error.localizedDescription;
    TPRShareItem *item = [TPRShareItem new];
    item.text = text;
    item.file = file;
    item.subject = subject;
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[ item ]
                                                                        applicationActivities:nil];
    anchor = anchor ?: from.view;   // popover anchor (iPad)
    share.popoverPresentationController.sourceView = anchor;
    share.popoverPresentationController.sourceRect = anchor.bounds;
    [from presentViewController:share animated:YES completion:nil];
    return nil;
}
