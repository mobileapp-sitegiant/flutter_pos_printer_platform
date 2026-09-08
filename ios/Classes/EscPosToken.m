#import "EscPosToken.h"

@implementation EscPosToken
+ (instancetype)tokenWithRange:(NSRange)range atomic:(BOOL)atomic {
    EscPosToken *token = [EscPosToken new];
    token.range = range;
    token.atomic = atomic;
    return token;
}
@end
