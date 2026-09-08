#import <Foundation/Foundation.h>

/// One unit of an ESC/POS byte stream. `atomic` units are complete commands
/// whose bytes must reach the printer without a pause in the middle (a slow
/// parameter stream makes printer firmware abort the command and print the
/// remaining bytes as text). Non-atomic units (text runs, raster image data)
/// may be split and paced freely.
@interface EscPosToken : NSObject
@property(nonatomic, assign) NSRange range;
@property(nonatomic, assign) BOOL atomic;
+ (instancetype)tokenWithRange:(NSRange)range atomic:(BOOL)atomic;
@end
