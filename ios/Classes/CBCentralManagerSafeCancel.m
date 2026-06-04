//
//  CBCentralManagerSafeCancel.m
//  flutter_pos_printer_platform
//
//  GSDK (libGSDK.a) calls cancelPeripheralConnection: with a nil peripheral
//  from its connect-timeout timer, which trips CoreBluetooth's NSAssert and
//  crashes the app (Sentry SITEGIANT-POS-1VG). The binary cannot be patched,
//  so guard the call at runtime: nil peripheral -> log + no-op.
//

#import <CoreBluetooth/CoreBluetooth.h>
#import <objc/runtime.h>

@interface CBCentralManager (SafeCancel)
@end

@implementation CBCentralManager (SafeCancel)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method original = class_getInstanceMethod(self, @selector(cancelPeripheralConnection:));
        Method swizzled = class_getInstanceMethod(self, @selector(sg_cancelPeripheralConnection:));
        if (original != NULL && swizzled != NULL) {
            method_exchangeImplementations(original, swizzled);
        }
    });
}

- (void)sg_cancelPeripheralConnection:(CBPeripheral *)peripheral {
    if (peripheral == nil) {
        NSLog(@"[flutter_pos_printer_platform] cancelPeripheralConnection: called with nil peripheral - ignored");
        return;
    }
    // Calls the original implementation (implementations are exchanged).
    [self sg_cancelPeripheralConnection:peripheral];
}

@end
