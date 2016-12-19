#import <Foundation/Foundation.h>


#define ISSUArrayLength(array) (sizeof (array) / sizeof (*(array)))


@class ISSUMachPort;

typedef struct {
	int signum;
	void (*handler) (void *info);
} ISSUSignalHandlerTableEntry;

typedef void (*ISSUMachPortMessageCallBack) (ISSUMachPort *port, mach_msg_header_t *msg, void *info);

typedef void (*ISSUMachPortInvalidationCallBack) (ISSUMachPort *port, void *info);


@interface ISSUMachPort : NSObject
	@property (readonly) mach_port_t machPort;

	+ (instancetype) portForName: (NSString *) name;

	- (instancetype) initWithMachPort: (mach_port_t) machPort;

	- (BOOL) registerName: (NSString *) name;

	- (void) setMessageCallBack: (ISSUMachPortMessageCallBack) callback andInfo: (void *) info;

	- (void) setInvalidationCallBack: (ISSUMachPortInvalidationCallBack) callback andInfo: (void *) info;

	- (BOOL) scheduleInRunLoop: (CFRunLoopRef) runLoop forMode: (CFStringRef) mode;

	- (void) unschedule;
@end


@interface ISSUMachPortHolder : NSObject
	+ (instancetype) holderWithPort: (ISSUMachPort *) port;

	- (instancetype) init NS_UNAVAILABLE;
	- (instancetype) initWithPort: (ISSUMachPort *) port;
	- (ISSUMachPort *) get;
	- (void) set: (ISSUMachPort *) port;
@end


BOOL ISSUSetupSignalHandler (int signum, void (*handler) (void *info));

BOOL ISSUSetupSignalHandlers (ISSUSignalHandlerTableEntry signalHandlerTable[], int entryCount);

NSURL *ISSUGetAbsoluteFileURL (char *filePath);

NSString *ISSUGetPerProcessName (char *name, pid_t pid);

BOOL ISSUCreateBoostrapSubset (mach_port_t *parentBootstrapPort);

BOOL ISSUGetAuditToken (mach_msg_header_t *msg, audit_token_t **auditToken);

mach_msg_descriptor_t *ISSUNextDescriptor (mach_msg_descriptor_t *current);

BOOL ISSUPortRightsSend (ISSUMachPort *port, mach_port_t rightsArray[], int rightsCount);

BOOL ISSUPortRightsReceive (mach_msg_header_t *msg, mach_port_t rightsArray[], int rightsCount);

BOOL ISSUCommandSend (ISSUMachPort *port, int command);

BOOL ISSUCommandReceive (mach_msg_header_t *msg, int *command);