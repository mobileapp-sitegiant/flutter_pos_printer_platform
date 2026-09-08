#import "FlutterPosPrinterPlatformPlugin.h"
#import "ConnecterManager.h"
#import "EscPosTokenizer.h"

// Paced Bluetooth LE writer
//
// Bluetooth LE thermal printers (XPrinter and similar) have a small receive
// buffer and no flow control above the link layer. GSDK's -[ConnecterManager
// write:] pushes data as fast as CoreBluetooth accepts it, so any payload
// larger than the printer's buffer is partly dropped: the receipt prints as
// garbage, stops halfway, or comes out as a single line feed.
//
// The writer below sends the payload as command-aligned units (see
// EscPosTokenizer) and, after each unit, waits roughly as long as the print
// head needs to physically render it (feed distance at a worst-case print
// speed). Pauses never fall inside a command: firmware aborts a command whose
// parameter bytes stall and prints the remainder as text.
static const NSUInteger kBleMaxChunkBytes = 244;
static const NSTimeInterval kBleLinkBusyRetry = 0.005;
static const double kPrintSpeedMmPerMs = 0.08;   // 80 mm/s, slowest common tier
static const double kDotsPerMm = 8.0;            // 203 dpi
static const NSUInteger kTextLineHeightDots = 32; // font A line + spacing, conservative
static const double kFeedSafetyMarginMs = 5.0;   // per feeding unit, covers link jitter
static const double kCutSettleMs = 500.0;         // autocutter mechanical cycle
static const double kUnknownDataBytesPerMs = 8.0; // fallback: 8 KB/s for unparsed data

@interface FlutterPosPrinterPlatformPlugin ()
@property(nonatomic, retain) NSObject<FlutterPluginRegistrar> *registrar;
@property(nonatomic, retain) FlutterMethodChannel *channel;
@property(nonatomic, retain) BluetoothPrintStreamHandler *stateStreamHandler;
@property(nonatomic) NSMutableDictionary *scannedPeripherals;
@property(nonatomic, strong) NSMutableArray<NSData *> *pendingWrites;
@property(nonatomic, assign) BOOL bleWriteInProgress;
@end

@implementation FlutterPosPrinterPlatformPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  FlutterMethodChannel* channel = [FlutterMethodChannel
      methodChannelWithName:NAMESPACE @"/methods"
            binaryMessenger:[registrar messenger]];
  FlutterEventChannel* stateChannel = [FlutterEventChannel eventChannelWithName:NAMESPACE @"/state" binaryMessenger:[registrar messenger]];
  FlutterPosPrinterPlatformPlugin* instance = [[FlutterPosPrinterPlatformPlugin alloc] init];

  instance.channel = channel;
  instance.scannedPeripherals = [NSMutableDictionary new];
    
  // STATE
  BluetoothPrintStreamHandler* stateStreamHandler = [[BluetoothPrintStreamHandler alloc] init];
  [stateChannel setStreamHandler:stateStreamHandler];
  instance.stateStreamHandler = stateStreamHandler;

  [registrar addMethodCallDelegate:instance channel:channel];
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  NSLog(@"call method -> %@", call.method);
    
  if ([@"state" isEqualToString:call.method]) {
    result(nil);
  } else if([@"isAvailable" isEqualToString:call.method]) {
    
    result(@(YES));
  } else if([@"isConnected" isEqualToString:call.method]) {
    
    result(@(NO));
  } else if([@"isOn" isEqualToString:call.method]) {
    result(@(YES));
  }else if([@"startScan" isEqualToString:call.method]) {
      NSLog(@"getDevices method -> %@", call.method);
      [self.scannedPeripherals removeAllObjects];
      
      if (Manager.bleConnecter == nil) {
          [Manager didUpdateState:^(NSInteger state) {
              switch (state) {
                  case CBCentralManagerStateUnsupported:
                      NSLog(@"The platform/hardware doesn't support Bluetooth Low Energy.");
                      break;
                  case CBCentralManagerStateUnauthorized:
                      NSLog(@"The app is not authorized to use Bluetooth Low Energy.");
                      break;
                  case CBCentralManagerStatePoweredOff:
                      NSLog(@"Bluetooth is currently powered off.");
                      break;
                  case CBCentralManagerStatePoweredOn:
                      [self startScan];
                      NSLog(@"Bluetooth power on");
                      break;
                  case CBCentralManagerStateUnknown:
                  default:
                      break;
              }
          }];
      } else {
          [self startScan];
      }
      
    result(nil);
  } else if([@"stopScan" isEqualToString:call.method]) {
    [Manager stopScan];
    result(nil);
  } else if([@"connect" isEqualToString:call.method]) {
    NSDictionary *device = [call arguments];
    @try {
      NSLog(@"connect device begin -> %@", [device objectForKey:@"name"]);
      CBPeripheral *peripheral = [_scannedPeripherals objectForKey:[device objectForKey:@"address"]];
        
      self.state = ^(ConnectState state) {
        [self updateConnectState:state];
      };
      [Manager connectPeripheral:peripheral options:nil timeout:5 connectBlack: self.state];
      
      result(nil);
    } @catch(FlutterError *e) {
      result(e);
    }
  } else if([@"disconnect" isEqualToString:call.method]) {
    @try {
      [Manager close];
      result(nil);
    } @catch(FlutterError *e) {
      result(e);
    }
  } else if([@"writeData" isEqualToString:call.method]) {
       @try {
           NSDictionary *args = [call arguments];
           
           NSMutableArray *bytes = [args objectForKey:@"bytes"];

           NSNumber* lenBuf = [args objectForKey:@"length"];
           int len = [lenBuf intValue];
           char cArray[len];

           for (int i = 0; i < len; ++i) {
//               NSLog(@"** ind_%d (d): %@, %d", i, bytes[i], [bytes[i] charValue]);
               cArray[i] = [bytes[i] charValue];
           }
           NSData *data2 = [NSData dataWithBytes:cArray length:sizeof(cArray)];
//           NSLog(@"bytes in hex: %@", [data2 description]);
           if (![self enqueuePacedWrite:data2]) {
               // No BLE peripheral/characteristic exposed by GSDK: fall back
               // to the SDK's own writer.
               [Manager write:data2];
           }
           result(nil);
       } @catch(FlutterError *e) {
           result(e);
       }
  }
}

#pragma mark - Paced BLE write

/// Queues [data] for paced delivery. Returns NO when GSDK has not exposed a
/// connected peripheral + write characteristic (caller falls back to GSDK).
- (BOOL)enqueuePacedWrite:(NSData *)data {
    BLEConnecter *ble = Manager.bleConnecter;
    CBPeripheral *peripheral = ble.connPeripheral;
    CBCharacteristic *characteristic = ble.transparentDataWriteChar;
    if (peripheral == nil || characteristic == nil ||
        peripheral.state != CBPeripheralStateConnected) {
        return NO;
    }
    if (self.pendingWrites == nil) {
        self.pendingWrites = [NSMutableArray new];
    }
    [self.pendingWrites addObject:data];
    NSLog(@"paced BLE write queued: %lu bytes (queue=%lu)",
          (unsigned long)data.length, (unsigned long)self.pendingWrites.count);
    [self startNextPacedWriteIfIdle];
    return YES;
}

static double msForFeedDots(double dots) {
    if (dots <= 0) {
        return 0;
    }
    return (dots / kDotsPerMm) / kPrintSpeedMmPerMs + kFeedSafetyMarginMs;
}

/// Milliseconds the printer needs to render one unit. `rasterWidthBytes` is
/// the row width of the GS v 0 image whose data is currently streaming (0 when
/// not inside one).
static double pacingMsForUnit(const uint8_t *b, NSRange unit, BOOL atomic,
                              NSUInteger *rasterWidthBytes) {
    if (unit.length == 0) {
        return 0;
    }
    const uint8_t c0 = b[unit.location];
    const uint8_t c1 = unit.length > 1 ? b[unit.location + 1] : 0;
    const uint8_t c2 = unit.length > 2 ? b[unit.location + 2] : 0;

    if (!atomic) {
        if (c0 == 0x0a) {
            return msForFeedDots(kTextLineHeightDots);
        }
        if (*rasterWidthBytes > 0) {
            // GS v 0 pixel rows: one row per widthBytes.
            double rows = ceil((double)unit.length / (double)*rasterWidthBytes);
            return msForFeedDots(rows);
        }
        // Text run without a line feed: nothing prints yet.
        return 0;
    }

    // Leaving raster data resets the row width.
    *rasterWidthBytes = 0;

    if (c0 == 0x1b) {
        switch (c1) {
            case '*':  // ESC * m nL nH: 24-dot (m >= 32) or 8-dot strip
                return msForFeedDots(c2 >= 32 ? 24 : 8);
            case 'd':  // ESC d n: feed n lines
            case 'e':
                return msForFeedDots((double)c2 * kTextLineHeightDots);
            case 'J':  // ESC J n: feed n dots
                return msForFeedDots(c2);
            default:
                return 0;
        }
    }
    if (c0 == 0x1d) {
        if (c1 == 'v' && unit.length >= 8) {
            *rasterWidthBytes = b[unit.location + 4] | (b[unit.location + 5] << 8);
            return 0;
        }
        if (c1 == 'V') {
            return kCutSettleMs;
        }
        if (c1 == '(' && c2 == 'L') {
            // Raster via GS ( L: width not parsed, pace its data by bytes.
            *rasterWidthBytes = 0;
            return 0;
        }
        return 0;
    }
    return 0;
}

/// Pops the next payload and sends it as command-aligned units. Pauses are
/// inserted only between units, never inside an ESC/POS command.
- (void)startNextPacedWriteIfIdle {
    if (self.bleWriteInProgress || self.pendingWrites.count == 0) {
        return;
    }
    NSData *data = self.pendingWrites.firstObject;
    [self.pendingWrites removeObjectAtIndex:0];

    BLEConnecter *ble = Manager.bleConnecter;
    CBPeripheral *peripheral = ble.connPeripheral;
    CBCharacteristic *characteristic = ble.transparentDataWriteChar;
    if (peripheral == nil || characteristic == nil ||
        peripheral.state != CBPeripheralStateConnected) {
        NSLog(@"paced BLE write dropped: printer disconnected");
        [self startNextPacedWriteIfIdle];
        return;
    }

    CBCharacteristicWriteType type =
        (characteristic.properties & CBCharacteristicPropertyWriteWithoutResponse)
            ? CBCharacteristicWriteWithoutResponse
            : CBCharacteristicWriteWithResponse;
    NSUInteger maxLen = [peripheral maximumWriteValueLengthForType:type];
    NSUInteger chunk = MIN(kBleMaxChunkBytes, maxLen > 0 ? maxLen : kBleMaxChunkBytes);

    // Atomic tokens (complete commands) stay whole; text runs and raster
    // data are cut into chunk-sized units so pacing can happen between them.
    // Each unit gets the time the printer needs to render it.
    const uint8_t *bytes = data.bytes;
    NSMutableArray<NSValue *> *units = [NSMutableArray new];
    NSMutableArray<NSNumber *> *delaysMs = [NSMutableArray new];
    NSUInteger rasterWidthBytes = 0;
    double totalMs = 0;
    for (EscPosToken *token in [EscPosTokenizer tokenize:data]) {
        if (token.atomic || token.range.length <= chunk) {
            double ms = pacingMsForUnit(bytes, token.range, token.atomic, &rasterWidthBytes);
            if (!token.atomic && rasterWidthBytes == 0 && bytes[token.range.location] != 0x0a
                && token.range.length > 64) {
                // Unparsed bulk data (e.g. GS ( L payload): byte-rate fallback.
                ms = token.range.length / kUnknownDataBytesPerMs;
            }
            [units addObject:[NSValue valueWithRange:token.range]];
            [delaysMs addObject:@(ms)];
            totalMs += ms;
            continue;
        }
        NSUInteger offset = token.range.location;
        const NSUInteger end = NSMaxRange(token.range);
        while (offset < end) {
            NSUInteger len = MIN(chunk, end - offset);
            NSRange piece = NSMakeRange(offset, len);
            double ms = pacingMsForUnit(bytes, piece, NO, &rasterWidthBytes);
            if (rasterWidthBytes == 0) {
                ms = len / kUnknownDataBytesPerMs;
            }
            [units addObject:[NSValue valueWithRange:piece]];
            [delaysMs addObject:@(ms)];
            totalMs += ms;
            offset += len;
        }
    }

    NSLog(@"paced BLE write start: %lu bytes, %lu units, chunk=%lu, type=%@, est. %.1fs",
          (unsigned long)data.length, (unsigned long)units.count, (unsigned long)chunk,
          type == CBCharacteristicWriteWithoutResponse ? @"noResp" : @"resp",
          totalMs / 1000.0);

    self.bleWriteInProgress = YES;
    [self sendUnitAtIndex:0
                    units:units
                 delaysMs:delaysMs
                     data:data
                    chunk:chunk
                     type:type
               peripheral:peripheral
           characteristic:characteristic];
}

- (void)sendUnitAtIndex:(NSUInteger)index
                  units:(NSArray<NSValue *> *)units
               delaysMs:(NSArray<NSNumber *> *)delaysMs
                   data:(NSData *)data
                  chunk:(NSUInteger)chunk
                   type:(CBCharacteristicWriteType)type
             peripheral:(CBPeripheral *)peripheral
         characteristic:(CBCharacteristic *)characteristic {
    if (index >= units.count) {
        NSLog(@"paced BLE write done: %lu bytes", (unsigned long)data.length);
        self.bleWriteInProgress = NO;
        [self startNextPacedWriteIfIdle];
        return;
    }
    const NSRange unit = [units[index] rangeValue];
    const double delayMs = delaysMs[index].doubleValue;
    __weak typeof(self) weakSelf = self;
    dispatch_block_t next = ^{
        [weakSelf sendUnitAtIndex:index + 1 units:units delaysMs:delaysMs data:data
                            chunk:chunk type:type peripheral:peripheral
                   characteristic:characteristic];
    };
    [self writeUnit:unit
             offset:unit.location
               data:data
              chunk:chunk
               type:type
         peripheral:peripheral
     characteristic:characteristic
         completion:^{
        if (delayMs <= 0) {
            next();
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayMs * NSEC_PER_MSEC)),
                       dispatch_get_main_queue(), next);
    }];
}

/// Writes one unit in chunk-sized pieces back to back. The only wait inside
/// a unit is CoreBluetooth's own link-queue readiness, which is at most one
/// connection interval, the same cadence GSDK's writer produces.
- (void)writeUnit:(NSRange)unit
           offset:(NSUInteger)offset
             data:(NSData *)data
            chunk:(NSUInteger)chunk
             type:(CBCharacteristicWriteType)type
       peripheral:(CBPeripheral *)peripheral
   characteristic:(CBCharacteristic *)characteristic
       completion:(dispatch_block_t)completion {
    const NSUInteger end = NSMaxRange(unit);
    if (offset >= end) {
        completion();
        return;
    }
    if (peripheral.state != CBPeripheralStateConnected) {
        NSLog(@"paced BLE write aborted at %lu/%lu: printer disconnected",
              (unsigned long)offset, (unsigned long)data.length);
        self.bleWriteInProgress = NO;
        [self.pendingWrites removeAllObjects];
        return;
    }
    __weak typeof(self) weakSelf = self;
    if (type == CBCharacteristicWriteWithoutResponse &&
        !peripheral.canSendWriteWithoutResponse) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(kBleLinkBusyRetry * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [weakSelf writeUnit:unit offset:offset data:data chunk:chunk type:type
                     peripheral:peripheral characteristic:characteristic completion:completion];
        });
        return;
    }
    const NSUInteger len = MIN(chunk, end - offset);
    [peripheral writeValue:[data subdataWithRange:NSMakeRange(offset, len)]
         forCharacteristic:characteristic
                      type:type];
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf writeUnit:unit offset:offset + len data:data chunk:chunk type:type
                 peripheral:peripheral characteristic:characteristic completion:completion];
    });
}

-(void)startScan {
    [Manager scanForPeripheralsWithServices:nil options:nil discover:^(CBPeripheral * _Nullable peripheral, NSDictionary<NSString *,id> * _Nullable advertisementData, NSNumber * _Nullable RSSI) {
        if (peripheral.name != nil) {
            
            NSLog(@"find device -> %@", peripheral.name);
            [self.scannedPeripherals setObject:peripheral forKey:[[peripheral identifier] UUIDString]];
            
            NSDictionary *device = [NSDictionary dictionaryWithObjectsAndKeys:peripheral.identifier.UUIDString,@"address",peripheral.name,@"name",nil,@"type",nil];
            [_channel invokeMethod:@"ScanResult" arguments:device];
        }
    }];
    
}

-(void)updateConnectState:(ConnectState)state {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSNumber *ret = @0;
        switch (state) {
            case CONNECT_STATE_CONNECTING:
                NSLog(@"status -> %@", @"Connecting ...");
                ret = @1;
                break;
            case CONNECT_STATE_CONNECTED:
                NSLog(@"status -> %@", @"Connection success");
                ret = @2;
                break;
            case CONNECT_STATE_FAILT:
                NSLog(@"status -> %@", @"Connection failed");
                ret = @0;
                break;
            case CONNECT_STATE_DISCONNECT:
                NSLog(@"status -> %@", @"Disconnected");
                ret = @0;
                break;
            default:
                NSLog(@"status -> %@", @"Connection timed out");
                ret = @0;
                break;
        }
        
         NSDictionary *dict = [NSDictionary dictionaryWithObjectsAndKeys:ret,@"id",nil];
        if(_stateStreamHandler.sink != nil) {
          self.stateStreamHandler.sink([dict objectForKey:@"id"]);
        }
    });
}

@end

@implementation BluetoothPrintStreamHandler

- (FlutterError*)onListenWithArguments:(id)arguments eventSink:(FlutterEventSink)eventSink {
  self.sink = eventSink;
  return nil;
}

- (FlutterError*)onCancelWithArguments:(id)arguments {
  self.sink = nil;
  return nil;
}

@end
