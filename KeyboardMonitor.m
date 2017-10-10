#import "ISSUtils.h"
#import <IOKit/hid/IOHIDLib.h>
#import <IOKit/IOMessage.h>

#import "InputSourceSwitch.h"


#define kIOHIDEventDriverClass  "IOHIDEventDriver"

#define kFnModifierUsagePageKey "FnModifierUsagePage"
#define kFnModifierUsageKey     "FnModifierUsage"


@class KeyboardMonitorApplication;

enum {
	kHIDUsage_AppleVendorKeyboard_Function = 0x03
};

typedef void (*DeviceEventCallBack) (int eventCode, void *info);


KeyboardMonitorApplication *MonitorApp;


@interface DeviceState : NSObject
	- (instancetype) initWithDeallocBlock: (void (^) (void)) deallocBlock deviceEventCallBack: (DeviceEventCallBack) deviceEventCallback andInfo: (void *) info;
	- (void) sendDeviceEvent: (int) eventCode;
@end

@implementation DeviceState {
	DeviceEventCallBack _deviceEventCallback;
	void *_deviceEventCallbackInfo;
	void (^_deallocBlock) (void);
}
	- (instancetype) initWithDeallocBlock: (void (^) (void)) deallocBlock deviceEventCallBack: (DeviceEventCallBack) deviceEventCallback andInfo: (void *) info {
		if (self = [self init]) {
			_deallocBlock = deallocBlock;
			_deviceEventCallback = deviceEventCallback;
			_deviceEventCallbackInfo = info;
		}
		return self;
	}

	- (void) sendDeviceEvent: (int) eventCode {
		if (_deviceEventCallback)
			_deviceEventCallback (eventCode, _deviceEventCallbackInfo);
	}

	- (void) dealloc {
		if (_deallocBlock)
			_deallocBlock ();
	}
@end


@interface DeviceStateRegistry : NSObject
	- (instancetype) init NS_UNAVAILABLE;
	- (instancetype) initWithDeviceEventCallBack: (DeviceEventCallBack) deviceEventCallback andInfo: (void *) info;
	- (DeviceState *) getDeviceStateForTag: (void *) tag withDeviceStateBuilder: (DeviceState *(^) (void (^) (void), DeviceEventCallBack, void *)) deviceStateBuilder;
@end

@implementation DeviceStateRegistry {
	CFMutableDictionaryRef _deviceStateMap;
	DeviceEventCallBack _deviceEventCallback;
	void *_deviceEventCallbackInfo;
}
	- (instancetype) initWithDeviceEventCallBack: (DeviceEventCallBack) deviceEventCallback andInfo: (void *) info {
		if (self = [super init]) {
			_deviceStateMap = CFDictionaryCreateMutable (kCFAllocatorDefault, 0, NULL, NULL);
			if (!_deviceStateMap)
				return nil;

			_deviceEventCallback = deviceEventCallback;
			_deviceEventCallbackInfo = info;
		}
		return self;
	}

	- (DeviceState *) getDeviceStateForTag: (void *) tag withDeviceStateBuilder: (DeviceState *(^) (void (^) (void), DeviceEventCallBack, void *)) deviceStateBuilder {
		if (!tag)
			return deviceStateBuilder (nil, NULL, NULL);

		DeviceState *state = (__bridge DeviceState *) CFDictionaryGetValue (_deviceStateMap, tag);
		if (state)
			return state;

		state = deviceStateBuilder (
			^ {
				CFDictionaryRemoveValue (_deviceStateMap, tag);
			},
			_deviceEventCallback, _deviceEventCallbackInfo
		);
		if (!state)
			return nil;

		CFDictionarySetValue (_deviceStateMap, tag, (__bridge void *) state);

		return state;
	}

	- (void) dealloc {
		if (_deviceStateMap)
			CFRelease (_deviceStateMap);
	}
@end


@interface KeyboardDeviceState : DeviceState
	- (instancetype) initWithDeallocBlock: (void (^) (void)) deallocBlock deviceEventCallBack: (DeviceEventCallBack) deviceEventCallback andInfo: (void *) info;
	- (void) handleKey: (uint32_t) key status: (BOOL) pressed;
@end

@implementation KeyboardDeviceState {
	CFMutableSetRef _pressedKeys;
	uint8_t _switchState;
}
	- (instancetype) init {
		return [self localInit: [super init]];
	}

	- (instancetype) initWithDeallocBlock: (void (^) (void)) deallocBlock deviceEventCallBack: (DeviceEventCallBack) deviceEventCallback andInfo: (void *) info {
		return [self localInit: [super initWithDeallocBlock: deallocBlock deviceEventCallBack: deviceEventCallback andInfo: info]];
	}

	- (instancetype) __attribute__ ((objc_method_family (init))) localInit: (KeyboardDeviceState *) instance {
		if ((self = instance)) {
			_pressedKeys = CFSetCreateMutable (kCFAllocatorDefault, 0, NULL);
			if (!_pressedKeys)
				return nil;
		}
		return self;
	}

	- (void) handleKey: (uint32_t) key status: (BOOL) pressed {
		if (pressed)
			CFSetAddValue (_pressedKeys, (uint8_t *) NULL + key);
		else
			CFSetRemoveValue (_pressedKeys, (uint8_t *) NULL + key);

		switch (_switchState) {
			case 0:
				if (pressed && key == kHIDUsage_KeyboardLeftAlt && CFSetGetCount (_pressedKeys) == 1) {
					// L-Alt pressed on its own
					_switchState = 1;
					return;
				}
				break;

			case 1:
				if (pressed && key == kHIDUsage_KeyboardLeftShift) {
					// L-Shift pressed
					_switchState = 2;
					return;
				}
				break;

			default:
				if (pressed)
					break;

				switch (key) {
					case kHIDUsage_KeyboardLeftShift:
						// L-Shift released
						[self sendDeviceEvent: 0];
						_switchState = 1;
						return;
					case kHIDUsage_KeyboardLeftAlt:
						// L-Alt released
						[self sendDeviceEvent: 0];
				}
		}
		_switchState = 0;
	}

	- (void) dealloc {
		if (_pressedKeys)
			CFRelease (_pressedKeys);
	}
@end


@interface KeyboardDeviceHandler : NSObject
	- (instancetype) init NS_UNAVAILABLE;
	- (instancetype) initWithDeviceReference: (IOHIDDeviceRef) deviceRef andDeviceStateRegistry: registry;
@end

@implementation KeyboardDeviceHandler {
	IOHIDDeviceRef _deviceReference;
	BOOL _opened;
	KeyboardDeviceState *_deviceState;
	uint32_t _fnModifierKeyUsagePage;
	uint32_t _fnModifierKeyUsage;
	IONotificationPortRef _busyStateNotifyPort;
	io_object_t _busyStateNotification;
}
	- (instancetype) initWithDeviceReference: (IOHIDDeviceRef) deviceRef andDeviceStateRegistry: deviceStateRegistry {
		if (self = [super init]) {
			if (!(_deviceReference = deviceRef))
				return nil;
			CFRetain (_deviceReference);

			_deviceState = (KeyboardDeviceState *) [deviceStateRegistry
				getDeviceStateForTag: [self deviceLocationTag]
				withDeviceStateBuilder: ^ (void (^deallocBlock) (void), DeviceEventCallBack deviceEventCallback, void *info) {
					return [[KeyboardDeviceState alloc] initWithDeallocBlock: deallocBlock deviceEventCallBack: deviceEventCallback andInfo: info];
				}
			];
			if (!_deviceState) {
				NSLog (@"Failed to obtain device state for device: %@", IOHIDDeviceGetProperty (_deviceReference, CFSTR (kIOHIDProductKey)));
				return nil;
			}

			[self initiateFnModifierKeyIdentification];

			IOReturn rv = IOHIDDeviceOpen (_deviceReference, kIOHIDOptionsTypeNone);
			if (rv != kIOReturnSuccess) {
				NSLog (@"Failed to open device: %@: 0x%08x", IOHIDDeviceGetProperty (_deviceReference, CFSTR (kIOHIDProductKey)), rv);
				return nil;
			}
			_opened = YES;

			IOHIDDeviceRegisterInputValueCallback (_deviceReference, inputValueCallback, (__bridge void *) self);

			NSLog (@"Added device: %@", IOHIDDeviceGetProperty (_deviceReference, CFSTR (kIOHIDProductKey)));
		}
		return self;
	}

	- (void) initiateFnModifierKeyIdentification {
		_fnModifierKeyUsagePage = kHIDPage_Undefined;

		io_service_t service = IOHIDDeviceGetService (_deviceReference);
		if (service == MACH_PORT_NULL)
			return;

		_busyStateNotifyPort = IONotificationPortCreate (kIOMasterPortDefault);
		if (!_busyStateNotifyPort)
			return;

		if (
			IOServiceAddInterestNotification (
				_busyStateNotifyPort,
				service,
				kIOBusyInterest,
				busyStateChangeCallback,
				(__bridge void *) self,
				&_busyStateNotification
			) != KERN_SUCCESS
		) {
			IONotificationPortDestroy (_busyStateNotifyPort);
			_busyStateNotifyPort = NULL;
			return;
		}

		uint32_t busyState;

		if (
			IOServiceGetBusyState (service, &busyState) != KERN_SUCCESS
			||
			(busyStateChangeCallback (
				(__bridge void *) self,
				service,
				kIOMessageServiceBusyStateChange,
				(uint8_t *) NULL + busyState
			), _busyStateNotifyPort)
		)
			CFRunLoopAddSource (
				CFRunLoopGetMain (),
				IONotificationPortGetRunLoopSource (_busyStateNotifyPort),
				kCFRunLoopDefaultMode
			);
	}

	- (void) identifyFnModifierKey: (io_service_t) service {
		io_iterator_t childrenIterator;

		if (
			IORegistryEntryCreateIterator (
				service,
				kIOServicePlane,
				kIORegistryIterateRecursively,
				&childrenIterator
			) != KERN_SUCCESS
		)
			return;

		for (io_registry_entry_t child; (child = IOIteratorNext (childrenIterator)); IOObjectRelease (child)) {
			if (!IOObjectConformsTo (child, kIOHIDEventDriverClass))
				continue;

			NSMutableDictionary *childProperties;

			if (
				IORegistryEntryCreateCFProperties (
					child,
					(void *) &childProperties,
					kCFAllocatorDefault,
					kNilOptions
				) != KERN_SUCCESS
			)
				continue;

			NSNumber *fnUsagePage, *fnUsage;

			if (
				(fnUsagePage = ensureNumber ((__bridge CFTypeRef) childProperties[@kFnModifierUsagePageKey]))
				&&
				(fnUsage = ensureNumber ((__bridge CFTypeRef) childProperties[@kFnModifierUsageKey]))
			) {
				_fnModifierKeyUsagePage = fnUsagePage.unsignedIntValue;
				_fnModifierKeyUsage = fnUsage.unsignedIntValue;
				IOObjectRelease (child);
				break;
			}
		}

		IOObjectRelease (childrenIterator);
	}

	- (void *) deviceLocationTag {
		NSNumber *locationId = ensureNumber (IOHIDDeviceGetProperty (_deviceReference, CFSTR (kIOHIDLocationIDKey)));

		return (uint8_t *) NULL + locationId.unsignedIntegerValue;
	}

	- (void) handleInputValue: (IOHIDValueRef) valueRef {
		IOHIDElementRef elem = IOHIDValueGetElement (valueRef);
		uint32_t usagePage = IOHIDElementGetUsagePage (elem);
		uint32_t usage;

		switch (usagePage) {
			case kHIDPage_KeyboardOrKeypad:
				usage = IOHIDElementGetUsage (elem);
				if (!(usage >= kHIDUsage_KeyboardA && usage <= kHIDUsage_KeyboardRightGUI))
					return; // not a key event
				break;

			case kHIDPage_Consumer:
				usage = IOHIDElementGetUsage (elem);
				if (!(usage == kHIDUsage_Csmr_Eject))
					return; // not the 'Eject' key event
				usage |= 0x10000;
				break;

			default:
				if (usagePage != _fnModifierKeyUsagePage || _fnModifierKeyUsagePage == kHIDPage_Undefined)
					return; // not anything we care about
				usage = IOHIDElementGetUsage (elem);
				if (!(usage == _fnModifierKeyUsage))
					return; // not the Apple 'Fn' modifier key event
				usage = kHIDUsage_AppleVendorKeyboard_Function | 0x20000;
				break;
		}

		CFIndex valueLength = IOHIDValueGetLength (valueRef);
		if (valueLength == 0 || valueLength > 8)
			return; // not an expected value

		[_deviceState handleKey: usage status: IOHIDValueGetIntegerValue (valueRef) != 0];
	}

	- (void) dealloc {
		if (_busyStateNotifyPort) {
			IOObjectRelease (_busyStateNotification);
			IONotificationPortDestroy (_busyStateNotifyPort); // this releases the associated CFRunLoopSource
		}
		if (_opened) {
			IOHIDDeviceClose (_deviceReference, kIOHIDOptionsTypeNone);
			NSLog (@"Removed device: %@", IOHIDDeviceGetProperty (_deviceReference, CFSTR (kIOHIDProductKey)));
		} else if (!_deviceReference)
			return;
		CFRelease (_deviceReference);
	}

	static NSNumber *ensureNumber (CFTypeRef reference) {
		return (reference && CFGetTypeID (reference) == CFNumberGetTypeID ())
			? (__bridge NSNumber *) reference
			: nil;
	}

	static void inputValueCallback (void *context, IOReturn result, void *sender, IOHIDValueRef valueRef) {
		[(__bridge KeyboardDeviceHandler *) context handleInputValue: valueRef];
	}

	static void busyStateChangeCallback (void *context, io_service_t service, uint32_t messageType, void *messageArgument) {
		if (messageType != kIOMessageServiceBusyStateChange)
			return;

		if ((uint32_t) (messageArgument - NULL))
			return; // busyState > 0

		KeyboardDeviceHandler *instance = (__bridge KeyboardDeviceHandler *) context;

		IOObjectRelease (instance->_busyStateNotification);
		IONotificationPortDestroy (instance->_busyStateNotifyPort); // this releases the associated CFRunLoopSource
		instance->_busyStateNotifyPort = NULL;

		[instance identifyFnModifierKey: service];
	}
@end


@interface DeviceTracker : NSObject
	- (instancetype) init NS_UNAVAILABLE;
	- (instancetype) initWithDeviceEventCallBack: (DeviceEventCallBack) deviceEventCallback andInfo: (void *) info;
@end

@implementation DeviceTracker {
	IOHIDManagerRef _hidManager;
	CFMutableDictionaryRef _deviceHandlerMap;
	DeviceStateRegistry *_deviceStateRegistry;
}
	- (instancetype) initWithDeviceEventCallBack: (DeviceEventCallBack) deviceEventCallback andInfo: (void *) info {
		if (self = [super init]) {
			_deviceHandlerMap = CFDictionaryCreateMutable (kCFAllocatorDefault, 0, NULL, &kCFTypeDictionaryValueCallBacks);
			if (!_deviceHandlerMap)
				return nil;

			_deviceStateRegistry = [[DeviceStateRegistry alloc] initWithDeviceEventCallBack: deviceEventCallback andInfo: info];
			if (!_deviceStateRegistry)
				return nil;

			_hidManager = IOHIDManagerCreate (kCFAllocatorDefault, kIOHIDOptionsTypeNone);
			if (CFGetTypeID (_hidManager) != IOHIDManagerGetTypeID ())
				return nil;

			NSDictionary *matchingDictionary = deviceMatchingDictionary ();
			if (!matchingDictionary)
				return nil;

			IOHIDManagerSetDeviceMatching (_hidManager, (__bridge CFDictionaryRef) matchingDictionary);

			IOHIDManagerRegisterDeviceMatchingCallback (_hidManager, deviceAddedCallback, (__bridge void *) self);
			IOHIDManagerRegisterDeviceRemovalCallback (_hidManager, deviceRemovedCallback, (__bridge void *) self);

			IOHIDManagerScheduleWithRunLoop (_hidManager, CFRunLoopGetMain (), kCFRunLoopDefaultMode);
		}
		return self;
	}

	- (void) dealloc {
		if (_hidManager)
			IOHIDManagerUnscheduleFromRunLoop (_hidManager, CFRunLoopGetMain (), kCFRunLoopDefaultMode);
		if (_deviceHandlerMap)
			CFRelease (_deviceHandlerMap);
		if (_hidManager)
			CFRelease (_hidManager);
	}

	static NSDictionary *usagePairMatchingDictionary (uint32_t usagePage, uint32_t usage) {
		return @{
			@kIOHIDDeviceUsagePageKey: @(usagePage),
			@kIOHIDDeviceUsageKey:     @(usage)
		};
	}

	static NSDictionary *deviceMatchingDictionary (void) {
		@try {
			return @{
				@kIOHIDDeviceUsagePairsKey: @[
					// this dictionary will match keyboard devices
					usagePairMatchingDictionary (kHIDPage_GenericDesktop, kHIDUsage_GD_Keyboard),
					// this dictionary will match consumer control devices
					usagePairMatchingDictionary (kHIDPage_Consumer, kHIDUsage_Csmr_ConsumerControl)
				]
			};
		} @catch (NSException *e) {
			if ([e.name isEqualToString: NSInvalidArgumentException])
				return nil;
			@throw;
		}
	}

	static void deviceAddedCallback (void *context, IOReturn result, void *sender, IOHIDDeviceRef deviceRef) {
		DeviceTracker *instance = (__bridge DeviceTracker *) context;

		if (CFDictionaryContainsKey (instance->_deviceHandlerMap, deviceRef))
			return;

		KeyboardDeviceHandler *handler = [[KeyboardDeviceHandler alloc]
			initWithDeviceReference: deviceRef
			andDeviceStateRegistry:  instance->_deviceStateRegistry
		];
		if (!handler)
			return;

		CFDictionarySetValue (instance->_deviceHandlerMap, deviceRef, (__bridge void *) handler);
	}

	static void deviceRemovedCallback (void *context, IOReturn result, void *sender, IOHIDDeviceRef deviceRef) {
		DeviceTracker *instance = (__bridge DeviceTracker *) context;

		if (!CFDictionaryContainsKey (instance->_deviceHandlerMap, deviceRef))
			return;

		CFDictionaryRemoveValue (instance->_deviceHandlerMap, deviceRef);
	}
@end


@interface KeyboardMonitorApplication : NSObject
	- (int) runWithClientPortHolder: (ISSUMachPortHolder *) clientPortHolder;
	- (void) quitWithReturnValue: (int) returnValue;
@end

@implementation KeyboardMonitorApplication {
	ISSUMachPort *_listenPort;
	ISSUMachPort *_sendPort;
	DeviceTracker *_tracker;
	int _returnValue;
}
	- (instancetype) init {
		if (self = [super init]) {
			if (!(_listenPort = [ISSUMachPort new])) {
				NSLog (@"Failed to create listen mach port.");
				return nil;
			}

			if (![_listenPort scheduleInRunLoop: CFRunLoopGetMain () forMode: kCFRunLoopDefaultMode]) {
				NSLog (@"Failed to schedule listen mach port.");
				return nil;
			}
		}
		return self;
	}

	- (void) createTracker {
		if (!_tracker)
			if (!(_tracker = [[DeviceTracker alloc]
				initWithDeviceEventCallBack: &deviceEventHandler
				andInfo:                     (__bridge void *) self
			])) {
				NSLog (@"Failed to create device tracker.");
				[self quitWithReturnValue: 3];
			}
	}

	- (void) destroyTracker {
		if (_tracker)
			_tracker = nil;
	}

	- (int) runWithClientPortHolder: (ISSUMachPortHolder *) clientPortHolder {
		_returnValue = 0;

		@try {
			_sendPort = [clientPortHolder get];

			mach_port_t machPort = _listenPort.machPort;

			if (!ISSUPortRightsSend (_sendPort, &machPort, 1)) {
				NSLog (@"Failed to send mach port rights.");
				return 2;
			}

			[_sendPort setInvalidationCallBack: &sendPortInvalidationHandler andInfo: (__bridge void *) self];

			[_listenPort setMessageCallBack: &portExchangeHandler andInfo: (__bridge void *) self];

			CFRunLoopRun ();

			return _returnValue;
		} @finally {
			[_listenPort setMessageCallBack: NULL andInfo: NULL];
			_sendPort = nil;
		}
	}

	- (void) quitWithReturnValue: (int) returnValue {
		CFRunLoopStop (CFRunLoopGetMain ());
		_returnValue = returnValue;
	}

	static void portExchangeHandler (ISSUMachPort *port, mach_msg_header_t *msg, void *info) {
		KeyboardMonitorApplication *instance = (__bridge KeyboardMonitorApplication *) info;
		mach_port_t machPort[2];

		switch (ISSUPortRightsReceive (msg, machPort, ISSUArrayLength (machPort))) {
			default: // > 1
				if (!ISSUResetBootstrapPort (machPort[1])) {
					NSLog (@"Failed to reset bootstrap port.");
					goto error_exit;
				}
				// fall through
			case 1:
				break;
			case 0:
			case -1:
				NSLog (@"Failed to receive mach port rights.");
				goto error_exit;
		}

		if (!(instance->_sendPort = [[ISSUMachPort alloc] initWithMachPort: machPort[0]])) {
			NSLog (@"Failed to create send mach port.");
			goto error_exit;
		}

		[instance->_sendPort setInvalidationCallBack: &sendPortInvalidationHandler andInfo: info];

		[instance->_listenPort setMessageCallBack: &commandHandler andInfo: info];

		return;

	error_exit:
		[instance quitWithReturnValue: 3];
	}

	static void commandHandler (ISSUMachPort *port, mach_msg_header_t *msg, void *info) {
		KeyboardMonitorApplication *instance = (__bridge KeyboardMonitorApplication *) info;
		int command;

		if (!ISSUCommandReceive (msg, &command)) {
			NSLog (@"Invalid message received.");
			goto error_exit;
		}

		switch (command) {
			case ISS_CMD_ACTIVATE_MONITOR:
				[instance createTracker];
				break;
			case ISS_CMD_DEACTIVATE_MONITOR:
				[instance destroyTracker];
				break;
			default:
				NSLog (@"Invalid command received: %d", command);
				goto error_exit;
		}
		return;

	error_exit:
		[instance quitWithReturnValue: 3];
	}

	static void sendPortInvalidationHandler (ISSUMachPort *port, void *info) {
		KeyboardMonitorApplication *instance = (__bridge KeyboardMonitorApplication *) info;

		// invalidation of the send port means the switcher has closed
		// the port, which is likely because it has exited, so here we
		// arrange for our clean exit too
		[instance quitWithReturnValue: 0];
	}

	static void deviceEventHandler (int eventCode, void *info) {
		KeyboardMonitorApplication *instance = (__bridge KeyboardMonitorApplication *) info;

		if (!ISSUCommandSend (instance->_sendPort, ISS_CMD_PERFORM_SWITCH)) {
			NSLog (@"Failed to send monitor event.");
			[instance quitWithReturnValue: 3];
		}
	}
@end


static void handleSignalAsQuit (void *info) {
	[MonitorApp quitWithReturnValue: 0];
}

static ISSUSignalHandlerTableEntry signalHandlerTable[] = {
	{SIGTERM, &handleSignalAsQuit},
	{SIGINT,  &handleSignalAsQuit}
};

static ISSUMachPortHolder *createClientPort (void) {
	NSString *name = ISSUGetPerProcessName (ISS_SERVER_PORT_NAME, getppid ());
	if (!name)
		return nil;

	ISSUMachPort *port = [ISSUMachPort portForName: name];
	if (!port)
		return nil;

	return [ISSUMachPortHolder holderWithPort: port];
}

int autoreleasedMain (int argc, char * const argv[]) {
	NSArray *signalHandlerManagers;
	ISSUMachPortHolder *clientPortHolder;

	if (!(signalHandlerManagers = ISSUSetupSignalHandlers (signalHandlerTable, ISSUArrayLength (signalHandlerTable)))) {
		NSLog (@"Failed to setup signal handlers.");
		goto error_exit;
	}

	if (geteuid () != 0) {
		NSURL *url = ISSUGetAbsoluteFileURL (argv[0]);

		NSLog (
			@"Keyboard monitor process is not running with superuser privileges, "
			"it will not be able to monitor keyboard events when secure input is "
			"enabled. Consider setting setuid root on its binary: %s",
			url ? url.fileSystemRepresentation : argv[0]
		);
	}

	if (!(clientPortHolder = createClientPort ())) {
		NSLog (@"Failed to create client mach port.");
		goto error_exit;
	}

	MonitorApp = [KeyboardMonitorApplication new];
	if (!MonitorApp)
		goto error_exit;

	int rv = [MonitorApp runWithClientPortHolder: clientPortHolder];

	MonitorApp = nil; // release the global instance
	return rv;

error_exit:
	return 2;
}
