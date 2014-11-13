#import <Foundation/Foundation.h>

//TODO the Apple Fn key usage page & usage values could be read from the
//     below properties of a subordinate device of calss 'AppleEmbeddedKeyboard'
#define kFnModifierUsagePageKey "FnModifierUsagePage"
#define kFnModifierUsageKey     "FnModifierUsage"

// extracted from IOHIDFamily/AppleHIDUsageTables.h
enum {
	kHIDPage_AppleVendorTopCase = 0xFF
};

// extracted from IOHIDFamily/AppleHIDUsageTables.h
enum
{
	kHIDUsage_AppleVendorKeyboard_Function = 0x03
};


@interface DeviceTracker : NSObject
@end
