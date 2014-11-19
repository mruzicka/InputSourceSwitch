#import "InputSourceSwitch.h"
#import <AppKit/AppKit.h>
#import <IOKit/hid/IOHIDLib.h>
#import <Carbon/Carbon.h>
#import <sys/stat.h>


#define QuitEventSubType 0x5155


@interface DeviceState : NSObject
	- (void) setDeallocBlock: (void (^) ()) block;
@end

@implementation DeviceState {
	void (^deallocBlock) ();
}
	- (void) setDeallocBlock: (void (^) ()) block {
		deallocBlock = block;
	}

	- (void) dealloc {
		if (deallocBlock)
			deallocBlock ();
	}
@end


@interface DeviceStateRegistry : NSObject
	- (DeviceState *) registeredDeviceStateForTag: (void *) tag orRegister: (DeviceState *(^) ()) block;
@end

@implementation DeviceStateRegistry {
	CFMutableDictionaryRef deviceStateMap;
}
	- (instancetype) init {
		if (self = [super init]) {
			deviceStateMap = CFDictionaryCreateMutable (kCFAllocatorDefault, 0, NULL, NULL);
			if (!deviceStateMap)
				return nil;
		}
		return self;
	}

	- (DeviceState *) registeredDeviceStateForTag: (void *) tag orRegister: (DeviceState *(^) ()) block {
		if (!tag)
			return block ();

		DeviceState *state = (__bridge DeviceState *) CFDictionaryGetValue (deviceStateMap, tag);
		if (state)
			return state;

		state = block ();
		if (!state)
			return nil;

		[state setDeallocBlock: ^ {
			CFDictionaryRemoveValue (deviceStateMap, tag);
		}];
		CFDictionarySetValue (deviceStateMap, tag, (__bridge void *) state);

		return state;
	}

	- (void) dealloc {
		if (deviceStateMap)
			CFRelease (deviceStateMap);
	}
@end


@interface KeyboardDeviceState : DeviceState
	- (instancetype) initWithCapacity: (uint32_t) capacity;
	- (void) handleKey: (uint16_t) key status: (BOOL) pressed;
@end

@implementation KeyboardDeviceState {
	CFMutableBitVectorRef keyStates;
	uint16_t pressedKeysCount;
	uint8_t switchState;
}
	- (instancetype) initWithCapacity: (uint32_t) capacity {
		if (self = [super init]) {
			keyStates = CFBitVectorCreateMutable (kCFAllocatorDefault, capacity);
			if (!keyStates)
				return nil;
			CFBitVectorSetCount (keyStates, capacity);
		}
		return self;
	}

	- (instancetype) init {
		return [self initWithCapacity: 0];
	}

	- (void) performSwitch {
		NSArray *inputSources = (__bridge_transfer NSArray *) TISCreateInputSourceList (
			(__bridge CFDictionaryRef) @{
				(__bridge NSString *) kTISPropertyInputSourceCategory:
					(__bridge NSString *) kTISCategoryKeyboardInputSource,
				(__bridge NSString *) kTISPropertyInputSourceIsEnabled:       @YES,
				(__bridge NSString *) kTISPropertyInputSourceIsSelectCapable: @YES
			},
			NO
		);

		if ([inputSources count] < 2)
			return; // no point to switch if less than two sources are available

		[inputSources enumerateObjectsUsingBlock: ^ (id element, NSUInteger idx, BOOL *stop) {
			TISInputSourceRef inputSource = (__bridge TISInputSourceRef) element;
			CFTypeRef isSelectedValueRef = (CFTypeRef) TISGetInputSourceProperty (
				inputSource,
				kTISPropertyInputSourceIsSelected
			);

			if (
				isSelectedValueRef
				&&
				CFGetTypeID (isSelectedValueRef) == CFBooleanGetTypeID ()
				&&
				CFBooleanGetValue (isSelectedValueRef)
			) {
				idx = (idx + 1) % [inputSources count];
				TISSelectInputSource ((__bridge TISInputSourceRef) inputSources[idx]);
				*stop = YES;
			}
		}];
	}

	- (void) handleKey: (uint16_t) key status: (BOOL) pressed {
		if (CFBitVectorGetBitAtIndex (keyStates, (CFIndex) key) ^ (CFBit) pressed) {
			CFBitVectorSetBitAtIndex (keyStates, (CFIndex) key, (CFBit) pressed);
			pressed ? ++pressedKeysCount : --pressedKeysCount;
		}

		switch (switchState) {
			case 0:
				if (pressed && key == kHIDUsage_KeyboardLeftAlt && pressedKeysCount == 1) {
					// L-Alt pressed on its own
					switchState = 1;
					return;
				}
				break;

			case 1:
				if (pressed && key == kHIDUsage_KeyboardLeftShift) {
					// L-Shift pressed
					switchState = 2;
					return;
				}
				break;

			default:
				if (pressed)
					break;

				switch (key) {
					case kHIDUsage_KeyboardLeftShift:
						// L-Shift released
						[self performSwitch];
						switchState = 1;
						return;
					case kHIDUsage_KeyboardLeftAlt:
						// L-Alt released
						[self performSwitch];
				}
		}
		switchState = 0;
	}

	- (void) dealloc {
		if (keyStates)
			CFRelease (keyStates);
	}
@end


@interface KeyboardDeviceHandler : NSObject
	- (instancetype) initWithDeviceReference: (IOHIDDeviceRef) deviceRef andDeviceStateRegistry: registry;
@end

@implementation KeyboardDeviceHandler {
	IOHIDDeviceRef deviceReference;
	BOOL opened;
	KeyboardDeviceState *deviceState;
	uint32_t fnModifierKeyUsagePage;
	uint32_t fnModifierKeyUsage;
}
	- (instancetype) initWithDeviceReference: (IOHIDDeviceRef) deviceRef andDeviceStateRegistry: deviceStateRegistry {
		if (self = [super init]) {
			if (!(deviceReference = deviceRef))
				return nil;

			deviceState = (KeyboardDeviceState *) [deviceStateRegistry registeredDeviceStateForTag: [self deviceLocationTag] orRegister: ^ {
				return [[KeyboardDeviceState alloc] initWithCapacity: 0x200];
			}];
			if (!deviceState) {
				NSLog (@"Failed to obtain device state for device: %@", IOHIDDeviceGetProperty (deviceReference, CFSTR (kIOHIDProductKey)));
				return nil;
			}

			[self identifyFnModifierKey];

			IOReturn rv = IOHIDDeviceOpen (deviceReference, kIOHIDOptionsTypeNone);
			if (rv != kIOReturnSuccess) {
				NSLog (@"Failed to open device: %@: 0x%08x", IOHIDDeviceGetProperty (deviceReference, CFSTR (kIOHIDProductKey)), rv);
				return nil;
			}
			opened = YES;

			IOHIDDeviceRegisterInputValueCallback (deviceReference, inputValueCallback, (__bridge void *) self);

			NSLog (@"Added device: %@", IOHIDDeviceGetProperty (deviceReference, CFSTR (kIOHIDProductKey)));
		}
		return self;
	}

	- (instancetype) init {
		return nil;
	}

	- (void) identifyFnModifierKey {
		io_service_t ioService = IOHIDDeviceGetService (deviceReference);
		if (ioService == MACH_PORT_NULL)
			goto fail;

		io_iterator_t childrenIterator;

		if (
			IORegistryEntryCreateIterator (
				ioService,
				kIOServicePlane,
				kIORegistryIterateRecursively,
				&childrenIterator
			) != KERN_SUCCESS
		)
			goto fail;

		@try {
			io_registry_entry_t child;

			while ((child = IOIteratorNext (childrenIterator))) {
				@try {
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
						fnModifierKeyUsagePage = fnUsagePage.unsignedIntValue;
						fnModifierKeyUsage = fnUsage.unsignedIntValue;
						return;
					}
				} @finally {
					IOObjectRelease (child);
				}
			}
		} @finally {
			IOObjectRelease (childrenIterator);
		}
	fail:
		fnModifierKeyUsagePage = kHIDPage_Undefined;
	}

	- (void *) deviceLocationTag {
		NSNumber *locationId = ensureNumber (IOHIDDeviceGetProperty (deviceReference, CFSTR (kIOHIDLocationIDKey)));

		return locationId ? (void *) locationId.unsignedIntegerValue : NULL;
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
				usage |= 0x100;
				break;

			default:
				if (usagePage != fnModifierKeyUsagePage || fnModifierKeyUsagePage == kHIDPage_Undefined)
					return; // not anything we care about
				usage = IOHIDElementGetUsage (elem);
				if (!(usage == fnModifierKeyUsage))
					return; // not the Apple 'Fn' modifier key event
				usage = kHIDUsage_AppleVendorKeyboard_Function | 0x100;
				break;
		}

		CFIndex valueLength = IOHIDValueGetLength (valueRef);
		if (valueLength == 0 || valueLength > 8)
			return; // not an expected value

		[deviceState handleKey: (uint16_t) usage status: IOHIDValueGetIntegerValue (valueRef) != 0];
	}

	- (void) dealloc {
		if (opened) {
			IOHIDDeviceClose (deviceReference, kIOHIDOptionsTypeNone);
			NSLog (@"Removed device: %@", IOHIDDeviceGetProperty (deviceReference, CFSTR (kIOHIDProductKey)));
		}
	}

	static NSNumber *ensureNumber (CFTypeRef reference) {
		return (reference && CFGetTypeID (reference) == CFNumberGetTypeID ())
			? (__bridge NSNumber *) reference
			: nil;
	}

	static void inputValueCallback (void *context, IOReturn result, void *sender, IOHIDValueRef valueRef) {
		[(__bridge KeyboardDeviceHandler *) context handleInputValue: valueRef];
	}
@end


@implementation DeviceTracker {
	IOHIDManagerRef hidManager;
	CFMutableDictionaryRef deviceHandlerMap;
	DeviceStateRegistry *deviceStateRegistry;
}
	- (instancetype) init {
		if (self = [super init]) {
			deviceHandlerMap = CFDictionaryCreateMutable (kCFAllocatorDefault, 0, NULL, &kCFTypeDictionaryValueCallBacks);
			if (!deviceHandlerMap)
				return nil;

			deviceStateRegistry = [DeviceStateRegistry new];
			if (!deviceStateRegistry)
				return nil;

			hidManager = IOHIDManagerCreate (kCFAllocatorDefault, kIOHIDOptionsTypeNone);
			if (CFGetTypeID (hidManager) != IOHIDManagerGetTypeID ())
				return nil;

			if (![self setupMatching])
				return nil;

			IOHIDManagerRegisterDeviceMatchingCallback (hidManager, deviceAddedCallback, (__bridge void *) self);
			IOHIDManagerRegisterDeviceRemovalCallback (hidManager, deviceRemovedCallback, (__bridge void *) self);

			IOHIDManagerScheduleWithRunLoop (hidManager, CFRunLoopGetMain (), kCFRunLoopDefaultMode);
		}
		return self;
	}

	static NSMutableDictionary *usagePairMatchingDictionary (uint32_t usagePage, uint32_t usage) {
		NSMutableDictionary *dictionary = [[NSMutableDictionary alloc] initWithCapacity: 2];
		if (!dictionary)
			return nil;

		dictionary[@kIOHIDDeviceUsagePageKey] = @(usagePage);
		dictionary[@kIOHIDDeviceUsageKey]     = @(usage);

		return dictionary;
	}

	- (BOOL) setupMatching {
		NSMutableDictionary *dictionary;
		NSMutableArray *array = [[NSMutableArray alloc] initWithCapacity: 2];
		if (!array)
			return NO;

		// this dictionary will match keyboard devices
		dictionary = usagePairMatchingDictionary (kHIDPage_GenericDesktop, kHIDUsage_GD_Keyboard);
		if (!dictionary)
			return NO;

		[array addObject: dictionary];

		// this dictionary will match consumer control devices
		dictionary = usagePairMatchingDictionary (kHIDPage_Consumer, kHIDUsage_Csmr_ConsumerControl);
		if (!dictionary)
			return NO;

		[array addObject: dictionary];

		dictionary = [[NSMutableDictionary alloc] initWithCapacity: 1];
		if (!dictionary)
			return NO;

		dictionary[@kIOHIDDeviceUsagePairsKey] = array;

		IOHIDManagerSetDeviceMatching (hidManager, (__bridge CFDictionaryRef) dictionary);
		return YES;
	}

	- (void) dealloc {
		if (hidManager)
			IOHIDManagerUnscheduleFromRunLoop (hidManager, CFRunLoopGetMain (), kCFRunLoopDefaultMode);
		if (deviceHandlerMap)
			CFRelease (deviceHandlerMap);
		if (hidManager)
			CFRelease (hidManager);
	}

	static void deviceAddedCallback (void *context, IOReturn result, void *sender, IOHIDDeviceRef deviceRef) {
		DeviceTracker *tracker = (__bridge DeviceTracker *) context;

		if (CFDictionaryContainsKey (tracker->deviceHandlerMap, deviceRef))
			return;

		KeyboardDeviceHandler *handler = [[KeyboardDeviceHandler alloc]
			initWithDeviceReference: deviceRef
			andDeviceStateRegistry:  tracker->deviceStateRegistry
		];
		if (!handler)
			return;

		CFDictionarySetValue (tracker->deviceHandlerMap, deviceRef, (__bridge void *) handler);
	}

	static void deviceRemovedCallback (void *context, IOReturn result, void *sender, IOHIDDeviceRef deviceRef) {
		DeviceTracker *tracker = (__bridge DeviceTracker *) context;

		if (!CFDictionaryContainsKey (tracker->deviceHandlerMap, deviceRef))
			return;

		CFDictionaryRemoveValue (tracker->deviceHandlerMap, deviceRef);
	}
@end


@interface LockFile : NSObject
	@property (readonly) NSURL *url;
	@property (readonly) BOOL isLocked;

	- (instancetype) initWithAppName: (NSString *) appName;
	- (BOOL) lock;
	- (NSString *) read;
@end

@implementation LockFile {
	NSFileHandle *handle;
}
	- (instancetype) initWithAppName: (NSString *) appName {
		if (self = [super init]) {
			NSFileManager *fileManger = [NSFileManager defaultManager];
			NSURL *url = [fileManger
				URLForDirectory:   NSApplicationSupportDirectory
				inDomain:          NSUserDomainMask
				appropriateForURL: nil
				create:            NO
				error:             nil
			];
			if (!url)
				return nil;

			url = [url URLByAppendingPathComponent: appName isDirectory: YES];

			if (![fileManger createDirectoryAtURL: url withIntermediateDirectories: YES attributes: nil error: nil])
				return nil;

			_url = [url URLByAppendingPathComponent: @".lockfile" isDirectory: NO];

			int fd = open (_url.fileSystemRepresentation, O_RDWR|O_CREAT, 0644);
			if (fd == -1)
				return nil;

			handle = [[NSFileHandle alloc] initWithFileDescriptor: fd closeOnDealloc: YES];
			if (!handle)
				return nil;
		}
		return self;
	}

	- (instancetype) init {
		NSString *name = [[[NSBundle mainBundle] infoDictionary]
			objectForKey: (__bridge NSString *) kCFBundleExecutableKey
		];
		if (!name)
			name = [NSProcessInfo processInfo].processName;

		return [self initWithAppName: name];
	}

	- (BOOL) lock {
		if (_isLocked)
			return YES;

		if (flock (handle.fileDescriptor, LOCK_EX|LOCK_NB))
			return NO;

		struct stat fsstat, fdstat;

		if (stat (_url.fileSystemRepresentation, &fsstat) || fstat (handle.fileDescriptor, &fdstat))
			return NO;

		if (!(fsstat.st_dev == fdstat.st_dev && fsstat.st_ino == fdstat.st_ino))
			return NO;

		[handle truncateFileAtOffset: 0];
		[handle writeData: [[NSString stringWithFormat: @"%d", [NSProcessInfo processInfo].processIdentifier]
			dataUsingEncoding: NSISOLatin1StringEncoding
		]];
		[handle synchronizeFile];

		return (_isLocked = YES);
	}

	- (NSString *) read {
		[handle seekToFileOffset: 0];
		return [[NSString alloc] initWithData: [handle readDataOfLength: 1024] encoding: NSISOLatin1StringEncoding];
	}

	- (void) dealloc {
		if (_isLocked)
			[[NSFileManager defaultManager] removeItemAtURL: _url error: nil];
	}
@end


@interface InputSourceSwitchApplication : NSApplication
	@property (readonly) int returnValue;

	+ (instancetype) sharedApplication;
@end

@implementation InputSourceSwitchApplication {
	LockFile *lockFile;
	DeviceTracker *tracker;
	BOOL subscribed;
}
	+ (instancetype) sharedApplication {
		return (InputSourceSwitchApplication *) [super sharedApplication];
	}

	- (instancetype) init {
		if (self = [super init]) {
			if (
				!setupSignalHandler (SIGTERM, handleSignalAsQuit)
				||
				!setupSignalHandler (SIGINT, handleSignalAsQuit)
			) {
				NSLog (@"Failed to setup signal handlers.");
				return nil;
			}

			lockFile = [LockFile new];
			if (!lockFile) {
				NSLog (@"Failed to create lock file.");
				return nil;
			}

			if (![lockFile lock]) {
				NSString *pid = [lockFile read];
				if ([pid length] > 0)
					pid = [NSString stringWithFormat: @" (with PID: %@)", pid];
				NSLog (@"Another instance%@ is already running.", pid);
				_returnValue = 1;
			}
		}
		return self;
	}

	- (BOOL) createTracker {
		tracker = [DeviceTracker new];
		if (!tracker) {
			NSLog (@"Failed to create DeviceTracker.");
			return NO;
		}
		return YES;
	}

	- (void) recreateTracker {
		if (!tracker) {
			if (![self createTracker]) {
				_returnValue = 3;
				[self quitWithData: 0];
			}
		}
	}

	- (void) destroyTracker {
		if (tracker)
			tracker = nil;
	}

	- (void) receiveDectivationNote: (NSNotification *) note {
		if (subscribed) {
			NSLog (@"Received dectivation notfication: %@", [note name]);
			[self destroyTracker];
		}
	}

	- (void) receiveActivationNote: (NSNotification *) note {
		if (subscribed) {
			NSLog (@"Received activation notfication: %@", [note name]);
			[self recreateTracker];
		}
	}

	- (void) subscribeToNotification: (NSString *) notificationName withSelector: (SEL) notificationSelector {
		[[[NSWorkspace sharedWorkspace] notificationCenter]
			addObserver: self
			selector:    notificationSelector
			name:        notificationName
			object:      nil
		];
	}

	- (void) unsubscribeFromNotification: (NSString *) notificationName {
		[[[NSWorkspace sharedWorkspace] notificationCenter]
			removeObserver: self
			name:           notificationName
			object:         nil
		];
	}

	- (void) subscribeToNotifications {
		[self
			subscribeToNotification: NSWorkspaceWillSleepNotification
			withSelector:            @selector (receiveDectivationNote:)
		];
		[self
			subscribeToNotification: NSWorkspaceDidWakeNotification
			withSelector:            @selector (receiveActivationNote:)
		];
		[self
			subscribeToNotification: NSWorkspaceSessionDidResignActiveNotification
			withSelector:            @selector (receiveDectivationNote:)
		];
		[self
			subscribeToNotification: NSWorkspaceSessionDidBecomeActiveNotification
			withSelector:            @selector (receiveActivationNote:)
		];
		subscribed = YES;
	}

	- (void) unsubscribeFromNotifications {
		subscribed = NO;
		[self unsubscribeFromNotification: NSWorkspaceWillSleepNotification];
		[self unsubscribeFromNotification: NSWorkspaceDidWakeNotification];
		[self unsubscribeFromNotification: NSWorkspaceSessionDidResignActiveNotification];
		[self unsubscribeFromNotification: NSWorkspaceSessionDidBecomeActiveNotification];
	}

	- (void) runLoop {
		[self finishLaunching];

		_running = YES;
		do {
			@autoreleasepool {
				NSEvent *event = [self
					nextEventMatchingMask: NSAnyEventMask
					untilDate:             [NSDate distantFuture]
					inMode:                NSDefaultRunLoopMode
					dequeue:               YES
				];

				if (event.type == NSApplicationDefined && event.subtype == QuitEventSubType)
					_running = NO;
				else
					[self sendEvent: event];
			}
		} while (_running);
	}

	- (void) run {
		if (_returnValue)
			return;

		[self subscribeToNotifications];

		if (isSessionActive () && ![self createTracker])
			_returnValue = 2;
		else
			[self runLoop];

		[self unsubscribeFromNotifications];

		[self destroyTracker];
	}

	- (void) quitWithData: (int) data {
		[self
			postEvent: [NSEvent
				otherEventWithType: NSApplicationDefined
				location:           NSMakePoint (0, 0)
				modifierFlags:      0
				timestamp:          [NSProcessInfo processInfo].systemUptime
				windowNumber:       0
				context:            nil
				subtype:            QuitEventSubType
				data1:              data
				data2:              0
			]
			atStart: YES
		];
	}

	- (void) dealloc {
		lockFile = nil;
		setupSignalHandler (SIGTERM, SIG_DFL);
		setupSignalHandler (SIGINT, SIG_DFL);
	}

	static void handleSignalAsQuit (int signum) {
		[NSApp quitWithData: signum];
	}

	static BOOL setupSignalHandler (int signal, void (*handler) (int signum)) {
		struct sigaction action;

		memset (&action, 0, sizeof (action));
		action.sa_handler = handler;
		return !sigaction (signal, &action, NULL);
	}

	static BOOL isSessionActive () {
		NSDictionary *sessionInfo = (__bridge_transfer NSDictionary *) CGSessionCopyCurrentDictionary ();
		if (!sessionInfo)
			return NO;

		CFTypeRef isActiveValueRef = (__bridge CFTypeRef) sessionInfo[(__bridge NSString *) kCGSessionOnConsoleKey];

		return
			isActiveValueRef
			&&
			CFGetTypeID (isActiveValueRef) == CFBooleanGetTypeID ()
			&&
			CFBooleanGetValue (isActiveValueRef);
	}
@end


int main (int argc, const char *argv[]) {
	InputSourceSwitchApplication *app = [InputSourceSwitchApplication sharedApplication];
	if (!app)
		return 2;

	[app run];

	NSApp = nil; // release the global reference to the app
	return app.returnValue;
}
