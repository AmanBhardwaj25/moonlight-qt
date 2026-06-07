#import "AWDLManager.h"
#import <Foundation/Foundation.h>
#import <ServiceManagement/ServiceManagement.h>
#import <os/log.h>
#import <dispatch/dispatch.h>

static os_log_t sLog;
static dispatch_once_t sLogOnce;

// Must match helper/main.m
@protocol MoonlightAWDLHelperProtocol
- (void)setSuppressed:(BOOL)suppressed withReply:(void(^)(BOOL))reply;
- (void)checkInWithReply:(void(^)(BOOL))reply;
@end

static const char* kMachService  = "com.moonlight-stream.xpc.MoonlightAWDLHelper";
static const char* kPlistName    = "com.moonlight-stream.MoonlightAWDLHelper.plist";

AWDLManager& AWDLManager::instance() {
    static AWDLManager s;
    return s;
}

AWDLManager::AWDLManager() : m_suppressed(false), m_helperReady(false), m_conn(nullptr) {
    dispatch_once(&sLogOnce, ^{
        sLog = os_log_create("com.moonlight-stream.Moonlight", "AWDLManager");
    });
}

AWDLManager::~AWDLManager() {
    restore();
}

// ---------- helper installation (main thread required for SMAppService) ----------

bool AWDLManager::ensureHelperInstalled() {
    if (m_helperReady) return true;

    __block bool success = false;

    auto block = ^{
        if (@available(macOS 13.0, *)) {
            SMAppService *svc = [SMAppService
                daemonServiceWithPlistName:[NSString stringWithUTF8String:kPlistName]];

            NSError *err = nil;
            if (svc.status == SMAppServiceStatusEnabled) {
                success = true;
                return;
            }

            if ([svc registerAndReturnError:&err]) {
                success = true;
            } else {
                os_log_error(sLog, "SMAppService register failed: %{public}@", err);
            }
        } else {
            // macOS < 13: fall back to a one-shot sudo-based approach.
            // AuthorizationRef auth;
            // ... (not implemented for pre-13 in this build)
            os_log_error(sLog, "AWDL suppression requires macOS 13+");
        }
    };

    if (NSThread.isMainThread) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }

    m_helperReady = success;
    return success;
}

// ---------- XPC connection ----------

static NSXPCConnection* openConnection() {
    NSXPCConnection *conn = [[NSXPCConnection alloc]
        initWithMachServiceName:[NSString stringWithUTF8String:kMachService]
                        options:NSXPCConnectionPrivileged];
    conn.remoteObjectInterface = [NSXPCInterface
        interfaceWithProtocol:@protocol(MoonlightAWDLHelperProtocol)];
    [conn resume];
    return conn;
}

static id<MoonlightAWDLHelperProtocol> proxy(void* connPtr) {
    NSXPCConnection *conn = (__bridge NSXPCConnection *)connPtr;
    return [conn remoteObjectProxyWithErrorHandler:^(NSError *err) {
        os_log_error(sLog, "XPC error: %{public}@", err);
    }];
}

// ---------- public interface ----------

void AWDLManager::suppress() {
    if (m_suppressed) return;
    if (!m_helperReady) return;

    if (!m_conn) {
        NSXPCConnection *c = openConnection();
        [c retain];
        m_conn = (void*)c;
    }

    [proxy(m_conn) setSuppressed:YES withReply:^(BOOL ok) {
        os_log(sLog, "AWDL suppress: %s", ok ? "ok" : "failed");
    }];
    m_suppressed = true;
}

void AWDLManager::restore() {
    if (!m_suppressed || !m_conn) {
        m_suppressed = false;
        return;
    }
    [proxy(m_conn) setSuppressed:NO withReply:^(BOOL) {}];
    m_suppressed = false;

    NSXPCConnection *c = (NSXPCConnection*)m_conn;
    m_conn = nullptr;
    [c invalidate];
    [c release];
}

bool AWDLManager::toggle() {
    if (m_suppressed) restore();
    else              suppress();
    return m_suppressed;
}
