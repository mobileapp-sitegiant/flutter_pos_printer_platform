#import <Foundation/Foundation.h>
#import "EscPosToken.h"

/// Splits an ESC/POS byte stream into command-aligned tokens so a paced
/// Bluetooth writer can pause between commands but never inside one.
/// Covers the command set emitted by flutter_esc_pos_utils / esc_pos_utils_plus
/// (text, ESC/GS/FS style commands, ESC * column bit images, GS v 0 and
/// GS ( L raster images, GS k barcodes, GS ( k QR codes, cash-drawer pulses).
/// Unknown two-byte prefixes are kept atomic; following bytes are treated as
/// text.
@interface EscPosTokenizer : NSObject
+ (NSArray<EscPosToken *> *)tokenize:(NSData *)data;
@end
