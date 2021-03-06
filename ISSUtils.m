#import "ISSUtils.h"
#import <mach/mach.h>
#import <servers/bootstrap.h>


@implementation ISSUMachPort {
	BOOL _destroyMachPort;
	CFMachPortRef _port;
	CFRunLoopSourceRef _runLoopSource;
	ISSUMachPortMessageCallBack _messageCallback;
	void *_messageCallbackInfo;
	ISSUMachPortInvalidationCallBack _invalidationCallback;
	void *_invalidationCallbackInfo;
}
	+ (instancetype) portForName: (NSString *) name {
		mach_port_t machPort;

		{
			NSPort *port = [[NSMachBootstrapServer sharedInstance]
				portForName: name
			];
			if (!port || ![port isKindOfClass: [NSMachPort class]])
				return nil;

			machPort = ((NSMachPort *) port).machPort;

			// increase the send right reference count by one so that the mach port
			// is not destroyed during invalidation of the owning NSMachPort instance
			if (mach_port_mod_refs (mach_task_self (), machPort, MACH_PORT_RIGHT_SEND, 1) != KERN_SUCCESS)
				return nil;

			// make sure the mach port is not owned by the NSMachPort instance any more
			[port invalidate];
		}

		ISSUMachPort *instance = [[self alloc] initWithMachPort: machPort];
		if (!instance) {
			// decrease the reference count to balance the earlier increase
			mach_port_mod_refs (mach_task_self (), machPort, MACH_PORT_RIGHT_SEND, -1);
			return nil;
		}

		return instance;
	}

	- (instancetype) init {
		mach_port_t machPort;

		if (mach_port_allocate (mach_task_self (), MACH_PORT_RIGHT_RECEIVE, &machPort) != KERN_SUCCESS)
			return nil;

		if (mach_port_insert_right (mach_task_self (), machPort, machPort, MACH_MSG_TYPE_MAKE_SEND) != KERN_SUCCESS)
			goto error_exit;

		if (self = [self initWithMachPort: machPort])
			return self;

	error_exit:
		mach_port_destroy (mach_task_self (), machPort);
		return nil;
	}

	- (instancetype) initWithMachPort: (mach_port_t) machPort {
		if (self = [super init]) {
			_machPort = machPort;

			CFMachPortContext context;

			memset (&context, 0, sizeof (context));
			context.info = (__bridge void *) self;

			if (!(_port = CFMachPortCreateWithPort (kCFAllocatorDefault, _machPort, &ISSUMachPortMessageHandler, &context, NULL)))
				return nil;

			CFMachPortGetContext (_port, &context);
			if (context.info != (__bridge void *) self) {
				// the mach port is owned by another CFMachPort instance - release it
				// but don't invalidate
				CFRelease (_port);
				_port = NULL;
				return nil;
			}

			_destroyMachPort = YES;
		}
		return self;
	}

	- (BOOL) registerName: (NSString *) name {
		return [[NSMachBootstrapServer sharedInstance]
			registerPort: [NSMachPort
				portWithMachPort: _machPort
				options:          NSMachPortDeallocateNone
			]
			name: name
		];
	}

	- (void) setMessageCallBack: (ISSUMachPortMessageCallBack) callback andInfo: (void *) info {
		_messageCallback = callback;
		_messageCallbackInfo = info;
	}

	- (void) setInvalidationCallBack: (ISSUMachPortInvalidationCallBack) callback andInfo: (void *) info {
		_invalidationCallback = callback;
		_invalidationCallbackInfo = info;
	}

	- (BOOL) scheduleInRunLoop: (CFRunLoopRef) runLoop forMode: (CFStringRef) mode {
		if (!_runLoopSource && !(_runLoopSource = CFMachPortCreateRunLoopSource (kCFAllocatorDefault, _port, 0)))
			return NO;

		CFRunLoopAddSource (runLoop, _runLoopSource, mode);

		return YES;
	}

	- (void) unschedule {
		if (_runLoopSource) {
			CFRunLoopSourceInvalidate (_runLoopSource);
			CFRelease (_runLoopSource);
			_runLoopSource = NULL;
		}
	}

	- (void) dealloc {
		if (_port) {
			if (_runLoopSource) {
				CFRunLoopSourceInvalidate (_runLoopSource);
				CFRelease (_runLoopSource);
			}
			CFMachPortSetInvalidationCallBack (_port, NULL);
			CFMachPortInvalidate (_port);
			CFRelease (_port);
		}
		if (_destroyMachPort)
			mach_port_destroy (mach_task_self (), _machPort);
	}

	static void ISSUMachPortMessageHandler (CFMachPortRef port, void *msg, CFIndex size, void *info) {
		ISSUMachPort *instance = (__bridge ISSUMachPort *) info;
		ISSUMachPortMessageCallBack callback = instance->_messageCallback;

		if (callback)
			callback (instance, msg, instance->_messageCallbackInfo);
		else
			NSLog (@"ISSUMachPort scheduled without callback.");
	}

	static void ISSUMachPortInvalidationHandler (CFMachPortRef port, void *info) {
		ISSUMachPort *instance = (__bridge ISSUMachPort *) info;
		ISSUMachPortInvalidationCallBack callback = instance->_invalidationCallback;

		if (callback)
			callback (instance, instance->_invalidationCallbackInfo);
	}
@end


@implementation ISSUMachPortHolder {
	ISSUMachPort *_port;
}
	+ (instancetype) holderWithPort: (ISSUMachPort *) port {
		return [[self alloc] initWithPort: port];
	}

	- (instancetype) initWithPort: (ISSUMachPort *) port {
		if (self = [super init])
			_port = port;
		return self;
	}

	- (ISSUMachPort *) get {
		ISSUMachPort *port = _port;

		_port = nil;

		return port;
	}

	- (void) set: (ISSUMachPort *) port {
		_port = port;
	}
@end


@interface ISSUSignalHandlerManager : NSObject
	+ (instancetype) managerForSignalHandlerTableEntry: (ISSUSignalHandlerTableEntry *) entry;

	- (instancetype) init NS_UNAVAILABLE;
	- (instancetype) initForSignalHandlerTableEntry: (ISSUSignalHandlerTableEntry *) entry;
@end

@implementation ISSUSignalHandlerManager {
	int _signum;
	struct sigaction _action;
	dispatch_source_t _dispatchSource;
}
	+ (instancetype) managerForSignalHandlerTableEntry: (ISSUSignalHandlerTableEntry *) entry {
		return [[self alloc] initForSignalHandlerTableEntry: entry];
	}

	- (instancetype) initForSignalHandlerTableEntry: (ISSUSignalHandlerTableEntry *) entry {
		if (!entry)
			return nil;

		if (self = [super init]) {
			int signum = entry->signum;

			// setup a noop handler to ensure the signal is delivered
			// and doesn't kill the process (note that using SIG_IGN
			// instead of a noop handler doesn't work for at least the
			// SIGCHLD signal)
			{
				struct sigaction action;

				memset (&action, 0, sizeof (action));
				action.sa_handler = &ISSUNoopHandler;

				if (sigaction (signum, &action, &_action) != 0)
					return nil;
			}

			_signum = signum; // dealloc resets the signal action if _signum is set

			dispatch_source_t source = dispatch_source_create (DISPATCH_SOURCE_TYPE_SIGNAL, signum, 0, dispatch_get_main_queue ());
			if (!source)
				return nil;

			dispatch_set_context (source, (uint8_t *) NULL + signum);
			dispatch_source_set_event_handler_f (source, entry->handler);

			dispatch_resume (source);

			_dispatchSource = source;
		}
		return self;
	}

	- (void) dealloc {
		if (_dispatchSource)
			dispatch_source_cancel (_dispatchSource);
		if (_signum)
			sigaction (_signum, &_action, NULL);
	}

	static void ISSUNoopHandler (int signum) {
	}
@end

NSArray *ISSUSetupSignalHandlers (ISSUSignalHandlerTableEntry signalHandlerTable[], int entryCount) {
	@autoreleasepool {
		NSMutableArray *managers = [NSMutableArray arrayWithCapacity: entryCount];
		if (!managers)
			return nil;

		for (; entryCount > 0; --entryCount, ++signalHandlerTable) {
			ISSUSignalHandlerManager *manager = [ISSUSignalHandlerManager managerForSignalHandlerTableEntry: signalHandlerTable];
			if (!manager)
				return nil;

			[managers addObject: manager];
		}

		return managers;
	}
}

NSURL *ISSUGetAbsoluteFileURL (char *filePath) {
	NSURL *url = [NSURL
		fileURLWithPath: NSFileManager.defaultManager.currentDirectoryPath
		isDirectory:     YES
	];
	if (!url)
		return nil;

	return [NSURL
		fileURLWithFileSystemRepresentation: filePath
		isDirectory:                         NO
		relativeToURL:                       url
	];
}

NSString *ISSUGetPerProcessName (char *name, pid_t pid) {
	return [NSString stringWithFormat: @"%s.%d", name, pid];
}

mach_port_t ISSUGetBootstrapPort (void) {
	mach_port_t bootstrapPort;

	if (task_get_bootstrap_port (mach_task_self (), &bootstrapPort) != KERN_SUCCESS)
		return MACH_PORT_NULL;

	return bootstrapPort;
}

mach_port_t ISSUCreateBootstrapSubset (mach_port_t requestorPort) {
	mach_port_t bootstrapPort = ISSUGetBootstrapPort ();
	if (bootstrapPort == MACH_PORT_NULL)
		return MACH_PORT_NULL;

	mach_port_t subsetPort;

	if (
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
		bootstrap_subset
#pragma clang diagnostic pop
		(
			bootstrapPort, requestorPort, &subsetPort
		) != BOOTSTRAP_SUCCESS
	)
		return MACH_PORT_NULL;

	if (task_set_special_port (mach_task_self (), TASK_BOOTSTRAP_PORT, subsetPort) != KERN_SUCCESS) {
		mach_port_destroy (mach_task_self (), subsetPort);
		return MACH_PORT_NULL;
	}

	return bootstrapPort;
}

BOOL ISSUResetBootstrapPort (mach_port_t bootstrapPort) {
	mach_port_t subsetPort = ISSUGetBootstrapPort ();
	if (bootstrapPort == MACH_PORT_NULL)
		return NO;

	if (task_set_special_port (mach_task_self (), TASK_BOOTSTRAP_PORT, bootstrapPort) != KERN_SUCCESS)
		return NO;

	if (mach_port_destroy (mach_task_self (), subsetPort) != KERN_SUCCESS)
		return NO;

	return YES;
}

BOOL ISSUGetAuditToken (mach_msg_header_t *msg, audit_token_t **auditToken) {
	mach_msg_trailer_t *trailer = (mach_msg_trailer_t *) (((uint8_t *) msg) + round_msg (msg->msgh_size));

	if (trailer->msgh_trailer_type != MACH_MSG_TRAILER_FORMAT_0)
		return NO;

	if (trailer->msgh_trailer_size < sizeof (mach_msg_audit_trailer_t))
		return NO;

	*auditToken = &((mach_msg_audit_trailer_t *) trailer)->msgh_audit;
	return YES;
}

mach_msg_descriptor_t *ISSUNextDescriptor (mach_msg_descriptor_t *current) {
	mach_msg_descriptor_type_t type = current->type.type;

	switch (type) {
		case MACH_MSG_PORT_DESCRIPTOR:
			return (mach_msg_descriptor_t *) (&current->port + 1);

		case MACH_MSG_OOL_DESCRIPTOR:
		case MACH_MSG_OOL_VOLATILE_DESCRIPTOR:
			return (mach_msg_descriptor_t *) (&current->out_of_line + 1);

		case MACH_MSG_OOL_PORTS_DESCRIPTOR:
			return (mach_msg_descriptor_t *) (&current->ool_ports + 1);
	}

	NSLog (@"Unknown descriptor type %u encountered, assuming maximum descriptor length.", type);

	return current + 1;
}

BOOL ISSUPortRightsSend (ISSUMachPort *port, mach_port_t rightsArray[], int rightsCount) {
	struct {
		mach_msg_header_t          header;
		mach_msg_body_t            body;
		mach_msg_port_descriptor_t rights[0];
	} *msg;
	uint8_t buffer[sizeof (*msg) + sizeof (mach_msg_port_descriptor_t) * rightsCount];

	memset (buffer, 0, sizeof (buffer));
	msg = (void *) buffer;

	msg->header.msgh_bits = MACH_MSGH_BITS (MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
	msg->header.msgh_size = sizeof (buffer);
	msg->header.msgh_remote_port = port.machPort;
	msg->header.msgh_local_port = MACH_PORT_NULL;

	msg->body.msgh_descriptor_count = rightsCount;

	for (mach_msg_port_descriptor_t *descriptor = msg->rights; rightsCount > 0; --rightsCount, ++rightsArray, ++descriptor) {
		descriptor->name = *rightsArray;
		descriptor->disposition = MACH_MSG_TYPE_COPY_SEND;
		descriptor->type = MACH_MSG_PORT_DESCRIPTOR;
	}

	return (mach_msg_send (&msg->header) == KERN_SUCCESS);
}

int ISSUPortRightsReceive (mach_msg_header_t *msg, mach_port_t rightsArray[], int maxRightsCount) {
	if (!(msg->msgh_bits & MACH_MSGH_BITS_COMPLEX))
		return -1;

	if (msg->msgh_size < sizeof (mach_msg_header_t) + sizeof (mach_msg_body_t))
		return -1;

	mach_msg_body_t *body = (mach_msg_body_t *) (msg + 1);
	int count = body->msgh_descriptor_count;
	void *end = ((uint8_t *) msg) + msg->msgh_size;
	int remainingRightsCount = maxRightsCount;

	for (
		mach_msg_descriptor_t *next = (mach_msg_descriptor_t *) (body + 1)
		;
		remainingRightsCount > 0
		;
		--remainingRightsCount, ++rightsArray
	) {
		for (
			mach_msg_descriptor_t *current = next
			;
			count > 0 && (--count, YES) && (void *) (&current->type + 1) <= end && (void *) (next = ISSUNextDescriptor (current)) <= end
			;
			current = next
		) {
			if (current->type.type == MACH_MSG_PORT_DESCRIPTOR) {
				*rightsArray = current->port.name;
				goto continue_outer;
			}
		}
		break;

	continue_outer:
		;
	}

	return (maxRightsCount - remainingRightsCount);
}

BOOL ISSUCommandSend (ISSUMachPort *port, int command) {
	struct {
		mach_msg_header_t          header;
	} *msg;
	uint8_t buffer[sizeof (*msg)];

	memset (buffer, 0, sizeof (buffer));
	msg = (void *) buffer;

	msg->header.msgh_bits = MACH_MSGH_BITS (MACH_MSG_TYPE_COPY_SEND, 0);
	msg->header.msgh_size = sizeof (buffer);
	msg->header.msgh_remote_port = port.machPort;
	msg->header.msgh_local_port = MACH_PORT_NULL;
	msg->header.msgh_id = command;

	return (mach_msg_send (&msg->header) == KERN_SUCCESS);
}

BOOL ISSUCommandReceive (mach_msg_header_t *msg, int *command) {
	if (msg->msgh_size < sizeof (mach_msg_header_t))
		return NO;

	*command = msg->msgh_id;
	return YES;
}

int main (int argc, char * const argv[]) {
	@autoreleasepool {
		return autoreleasedMain (argc, argv);
	}
}
