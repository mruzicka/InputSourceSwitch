#import <AppKit/AppKit.h>
#import <IOKit/hid/IOHIDLib.h>
#import <IOKit/IOMessage.h>
#import <Carbon/Carbon.h>
#import <sys/stat.h>
#import "InputSourceSwitch.h"

#define SLAVE_EXIT_CODE 127
#define LOCKFILE_ENCODING NSISOLatin1StringEncoding
#define LOCKFILE_FD 15


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
	IONotificationPortRef busyStateNotifyPort;
	io_object_t busyStateNotification;
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

			[self initiateFnModifierKeyIdentification];

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

	- (void) initiateFnModifierKeyIdentification {
		fnModifierKeyUsagePage = kHIDPage_Undefined;

		io_service_t service = IOHIDDeviceGetService (deviceReference);
		if (service == MACH_PORT_NULL)
			return;

		busyStateNotifyPort = IONotificationPortCreate (kIOMasterPortDefault);
		if (!busyStateNotifyPort)
			return;

		if (
			IOServiceAddInterestNotification (
				busyStateNotifyPort,
				service,
				kIOBusyInterest,
				busyStateChangeCallback,
				(__bridge void *) self,
				&busyStateNotification
			) != KERN_SUCCESS
		) {
			IONotificationPortDestroy (busyStateNotifyPort);
			busyStateNotifyPort = NULL;
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
				(void *) (NSUInteger) busyState
			), busyStateNotifyPort)
		)
			CFRunLoopAddSource (
				CFRunLoopGetMain (),
				IONotificationPortGetRunLoopSource (busyStateNotifyPort),
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
				fnModifierKeyUsagePage = fnUsagePage.unsignedIntValue;
				fnModifierKeyUsage = fnUsage.unsignedIntValue;
				IOObjectRelease (child);
				break;
			}
		}

		IOObjectRelease (childrenIterator);
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
		if (busyStateNotifyPort) {
			IOObjectRelease (busyStateNotification);
			IONotificationPortDestroy (busyStateNotifyPort); // this releases the associated CFRunLoopSource
		}
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

	static void busyStateChangeCallback (void *context, io_service_t service, uint32_t messageType, void *messageArgument) {
		if (messageType != kIOMessageServiceBusyStateChange)
			return;

		if ((uint32_t) messageArgument)
			return; // busyState > 0

		KeyboardDeviceHandler *handler = (__bridge KeyboardDeviceHandler *) context;

		IOObjectRelease (handler->busyStateNotification);
		IONotificationPortDestroy (handler->busyStateNotifyPort); // this releases the associated CFRunLoopSource
		handler->busyStateNotifyPort = NULL;

		[handler identifyFnModifierKey: service];
	}
@end


@interface DeviceTracker : NSObject
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


@interface InputSourceSwitchApplication : NSApplication
	@property (readonly) int returnValue;

	+ (instancetype) sharedApplication;
@end

@implementation InputSourceSwitchApplication {
	DeviceTracker *tracker;
	BOOL subscribed;
}
	+ (instancetype) sharedApplication {
		return (InputSourceSwitchApplication *) [super sharedApplication];
	}

	- (instancetype) init {
		if (self = [super init]) {
			if (!setupSignalHandlers (handleSignalAsQuit, NO)) {
				NSLog (@"Failed to setup signal handlers.");
				return nil;
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
		setupSignalHandlers (SIG_DFL, NO);
	}

	static void handleSignalAsQuit (int signum) {
		[NSApp quitWithData: signum];
	}

	static BOOL maskSignals (int how) {
		sigset_t set;

		sigemptyset (&set);
		sigaddset (&set, SIGTERM);
		sigaddset (&set, SIGINT);

		return !sigprocmask (how, &set, NULL);
	}

	static BOOL setupSignalHandler (int signal, void (*handler) (int signum), BOOL restart) {
		struct sigaction action;

		memset (&action, 0, sizeof (action));
		action.sa_handler = handler;
		if (restart)
			action.sa_flags = SA_RESTART;

		return !sigaction (signal, &action, NULL);
	}

	static BOOL setupSignalHandlers (void (*handler) (int signum), BOOL restart) {
		return
			setupSignalHandler (SIGTERM, handler, restart)
			&&
			setupSignalHandler (SIGINT, handler, restart);
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


@interface LockFile : NSObject
	@property (readonly) NSURL *url;
	@property (readonly) BOOL isLocked;

	- (instancetype) initWithAppName: (NSString *) appName;
	- (BOOL) ensureLocked;
	- (BOOL) handDown;
@end

@implementation LockFile {
	NSFileHandle *handle;
}
	- (instancetype) init {
		if (fcntl (LOCKFILE_FD, F_GETFD) != -1) {
			// we've inherited a lockfile
			int fd = dup (LOCKFILE_FD);

			close (LOCKFILE_FD);

			return [self initWithFd: fd];
		}

		// we need to create our own lockfile
		NSString *name = [[[NSBundle mainBundle] infoDictionary]
			objectForKey: (__bridge NSString *) kCFBundleExecutableKey
		];
		if (!name)
			name = [NSProcessInfo processInfo].processName;

		return [self initWithAppName: name];
	}

	- (instancetype) initWithFd: (int) fd {
		if (!(self = [super init]))
			return nil;

		return [self finishInit: fd];
	}

	- (instancetype) initWithAppName: (NSString *) appName {
		if (!(self = [super init]))
			return nil;

		return [self finishInit: [self open: appName]];
	}

	- (instancetype) __attribute__ ((objc_method_family (init))) finishInit: (int) fd {
		if (fd == -1)
			return nil;

		handle = [[NSFileHandle alloc] initWithFileDescriptor: fd closeOnDealloc: YES];
		if (!handle) {
			close (fd);
			return nil;
		}

		return self;
	}

	- (int) open: (NSString *) appName {
		NSFileManager *fileManager = [NSFileManager defaultManager];
		NSURL *url = [fileManager
			URLForDirectory:   NSApplicationSupportDirectory
			inDomain:          NSUserDomainMask
			appropriateForURL: nil
			create:            NO
			error:             nil
		];
		if (!url)
			return -1;

		url = [url URLByAppendingPathComponent: appName isDirectory: YES];
		_url = [url URLByAppendingPathComponent: @".lockfile" isDirectory: NO];

		if (![fileManager createDirectoryAtURL: url withIntermediateDirectories: YES attributes: nil error: nil])
			return -1;

		return open (_url.fileSystemRepresentation, O_RDWR|O_CREAT, 0644);
	}

	- (BOOL) ensureLocked {
		if (_isLocked)
			return YES;

		if (_url) {
			if (flock (handle.fileDescriptor, LOCK_EX|LOCK_NB)) {
				logAnotherInstance ([self readPid]);
				return NO;
			}

			if (![self isOwned]) {
				NSLog (@"Lockfile ownership verification failed.");
				return NO;
			}

			[self writePid];
		} else {
			int pid = [self readPid];

			if (flock (handle.fileDescriptor, LOCK_EX|LOCK_NB) || pid != getppid ()) {
				logAnotherInstance (pid);
				return NO;
			}
		}

		return (_isLocked = YES);
	}

	- (BOOL) isOwned {
		struct stat fsstat, fdstat;

		if (stat (_url.fileSystemRepresentation, &fsstat) || fstat (handle.fileDescriptor, &fdstat))
			return NO;

		return (fsstat.st_dev == fdstat.st_dev && fsstat.st_ino == fdstat.st_ino);
	}

	- (int) readPid {
		[handle seekToFileOffset: 0];
		return [[NSString alloc]
			initWithData: [handle readDataOfLength: 1024]
			encoding: LOCKFILE_ENCODING
		].intValue;
	}

	- (void) writePid {
		[handle truncateFileAtOffset: 0];
		[handle
			writeData: [[NSString stringWithFormat: @"%d", getpid ()]
				dataUsingEncoding: LOCKFILE_ENCODING
			]
		];
		[handle synchronizeFile];
	}

	- (BOOL) handDown {
		// release _url so that the lockfile is not removed on dealloc
		_url = nil;

		int fd = dup2 (handle.fileDescriptor, LOCKFILE_FD);

		// release handle so that the original fd is closed
		handle = nil;

		return (fd != -1);
	}

	- (void) dealloc {
		if (_isLocked && [self isOwned])
			[[NSFileManager defaultManager] removeItemAtURL: _url error: nil];
	}

	static void logAnotherInstance (int pid) {
		NSLog (@"Another instance%@ is already running.",
			(pid > 0) ? [NSString stringWithFormat: @" (with PID %d)", pid] : @""
		);
	}

	static uid_t giveupSuidPrivileges () {
		uid_t ruid = getuid ();
		uid_t euid = geteuid ();

		if (ruid != euid)
			seteuid (ruid);
		else
			euid = -1;

		return euid;
	}

	static gid_t giveupSgidPrivileges () {
		gid_t rgid = getgid ();
		gid_t egid = getegid ();

		if (rgid != egid)
			setegid (rgid);
		else
			egid = -1;

		return egid;
	}

	static uid_t assumeSuidIdentity () {
		uid_t ruid = getuid ();
		uid_t euid = geteuid ();

		if (ruid != euid)
			setuid (euid);
		else
			ruid = -1;

		return ruid;
	}

	static gid_t assumeSgidIdentity () {
		gid_t rgid = getgid ();
		gid_t egid = getegid ();

		if (rgid != egid)
			setgid (egid);
		else
			rgid = -1;

		return rgid;
	}

	static void restoreSuidPrivileges (uid_t suid) {
		if (suid != -1)
			seteuid (suid);
	}

	static void restoreSgidPrivileges (gid_t sgid) {
		if (sgid != -1)
			setegid (sgid);
	}

	static NSObject *runUnprivileged (NSObject *(^block) ()) {
		uid_t suid = giveupSuidPrivileges ();
		gid_t sgid = giveupSgidPrivileges ();

		@try {
			return block ();
		} @finally {
			restoreSuidPrivileges (suid);
			restoreSgidPrivileges (sgid);
		}
	}
@end


static pid_t slave;


static void forwardSignal (int signum) {
	kill (slave, signum);
}

int main (int argc, char * const argv[]) {
	LockFile *lockFile = (LockFile *) runUnprivileged (^ {return [LockFile new];});
	int rv;

	if (!lockFile) {
		NSLog (@"Failed to create lockfile.");
		goto error_exit;
	}

	if (![lockFile ensureLocked])
		goto error_exit;

	if (!issetugid ()) {
		// not running as issetugid - we can do our job
		InputSourceSwitchApplication *app = [InputSourceSwitchApplication sharedApplication];
		if (!app)
			goto error_exit;

		[app run];

		NSApp = nil; // release the global reference to the app
		rv = app.returnValue;
		goto normal_exit;
	}

	if (!maskSignals (SIG_BLOCK)) {
		NSLog (@"Failed to block signals: %s", strerror (errno));
		goto error_exit;
	}

	switch (slave = fork ()) {
		case -1: { // error
			NSLog (@"Failed to fork: %s", strerror (errno));
			goto error_exit;
		}
		case 0: { // child/slave
			if (!maskSignals (SIG_UNBLOCK)) {
				NSLog (@"Failed to unblock signals: %s", strerror (errno));
				_exit (SLAVE_EXIT_CODE);
			}

			if (![lockFile handDown]) {
				NSLog (@"Failed to hand down lockfile.");
				_exit (SLAVE_EXIT_CODE);
			}

			// get rid of the issetugid stigma
			assumeSuidIdentity ();
			assumeSgidIdentity ();

			// restart so that issetugid () returns false
			execvp (*argv, argv);

			NSLog (@"Failed to exec slave: %s", strerror (errno));
			_exit (SLAVE_EXIT_CODE);
		}
		default: { // parent/master
			if (!setupSignalHandlers (forwardSignal, YES)) {
				kill (slave, SIGTERM);
				NSLog (@"Failed to setup signal handlers: %s", strerror (errno));
				goto error_exit;
			}
			if (!maskSignals (SIG_UNBLOCK)) {
				kill (slave, SIGTERM);
				NSLog (@"Failed to unblock signals: %s", strerror (errno));
				goto error_exit;
			}

			int status;
			rv = waitpid (slave, &status, 0);

			setupSignalHandlers (SIG_DFL, NO);

			if (rv == -1) {
				kill (slave, SIGTERM);
				NSLog (@"Failed to wait for slave: %s", strerror (errno));
				goto error_exit;
			}

			if (WIFEXITED (status)) {
				rv = WEXITSTATUS (status);
				goto normal_exit;
			}

			if (WIFSIGNALED (status)) {
				int signum = WTERMSIG (status);
				NSLog (@"Slave was terminated by signal: %d (SIG%@)", signum, [@(sys_signame[signum]) uppercaseString]);
				goto error_exit;
			}

			NSLog (@"Slave terminated with unexpected status: 0x%08x", status);
			goto error_exit;
		}
	}

error_exit:
	rv = 2;

normal_exit:
	lockFile = nil;

	// give up privileges before exiting
	giveupSuidPrivileges ();
	giveupSgidPrivileges ();

	return rv;
}
