// Minimal declarations for the private UIKit keyboard-layout classes we touch.
// Accessors in TPRTree.m check the class and respondsToSelector: first, so a
// missing or renamed method on some iOS version makes the patch bail instead of
// crashing the host app.

#import <UIKit/UIKit.h>

// UIKBTree node types, as observed in the iOS 17/18 keyboard graph.
typedef NS_ENUM(int, TPRNodeType) {
    TPRNodeKeyboard     = 1,
    TPRNodeKeyplane     = 2,
    TPRNodeKeylayout    = 3,
    TPRNodeKeyset       = 4,
    TPRNodeGeometrySet  = 5,
    TPRNodeAttributeSet = 6,
    TPRNodeList         = 7,   // one row: keys (keyset), shapes (geometry set) or attribute dicts
    TPRNodeKey          = 8,
};

@protocol TPRKBTree <NSObject, NSCopying>
- (int)type;
- (NSString *)name;
- (void)setName:(NSString *)name;
- (NSMutableDictionary *)properties;
- (void)setProperties:(NSMutableDictionary *)properties;
- (NSMutableArray *)subtrees;
- (void)setSubtrees:(NSMutableArray *)subtrees;
- (NSMutableDictionary *)cache;
- (void)setCache:(NSMutableDictionary *)cache;
- (BOOL)isAlphabeticPlane;
- (BOOL)isShiftKeyplane;
@end

@protocol TPRKBShape <NSObject, NSCopying>
- (CGRect)frame;
- (void)setFrame:(CGRect)frame;
- (CGRect)paddedFrame;
- (void)setPaddedFrame:(CGRect)frame;
@end

BOOL TPRIsTree(id obj);
BOOL TPRIsShape(id obj);
int TPRType(id node);
NSString *TPRName(id node);
NSArray *TPRSubtrees(id node);
NSDictionary *TPRProperties(id node);
id TPRChildOfType(id node, int type);
id TPRShapeOf(id shapeOrNode);
BOOL TPRGetFrames(id shapeOrNode, CGRect *frame, CGRect *padded);
BOOL TPRSetFrames(id shapeOrNode, CGRect frame, CGRect padded);
NSString *TPRDescribeTree(id node);
