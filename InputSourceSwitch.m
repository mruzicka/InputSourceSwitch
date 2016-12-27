#import "ISSUtils.h"
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <sys/stat.h>
#import <dlfcn.h>

#import "InputSourceSwitch.h"


#ifndef ISS_MONITOR_EXECUTABLE
#define ISS_MONITOR_EXECUTABLE "KeyboardMonitor"
#endif

#define ISS_LOCKFILE_ENCODING NSISOLatin1StringEncoding

#define ISS_QUIT_EVENT_SUBTYPE 0x5155

#define ISS_ERROR_EXIT_CODE 127


@interface LockFile : NSObject
	@property (readonly) NSURL *url;
	@property (readonly) BOOL isLocked;

	- (instancetype) initWithAppName: (NSString *) appName;
	- (BOOL) lock;
@end

@implementation LockFile {
	NSFileHandle *handle;
}
	- (instancetype) init {
		NSString *name = [[[NSBundle mainBundle] infoDictionary]
			objectForKey: (__bridge NSString *) kCFBundleExecutableKey
		];
		if (!name)
			name = [NSProcessInfo processInfo].processName;

		return [self initWithAppName: name];
	}

	- (instancetype) initWithAppName: (NSString *) appName {
		if (self = [super init]) {
			int fd = [self open: appName];
			if (fd < 0)
				return nil;

			handle = [[NSFileHandle alloc] initWithFileDescriptor: fd closeOnDealloc: YES];
			if (!handle) {
				close (fd);
				return nil;
			}
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
		if (!url)
			return -1;

		_url = [url URLByAppendingPathComponent: @".lockfile" isDirectory: NO];
		if (!_url)
			return -1;

		if (![fileManager createDirectoryAtURL: url withIntermediateDirectories: YES attributes: nil error: nil])
			return -1;

		return open (_url.fileSystemRepresentation, O_RDWR|O_CREAT, 0644);
	}

	- (BOOL) lock {
		if (_isLocked)
			return YES;

		if (flock (handle.fileDescriptor, LOCK_EX|LOCK_NB)) {
			int pid = [self readPID];
			NSLog (@"Another instance%@ is already running.",
				(pid > 0) ? [NSString stringWithFormat: @" (PID %d)", pid] : @""
			);
			return NO;
		}

		if (![self isOwned]) {
			NSLog (@"Lockfile ownership verification failed.");
			return NO;
		}

		[self writePID];

		return (_isLocked = YES);
	}

	- (BOOL) isOwned {
		struct stat fsstat, fdstat;

		if (stat (_url.fileSystemRepresentation, &fsstat) || fstat (handle.fileDescriptor, &fdstat))
			return NO;

		return (fsstat.st_dev == fdstat.st_dev && fsstat.st_ino == fdstat.st_ino);
	}

	- (int) readPID {
		[handle seekToFileOffset: 0];
		return [[NSString alloc]
			initWithData: [handle readDataOfLength: 1024]
			encoding: ISS_LOCKFILE_ENCODING
		].intValue;
	}

	- (void) writePID {
		[handle truncateFileAtOffset: 0];
		[handle
			writeData: [[NSString stringWithFormat: @"%d", getpid ()]
				dataUsingEncoding: ISS_LOCKFILE_ENCODING
			]
		];
		[handle synchronizeFile];
	}

	- (void) dealloc {
		if (_isLocked && [self isOwned])
			[[NSFileManager defaultManager] removeItemAtURL: _url error: nil];
	}
@end


@interface DynamicBSM : NSObject
	- (pid_t) pidFromAuditToken: (audit_token_t *) auditToken;
@end

@implementation DynamicBSM {
	void *_handle;
	pid_t (*_audit_token_to_pid) (audit_token_t token);
}
	- (instancetype) init {
		if (self = [super init]) {
			if (!(_handle = dlopen ("libbsm.dylib", RTLD_GLOBAL)))
				return nil;

			if (!(_audit_token_to_pid = dlsym (_handle, "audit_token_to_pid")))
				return nil;
		}
		return self;
	}

	- (pid_t) pidFromAuditToken: (audit_token_t *) auditToken {
		return _audit_token_to_pid (*auditToken);
	}

	- (void) dealloc {
		if (_handle)
			dlclose (_handle);
	}
@end


@interface InputSourceSwitchApplication : NSApplication
	- (int) runWithServerPortHolder: (ISSUMachPortHolder *) serverPortHolder andMonitorPID: (pid_t) monitorPID;
	- (void) quitWithReturnValue: (int) returnValue;
@end

@implementation InputSourceSwitchApplication {
	pid_t _monitorPID;
	DynamicBSM *_bsm;
	ISSUMachPort *_listenPort;
	ISSUMachPort *_sendPort;
	BOOL _subscribed;
	int _returnValue;
}
	- (void) receiveDectivationNote: (NSNotification *) note {
		if (_subscribed) {
			NSLog (@"Received dectivation notfication: %@", [note name]);
			[self sendMonitorCommand: ISS_CMD_DEACTIVATE_MONITOR];
		}
	}

	- (void) receiveActivationNote: (NSNotification *) note {
		if (_subscribed) {
			NSLog (@"Received activation notfication: %@", [note name]);
			[self sendMonitorCommand: ISS_CMD_ACTIVATE_MONITOR];
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
#if 0
		[self
			subscribeToNotification: NSWorkspaceWillSleepNotification
			withSelector:            @selector (receiveDectivationNote:)
		];
		[self
			subscribeToNotification: NSWorkspaceDidWakeNotification
			withSelector:            @selector (receiveActivationNote:)
		];
#endif
		[self
			subscribeToNotification: NSWorkspaceSessionDidResignActiveNotification
			withSelector:            @selector (receiveDectivationNote:)
		];
		[self
			subscribeToNotification: NSWorkspaceSessionDidBecomeActiveNotification
			withSelector:            @selector (receiveActivationNote:)
		];
		_subscribed = YES;
	}

	- (void) unsubscribeFromNotifications {
		_subscribed = NO;
#if 0
		[self unsubscribeFromNotification: NSWorkspaceWillSleepNotification];
		[self unsubscribeFromNotification: NSWorkspaceDidWakeNotification];
#endif
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

				if (event.type == NSApplicationDefined && event.subtype == ISS_QUIT_EVENT_SUBTYPE) {
					_returnValue = event.data1;
					_running = NO;
				} else
					[self sendEvent: event];
			}
		} while (_running);
	}

	- (void) run {
		_returnValue = 0;

		[self subscribeToNotifications];

		@try {
			[self runLoop];
		} @finally {
			[self unsubscribeFromNotifications];
		}
	}

	- (int) runWithServerPortHolder: (ISSUMachPortHolder *) serverPortHolder andMonitorPID: (pid_t) monitorPID {
		@try {
			_monitorPID = monitorPID;
			if (_monitorPID > 0 && !(_bsm = [DynamicBSM new])) {
				NSLog (@"Process identity verification required but libbsm could not be loaded.");
				return (_returnValue = 2);
			}

			_listenPort = [serverPortHolder get];

			[_listenPort setMessageCallBack: &portExchangeHandler andInfo: (__bridge void *) self];

			if (![_listenPort scheduleInRunLoop: CFRunLoopGetMain () forMode: kCFRunLoopDefaultMode]) {
				NSLog (@"Failed to schedule server mach port.");
				_returnValue = 2;
			} else
				[self run];

			return _returnValue;
		} @finally {
			_monitorPID = 0;
			_bsm = nil;
			_listenPort = nil;
			_sendPort = nil;
		}
	}

	- (void) sendMonitorCommand: (int) command {
		if (_sendPort)
			if (!ISSUCommandSend (_sendPort, command)) {
				NSLog (@"Failed to send monitor command.");
				[self quitWithReturnValue: 3];
			}
	}

	- (void) quitWithReturnValue: (int) returnValue {
		[self
			postEvent: [NSEvent
				otherEventWithType: NSApplicationDefined
				location:           NSMakePoint (0, 0)
				modifierFlags:      0
				timestamp:          [NSProcessInfo processInfo].systemUptime
				windowNumber:       0
				context:            nil
				subtype:            ISS_QUIT_EVENT_SUBTYPE
				data1:              returnValue
				data2:              0
			]
			atStart: YES
		];
	}

	static BOOL isSessionActive (void) {
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

	static void portExchangeHandler (ISSUMachPort *port, mach_msg_header_t *msg, void *info) {
		InputSourceSwitchApplication *instance = (__bridge InputSourceSwitchApplication *) info;
		ISSUMachPort *listenPort, *sendPort;
		mach_port_t machPort;
		BOOL ignore;

		if (instance->_monitorPID > 0) {
			audit_token_t *auditToken;

			if (ISSUGetAuditToken (msg, &auditToken)) {
				pid_t pid = [instance->_bsm pidFromAuditToken: auditToken];
				if ((ignore = (pid != instance->_monitorPID)))
					NSLog (@"Ignoring message from unauthorized process PID: %d", pid);
			} else {
				ignore = YES;
				NSLog (@"Ignoring message without audit token.");
			}
		} else
			ignore = NO;

		if (!ISSUPortRightsReceive (msg, &machPort, 1)) {
			if (ignore)
				return;
			NSLog (@"Failed to receive mach port rights.");
			goto error_exit;
		}

		if (!(sendPort = [[ISSUMachPort alloc] initWithMachPort: machPort])) {
			if (ignore)
				return;
			NSLog (@"Failed to create send mach port.");
			goto error_exit;
		}

		if (ignore) {
			ISSUCommandSend (sendPort, -1);
			return;
		}

		instance->_sendPort = sendPort;

		// now replace the listen port which is registered with the bootstrap
		// server (the "server port") with an anonymous one (the "listen port")

		if (!(listenPort = [ISSUMachPort new])) {
			NSLog (@"Failed to create listen mach port.");
			goto error_exit;
		}

		[listenPort setMessageCallBack: &monitorEventHandler andInfo: info];

		if (![listenPort scheduleInRunLoop: CFRunLoopGetMain () forMode: kCFRunLoopDefaultMode]) {
			NSLog (@"Failed to schedule listen mach port.");
			goto error_exit;
		}

		machPort = listenPort.machPort;

		// send the new listen port to the monitor process
		if (!ISSUPortRightsSend (instance->_sendPort, &machPort, 1)) {
			NSLog (@"Failed to send mach port rights.");
			goto error_exit;
		}

		if (isSessionActive ())
			[instance sendMonitorCommand: ISS_CMD_ACTIVATE_MONITOR];

		instance->_listenPort = listenPort;
		instance->_bsm = nil; // this is not needed beyond port exchange

		return;

	error_exit:
		[instance quitWithReturnValue: 3];
	}

	static void monitorEventHandler (ISSUMachPort *port, mach_msg_header_t *msg, void *info) {
		InputSourceSwitchApplication *instance = (__bridge InputSourceSwitchApplication *) info;
		int command;

		if (!ISSUCommandReceive (msg, &command)) {
			NSLog (@"Invalid message received.");
			goto error_exit;
		}

		switch (command) {
			case ISS_CMD_PERFORM_SWITCH:
				switchInputSource ();
				break;
			default:
				NSLog (@"Invalid command received: %d", command);
				goto error_exit;
		}
		return;

	error_exit:
		[instance quitWithReturnValue: 3];
	}

	static void switchInputSource (void) {
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
				inputSource = (__bridge TISInputSourceRef) inputSources[(idx + 1) % [inputSources count]];

				TISSelectInputSource (inputSource);

				*stop = YES;
			}
		}];
	}
@end


static void handleSignalAsQuit (void *info) {
	[NSApp quitWithReturnValue: 0];
}

static void handleChildDeath (void *info) {
	int status;

	// reap the child
	if (waitpid (-1, &status, WNOHANG) > 0) {
		if (WIFEXITED (status)) {
			int exitStatus = WEXITSTATUS (status);
			if (exitStatus)
				NSLog (@"Monitor process exited unexpectedly with exit status: %d", exitStatus);
			else
				NSLog (@"Monitor process exited unexpectedly.");
		} else if (WIFSIGNALED (status)) {
			int signum = WTERMSIG (status);
			NSLog (@"Monitor process was terminated unexpectedly by signal: %d (SIG%@)", signum, [@(sys_signame[signum]) uppercaseString]);
		}
	} else
		NSLog (@"Failed to get the monitor process exit status.");

	[NSApp quitWithReturnValue: 3];
}

static ISSUSignalHandlerTableEntry signalHandlerTable[] = {
	{SIGTERM, &handleSignalAsQuit},
	{SIGINT,  &handleSignalAsQuit},
	{SIGCHLD, &handleChildDeath}
};

static NSURL *getMonitorExecutableURL (char *argv0) {
	NSURL *url = ISSUGetAbsoluteFileURL (argv0);
	if (!url)
		return nil;

	url = [url URLByDeletingLastPathComponent];
	if (!url)
		return nil;

	return [NSURL
		fileURLWithFileSystemRepresentation: ISS_MONITOR_EXECUTABLE
		isDirectory:                         NO
		relativeToURL:                       url
	];
}

static ISSUMachPortHolder *createServerPort (void) {
	NSString *name = ISSUGetPerProcessName (ISS_SERVER_PORT_NAME, getpid ());
	if (!name)
		return nil;

	ISSUMachPort *port = [ISSUMachPort new];
	if (!port)
		return nil;

	if (![port registerName: name])
		return nil;

	return [ISSUMachPortHolder holderWithPort: port];
}


int main (int argc, char * const argv[]) {
	LockFile *lockFile;
	ISSUMachPortHolder *serverPortHolder;
	pid_t pid;

	if (!ISSUSetupSignalHandlers (signalHandlerTable, ISSUArrayLength (signalHandlerTable))) {
		NSLog (@"Failed to setup signal handlers.");
		goto error_exit;
	}

	if (!(lockFile = [LockFile new])) {
		NSLog (@"Failed to create lockfile.");
		goto error_exit;
	}
	if (![lockFile lock])
		goto error_exit;

	{
		NSURL *monitorExecutableURL = getMonitorExecutableURL (argv[0]);
		if (!monitorExecutableURL) {
			NSLog (@"Failed to build monitor executable path.");
			goto error_exit;
		}
		if (access (monitorExecutableURL.fileSystemRepresentation, X_OK) != 0) {
			NSLog (@"Monitor executable not present/executable: %s", monitorExecutableURL.fileSystemRepresentation);
			goto error_exit;
		}

		// if the creation of the bootstrap subset (a private namespace for port
		// registrations) is successfull we don't need to verify the identity of
		// the monitor process when it checks in as no other process can obtain
		// ports registered in the subset
		BOOL privateBootstrapNamespace = ISSUCreateBoostrapSubset (NULL);

		if (!(serverPortHolder = createServerPort ())) {
			NSLog (@"Failed to create server mach port.");
			goto error_exit;
		}

		switch (pid = fork ()) {
			case -1: { // error
				NSLog (@"Failed to fork: %s", strerror (errno));
				goto error_exit;
			}
			case 0: { // child / monitor
				char *monitorCmd[] = {(char *) monitorExecutableURL.fileSystemRepresentation, NULL};

				// start the monitor process
				execvp (*monitorCmd, monitorCmd);

				_exit (ISS_ERROR_EXIT_CODE);
			}
		}

		// we negate the PID if the server port is registered in a private bootstrap
		// namespace
		// the negative PID causes the InputSourceSwitchApplication to skip the
		// verification of the identity of the monitor process
		if (privateBootstrapNamespace)
			pid = -pid;
	}

	// parent / switch application
	[InputSourceSwitchApplication sharedApplication];
	if (!NSApp)
		goto error_exit;

	int rv = [NSApp runWithServerPortHolder: serverPortHolder andMonitorPID: pid];

	NSApp = nil; // release the global application instance
	return rv;

error_exit:
	return 2;
}
