#import "EscPosTokenizer.h"

static const uint8_t kLF = 0x0a;
static const uint8_t kESC = 0x1b;
static const uint8_t kFS = 0x1c;
static const uint8_t kGS = 0x1d;

static NSUInteger clampLength(NSUInteger length, NSUInteger offset, NSUInteger total) {
    if (offset + length > total) {
        return total - offset;
    }
    return length;
}

static uint8_t byteAt(const uint8_t *bytes, NSUInteger index, NSUInteger total) {
    return index < total ? bytes[index] : 0;
}

/// Length of the ESC-prefixed command starting at `i`, or 0 for ESC * which is
/// handled by the caller.
static NSUInteger escCommandLength(const uint8_t *b, NSUInteger i, NSUInteger n) {
    switch (byteAt(b, i + 1, n)) {
        case '@': case '2':
            return 2;
        case '!': case '-': case 'E': case 'M': case 'V': case 't': case 'a':
        case 'd': case 'e': case '3': case 'R': case 'G': case 'J': case 'c':
        case ' ': case 'r': case 'U': case '{': case 'S': case 'T': case 'W':
            return 3;
        case '$': case 'B': case '\\': case 'L':
            return 4;
        case 'p':
            return 5;
        default:
            return 2;
    }
}

static NSUInteger fsCommandLength(const uint8_t *b, NSUInteger i, NSUInteger n) {
    switch (byteAt(b, i + 1, n)) {
        case '&': case '.': case 'p': case 'q':
            return 2;
        case 'C': case 'W': case '-': case '!': case 'S':
            return 3;
        default:
            return 2;
    }
}

@implementation EscPosTokenizer

+ (NSArray<EscPosToken *> *)tokenize:(NSData *)data {
    NSMutableArray<EscPosToken *> *tokens = [NSMutableArray new];
    const uint8_t *b = data.bytes;
    const NSUInteger n = data.length;
    NSUInteger i = 0;

    while (i < n) {
        const uint8_t c = b[i];

        if (c == kLF) {
            [tokens addObject:[EscPosToken tokenWithRange:NSMakeRange(i, 1) atomic:NO]];
            i += 1;
            continue;
        }

        if (c == kESC) {
            if (byteAt(b, i + 1, n) == '*') {
                // ESC * m nL nH d1..dk ; k = n * (m >= 32 ? 3 : 1)
                const uint8_t m = byteAt(b, i + 2, n);
                const NSUInteger cols = byteAt(b, i + 3, n) | (byteAt(b, i + 4, n) << 8);
                const NSUInteger k = cols * (m >= 32 ? 3 : 1);
                NSUInteger len = clampLength(5 + k, i, n);
                [tokens addObject:[EscPosToken tokenWithRange:NSMakeRange(i, len) atomic:YES]];
                i += len;
                continue;
            }
            NSUInteger len = clampLength(escCommandLength(b, i, n), i, n);
            [tokens addObject:[EscPosToken tokenWithRange:NSMakeRange(i, len) atomic:YES]];
            i += len;
            continue;
        }

        if (c == kFS) {
            NSUInteger len = clampLength(fsCommandLength(b, i, n), i, n);
            [tokens addObject:[EscPosToken tokenWithRange:NSMakeRange(i, len) atomic:YES]];
            i += len;
            continue;
        }

        if (c == kGS) {
            const uint8_t sub = byteAt(b, i + 1, n);
            if (sub == 'v' && byteAt(b, i + 2, n) == '0') {
                // GS v 0 m xL xH yL yH d1..dk ; k = (xL|xH<<8) * (yL|yH<<8)
                const NSUInteger widthBytes = byteAt(b, i + 4, n) | (byteAt(b, i + 5, n) << 8);
                const NSUInteger rows = byteAt(b, i + 6, n) | (byteAt(b, i + 7, n) << 8);
                NSUInteger header = clampLength(8, i, n);
                [tokens addObject:[EscPosToken tokenWithRange:NSMakeRange(i, header) atomic:YES]];
                i += header;
                NSUInteger dataLen = clampLength(widthBytes * rows, i, n);
                if (dataLen > 0) {
                    [tokens addObject:[EscPosToken tokenWithRange:NSMakeRange(i, dataLen) atomic:NO]];
                    i += dataLen;
                }
                continue;
            }
            if (sub == '(') {
                // GS ( x pL pH d1..dk
                const uint8_t fn = byteAt(b, i + 2, n);
                const NSUInteger k = byteAt(b, i + 3, n) | (byteAt(b, i + 4, n) << 8);
                if (fn == 'L') {
                    // Raster graphics: keep the header atomic, stream the data.
                    NSUInteger header = clampLength(5, i, n);
                    [tokens addObject:[EscPosToken tokenWithRange:NSMakeRange(i, header) atomic:YES]];
                    i += header;
                    NSUInteger dataLen = clampLength(k, i, n);
                    if (dataLen > 0) {
                        [tokens addObject:[EscPosToken tokenWithRange:NSMakeRange(i, dataLen) atomic:NO]];
                        i += dataLen;
                    }
                    continue;
                }
                NSUInteger len = clampLength(5 + k, i, n);
                [tokens addObject:[EscPosToken tokenWithRange:NSMakeRange(i, len) atomic:YES]];
                i += len;
                continue;
            }
            if (sub == 'k') {
                // GS k m d1..dk NUL  (m <= 6)   |   GS k m n d1..dn  (m >= 65)
                const uint8_t m = byteAt(b, i + 2, n);
                NSUInteger len;
                if (m <= 6) {
                    NSUInteger j = i + 3;
                    while (j < n && b[j] != 0x00) {
                        j++;
                    }
                    len = clampLength((j - i) + 1, i, n);
                } else {
                    len = clampLength(4 + byteAt(b, i + 3, n), i, n);
                }
                [tokens addObject:[EscPosToken tokenWithRange:NSMakeRange(i, len) atomic:YES]];
                i += len;
                continue;
            }
            NSUInteger len;
            switch (sub) {
                case 'V': {
                    const uint8_t m = byteAt(b, i + 2, n);
                    len = (m == 65 || m == 66 || m == 97 || m == 98) ? 4 : 3;
                    break;
                }
                case 'L': case 'W': case '$': case '\\': case 'P':
                    len = 4;
                    break;
                case 'B': case '!': case 'H': case 'f': case 'h': case 'w':
                case 'E': case 'T': case 'a': case 'b': case 'r': case 'I':
                    len = 3;
                    break;
                default:
                    len = 2;
                    break;
            }
            len = clampLength(len, i, n);
            [tokens addObject:[EscPosToken tokenWithRange:NSMakeRange(i, len) atomic:YES]];
            i += len;
            continue;
        }

        // Text run up to the next control byte.
        NSUInteger j = i + 1;
        while (j < n && b[j] != kLF && b[j] != kESC && b[j] != kFS && b[j] != kGS) {
            j++;
        }
        [tokens addObject:[EscPosToken tokenWithRange:NSMakeRange(i, j - i) atomic:NO]];
        i = j;
    }
    return tokens;
}

@end
