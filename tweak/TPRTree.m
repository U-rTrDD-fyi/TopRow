#import "TPRTree.h"

static Class TreeClass(void) {
    static Class cls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cls = NSClassFromString(@"UIKBTree"); });
    return cls;
}

static Class ShapeClass(void) {
    static Class cls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cls = NSClassFromString(@"UIKBShape"); });
    return cls;
}

BOOL TPRIsTree(id obj) { return TreeClass() && [obj isKindOfClass:TreeClass()]; }
BOOL TPRIsShape(id obj) { return ShapeClass() && [obj isKindOfClass:ShapeClass()]; }

int TPRType(id node) {
    return TPRIsTree(node) && [node respondsToSelector:@selector(type)] ? [(id<TPRKBTree>)node type] : -1;
}

NSString *TPRName(id node) {
    id name = TPRIsTree(node) && [node respondsToSelector:@selector(name)] ? [(id<TPRKBTree>)node name] : nil;
    return [name isKindOfClass:[NSString class]] ? name : nil;
}

NSArray *TPRSubtrees(id node) {
    id subtrees = TPRIsTree(node) && [node respondsToSelector:@selector(subtrees)] ? [(id<TPRKBTree>)node subtrees] : nil;
    return [subtrees isKindOfClass:[NSArray class]] ? subtrees : nil;
}

NSDictionary *TPRProperties(id node) {
    id props = TPRIsTree(node) && [node respondsToSelector:@selector(properties)] ? [(id<TPRKBTree>)node properties] : nil;
    return [props isKindOfClass:[NSDictionary class]] ? props : nil;
}

id TPRChildOfType(id node, int type) {
    for (id child in TPRSubtrees(node))
        if (TPRType(child) == type) return child;
    return nil;
}

id TPRShapeOf(id shapeOrNode) {
    if (TPRIsShape(shapeOrNode)) return shapeOrNode;
    id shape = TPRProperties(shapeOrNode)[@"KBshape"];
    return TPRIsShape(shape) ? shape : nil;
}

BOOL TPRGetFrames(id shapeOrNode, CGRect *frame, CGRect *padded) {
    id<TPRKBShape> shape = TPRShapeOf(shapeOrNode);
    if (![shape respondsToSelector:@selector(frame)] || ![shape respondsToSelector:@selector(paddedFrame)]) return NO;
    if (frame) *frame = [shape frame];
    if (padded) *padded = [shape paddedFrame];
    return YES;
}

BOOL TPRSetFrames(id shapeOrNode, CGRect frame, CGRect padded) {
    id<TPRKBShape> shape = TPRShapeOf(shapeOrNode);
    if (![shape respondsToSelector:@selector(setFrame:)] || ![shape respondsToSelector:@selector(setPaddedFrame:)]) return NO;
    [shape setFrame:frame];
    [shape setPaddedFrame:padded];
    return YES;
}

// ---- debug description ------------------------------------------------------

static NSString *DescribeValue(id v) {
    if ([v isKindOfClass:[NSString class]]) return [NSString stringWithFormat:@"\"%@\"", v];
    if ([v isKindOfClass:[NSNumber class]]) return [v description];
    if (TPRIsShape(v)) {
        CGRect f = CGRectNull, p = CGRectNull;
        TPRGetFrames(v, &f, &p);
        id geometry = [v respondsToSelector:@selector(geometry)] ? [v performSelector:@selector(geometry)] : nil;
        return [NSString stringWithFormat:@"<shape %p f=%@ p=%@%@>", v, NSStringFromCGRect(f), NSStringFromCGRect(p),
                geometry ? [NSString stringWithFormat:@" geom=%@", [geometry description]] : @""];
    }
    if ([v isKindOfClass:[NSDictionary class]]) {
        NSMutableArray *parts = [NSMutableArray array];
        for (id k in v) [parts addObject:[NSString stringWithFormat:@"%@=%@", k, DescribeValue(v[k])]];
        return [NSString stringWithFormat:@"{%@}", [parts componentsJoinedByString:@", "]];
    }
    if ([v isKindOfClass:[NSArray class]]) return [NSString stringWithFormat:@"<array %lu>", (unsigned long)[v count]];
    return [NSString stringWithFormat:@"<%@ %p>", NSStringFromClass([v class]), v];
}

static void Describe(id node, int depth, NSMutableString *out, NSHashTable *seen) {
    NSString *pad = [@"" stringByPaddingToLength:(NSUInteger)depth * 2 withString:@" " startingAtIndex:0];
    if (!TPRIsTree(node)) {
        [out appendFormat:@"%@- %@\n", pad, DescribeValue(node)];
        return;
    }
    BOOL again = [seen containsObject:node];
    [seen addObject:node];
    [out appendFormat:@"%@[%d] %@ %p%@\n", pad, TPRType(node), TPRName(node), node, again ? @" (SHARED)" : @""];
    if (again) return;
    NSDictionary *props = TPRProperties(node);
    NSArray *keys = [[props allKeys] sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        return [[a description] compare:[b description]];
    }];
    for (id k in keys) [out appendFormat:@"%@    . %@ = %@\n", pad, k, DescribeValue(props[k])];
    id cache = [node respondsToSelector:@selector(cache)] ? [(id<TPRKBTree>)node cache] : nil;
    if ([cache isKindOfClass:[NSDictionary class]] && [cache count])
        [out appendFormat:@"%@    ~ cache %@\n", pad, [[cache allKeys] componentsJoinedByString:@","]];
    for (id child in TPRSubtrees(node)) Describe(child, depth + 1, out, seen);
}

NSString *TPRDescribeTree(id node) {
    NSMutableString *out = [NSMutableString string];
    Describe(node, 0, out, [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality]);
    return out;
}
