#import <Foundation/Foundation.h>

#define kIOHIDEventDriverClass  "IOHIDEventDriver"

#define kFnModifierUsagePageKey "FnModifierUsagePage"
#define kFnModifierUsageKey     "FnModifierUsage"


enum
{
	kHIDUsage_AppleVendorKeyboard_Function = 0x03
};


@interface DeviceTracker : NSObject
@end
