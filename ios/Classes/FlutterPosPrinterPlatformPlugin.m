#import "FlutterPosPrinterPlatformPlugin.h"
#import "ConnecterManager.h"

// Paced Bluetooth LE writer
//
// Bluetooth LE thermal printers (XPrinter and similar) have a small receive
// buffer and no flow control above the link layer. GSDK's -[ConnecterManager
// write:] pushes data as fast as CoreBluetooth accepts it, so any payload
// larger than the printer's buffer is partly dropped: the receipt prints as
// garbage, stops halfway, or comes out as a single line feed. Sending in small
// chunks at a fixed byte rate keeps delivery below the print head's consumption
// so the buffer never overflows. Payloads are queued so two prints (e.g. cash
// drawer + receipt) never interleave.
static const NSUInteger kBleMaxChunkBytes = 244;
static const double kBleBytesPerSecond = 8000.0;
static const NSTimeInterval kBleLinkBusyRetry = 0.005;

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

    // Prefer write-without-response when the printer offers it (throughput);
    // CoreBluetooth's canSendWriteWithoutResponse is honoured below so the
    // link queue itself never overflows either.
    CBCharacteristicWriteType type =
        (characteristic.properties & CBCharacteristicPropertyWriteWithoutResponse)
            ? CBCharacteristicWriteWithoutResponse
            : CBCharacteristicWriteWithResponse;
    NSUInteger maxLen = [peripheral maximumWriteValueLengthForType:type];
    NSUInteger chunk = MIN(kBleMaxChunkBytes, maxLen > 0 ? maxLen : kBleMaxChunkBytes);
    NSTimeInterval delay = chunk / kBleBytesPerSecond;

    NSLog(@"paced BLE write start: %lu bytes, chunk=%lu, type=%@, delay=%.0fms",
          (unsigned long)data.length, (unsigned long)chunk,
          type == CBCharacteristicWriteWithoutResponse ? @"noResp" : @"resp",
          delay * 1000);

    self.bleWriteInProgress = YES;
    [self writeChunkOf:data
                offset:0
                 chunk:chunk
                 delay:delay
                  type:type
            peripheral:peripheral
        characteristic:characteristic];
}

- (void)writeChunkOf:(NSData *)data
              offset:(NSUInteger)offset
               chunk:(NSUInteger)chunk
               delay:(NSTimeInterval)delay
                type:(CBCharacteristicWriteType)type
          peripheral:(CBPeripheral *)peripheral
      characteristic:(CBCharacteristic *)characteristic {
    if (offset >= data.length) {
        NSLog(@"paced BLE write done: %lu bytes", (unsigned long)data.length);
        self.bleWriteInProgress = NO;
        [self startNextPacedWriteIfIdle];
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
        // Link-layer queue is full; wait without advancing the offset.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(kBleLinkBusyRetry * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [weakSelf writeChunkOf:data offset:offset chunk:chunk delay:delay
                              type:type peripheral:peripheral
                    characteristic:characteristic];
        });
        return;
    }
    NSUInteger len = MIN(chunk, data.length - offset);
    [peripheral writeValue:[data subdataWithRange:NSMakeRange(offset, len)]
         forCharacteristic:characteristic
                      type:type];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf writeChunkOf:data offset:offset + len chunk:chunk delay:delay
                          type:type peripheral:peripheral
                characteristic:characteristic];
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
