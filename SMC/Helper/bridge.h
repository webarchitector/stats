//
//  bridge.h
//  Helper
//
//  Created on 2026-06-09.
//
//  Trimmed copy of Modules/Sensors/bridge.h. The Helper target only needs
//  IOHID event reading for `AppleSiliconSensors` — the IOReport surface used
//  by the Sensors framework for power/perf channels is intentionally
//  excluded.
//
//  Based on https://github.com/yujitach/MenuMeters/blob/master/hardware_reader/applesilicon_hardware_reader.m
//

#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <CoreFoundation/CoreFoundation.h>

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
#ifdef __LP64__
typedef double IOHIDFloat;
#else
typedef float IOHIDFloat;
#endif

#define IOHIDEventFieldBase(type)   (type << 16)
#define kIOHIDEventTypeTemperature  15
#define kIOHIDEventTypePower        25

IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef, int64_t, int32_t, int64_t);
CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef property);
IOHIDFloat IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

NSDictionary*AppleSiliconSensors(int page, int usage, int32_t type);
