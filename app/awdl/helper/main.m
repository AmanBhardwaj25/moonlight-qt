#import <Foundation/Foundation.h>
#import "AWDLMonitor.h"
#import <os/log.h>

static os_log_t sLog;

// XPC protocol shared with the main app (must match AWDLManager.mm).
@protocol MoonlightAWDLHelperProtocol
- (void)setSuppressed:(BOOL)suppressed withReply:(void(^)(BOOL))reply;
- (void)checkInWithReply:(void(^)(BOOL))reply;
@end

@interface AWDLHelperService : NSObject <NSXPCListenerDelegate, MoonlightAWDLHelperProtocol>
@property (nonatomic, strong) AWDLMonitor *monitor;
@end

@implementation AWDLHelperService

- (instancetype)init {
    self = [super init];
    if (self) {
        _monitor = [[AWDLMonitor alloc] init];
    }
    return self;
}

// NSXPCListenerDelegate — called for each incoming connection.
- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)conn {
    conn.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(MoonlightAWDLHelperProtocol)];
    conn.exportedObject    = self;

    // When the main app disconnects (stream ends or app quits), restore AWDL and exit.
    __weak typeof(self) weakSelf = self;
    conn.invalidationHandler = ^{
        os_log(sLog, "XPC connection invalidated — restoring AWDL and exiting");
        [weakSelf.monitor stopSuppressing];
        exit(0);
    };

    [conn resume];
    return YES;
}

- (void)setSuppressed:(BOOL)suppressed withReply:(void(^)(BOOL))reply {
    if (suppressed) {
        [_monitor startSuppressing];
    } else {
        [_monitor stopSuppressing];
    }
    reply(YES);
}

- (void)checkInWithReply:(void(^)(BOOL))reply {
    reply(YES);
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        sLog = os_log_create("com.moonlight-stream.MoonlightAWDLHelper", "main");
        os_log(sLog, "MoonlightAWDLHelper starting");

        AWDLHelperService *service = [[AWDLHelperService alloc] init];
        NSXPCListener *listener = [[NSXPCListener alloc]
            initWithMachServiceName:@"com.moonlight-stream.xpc.MoonlightAWDLHelper"];
        listener.delegate = service;
        [listener resume];

        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}
