//
//  HelperBridge.h
//  Helper
//
//  Created on 2026-06-09.
//
//  Swift→Obj-C bridging header for the Helper target. Re-exports the
//  AppleSiliconSensors IOHID shim from bridge.h so HelperSensorReader can
//  read HID temperatures in-process (no XPC round-trip to the host app).
//

#ifndef HelperBridge_h
#define HelperBridge_h
#import "bridge.h"
#endif
