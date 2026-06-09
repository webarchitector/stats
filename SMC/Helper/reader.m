//
//  reader.m
//  Helper
//
//  Created on 2026-06-09.
//
//  AppleSiliconSensors IOHID shim — copy of Modules/Sensors/reader.m.
//  Lives in the Helper target so HelperSensorReader can poll HID
//  temperatures in-process without an XPC hop.
//

#import <Foundation/Foundation.h>
#import <os/lock.h>
#import "bridge.h"

// macOS 27 logs every short-lived IOHIDEventSystemClient under
// com.apple.iohid:oversized ("Released connection: <UUID>"). The helper
// polls sensors once a second, so a per-call create+release produced ~60
// events/min of pure log noise. Cache the client for the lifetime of the
// daemon; matching is reset per call (cheap).
static IOHIDEventSystemClientRef sharedHIDClient = NULL;
static os_unfair_lock sharedHIDClientLock = OS_UNFAIR_LOCK_INIT;

static IOHIDEventSystemClientRef getSharedHIDClient(void) {
    // Lazy init WITHOUT dispatch_once: if the first create returns NULL (HID
    // not yet available when launchd starts the daemon very early at boot),
    // dispatch_once would cache NULL for the whole process lifetime and HID
    // temperatures would never resolve until a restart. Retry on each call
    // until creation succeeds. The lock keeps it self-contained even though
    // callers already serialize on HelperSensorReader's accessQueue.
    os_unfair_lock_lock(&sharedHIDClientLock);
    if (sharedHIDClient == NULL) {
        sharedHIDClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    }
    IOHIDEventSystemClientRef client = sharedHIDClient;
    os_unfair_lock_unlock(&sharedHIDClientLock);
    return client;
}

NSDictionary*AppleSiliconSensors(int32_t page, int32_t usage, int32_t type) {
    IOHIDEventSystemClientRef system = getSharedHIDClient();
    if (system == NULL) {
        return nil;
    }

    NSDictionary* dictionary = @{@"PrimaryUsagePage":@(page),@"PrimaryUsage":@(usage)};
    IOHIDEventSystemClientSetMatching(system, (__bridge CFDictionaryRef)dictionary);
    CFArrayRef services = IOHIDEventSystemClientCopyServices(system);
    if (services == nil) {
        return nil;
    }

    NSMutableDictionary*dict = [NSMutableDictionary dictionary];
    for (int i = 0; i < CFArrayGetCount(services); i++) {
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        NSString* name = CFBridgingRelease(IOHIDServiceClientCopyProperty(service, CFSTR("Product")));

        IOHIDEventRef event = IOHIDServiceClientCopyEvent(service, type, 0, 0);
        if (event == nil) {
            continue;
        }

        if (name && event) {
            double value = IOHIDEventGetFloatValue(event, IOHIDEventFieldBase(type));
            dict[name]=@(value);
        }

        CFRelease(event);
    }

    CFRelease(services);

    return dict;
}
