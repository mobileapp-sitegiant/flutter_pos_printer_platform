## 1.2.5
* [iOS] Fix fatal crash `NSInternalInconsistencyException: Invalid parameter not satisfying: peripheral != nil` — GSDK's connect-timeout timer calls `cancelPeripheralConnection:` with a nil peripheral when the printer is unreachable; guarded at runtime via `CBCentralManagerSafeCancel`
* [iOS] Clear dangling `_connecter` reference in `ConnecterManager close`

## 1.2.4
* Upgraded to support android 14 and fix USB printing issue 
* Credits: 
   - https://github.com/diantahoc/flutter_pos_printer_platform
   - https://github.com/nasibudesign/thermal_printer/

## 1.0.12

* Resolve minor bug [Android] 12

## 1.0.11

* Resolve minor bug dependecies

## 1.0.10

* Now android supports targetSdkVersion 31

## 1.0.9

* Resolve minor bug [Android] connection

## 1.0.8

* Resolve minor bug [Android] connection

## 1.0.6

* Resolve minor bug [Android] connection

## 1.0.6

* Resolve minor bug windows printer

## 1.0.5

* Get current status bt

## 1.0.4

* Solved Bug windows: USB

## 1.0.3

* Bug android notify events: Bluetooth 

## 1.0.2

* Bug android connection interface: USB 

## 1.0.1

* How to use it.

## 1.0.0

* Initial release.
