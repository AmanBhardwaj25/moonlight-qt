#import "AWDLMonitor.h"
#include <net/if.h>
#include <net/route.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <poll.h>
#include <unistd.h>
#include <os/log.h>

static os_log_t sLog;

@implementation AWDLMonitor {
    int _ioctlSock;   // AF_INET sock for SIOCGIFFLAGS/SIOCSIFFLAGS
    int _routeSock;   // AF_ROUTE sock for monitoring
    int _pipe[2];     // control pipe: [0]=read [1]=write
    unsigned int _awdlIfIndex;
    BOOL _suppressing;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        static dispatch_once_t once;
        dispatch_once(&once, ^{ sLog = os_log_create("com.moonlight-stream.MoonlightAWDLHelper", "AWDLMonitor"); });

        _ioctlSock   = socket(AF_INET, SOCK_DGRAM, 0);
        _routeSock   = -1;
        _pipe[0]     = _pipe[1] = -1;
        _awdlIfIndex = if_nametoindex("awdl0");
        _suppressing = NO;
    }
    return self;
}

- (void)dealloc {
    [self stopSuppressing];
    if (_ioctlSock >= 0) { close(_ioctlSock); _ioctlSock = -1; }
}

- (BOOL)isAWDLUp {
    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    strlcpy(ifr.ifr_name, "awdl0", sizeof(ifr.ifr_name));
    if (ioctl(_ioctlSock, SIOCGIFFLAGS, &ifr) < 0) return NO;
    return (ifr.ifr_flags & IFF_UP) != 0;
}

- (void)setAWDLUp:(BOOL)up {
    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    strlcpy(ifr.ifr_name, "awdl0", sizeof(ifr.ifr_name));
    if (ioctl(_ioctlSock, SIOCGIFFLAGS, &ifr) < 0) {
        os_log_error(sLog, "SIOCGIFFLAGS failed: %d", errno);
        return;
    }
    if (up) ifr.ifr_flags |=  IFF_UP;
    else    ifr.ifr_flags &= ~IFF_UP;
    if (ioctl(_ioctlSock, SIOCSIFFLAGS, &ifr) < 0) {
        os_log_error(sLog, "SIOCSIFFLAGS(%s) failed: %d", up ? "UP" : "DOWN", errno);
    }
}

- (void)startSuppressing {
    if (_suppressing) return;
    _suppressing = YES;

    [self setAWDLUp:NO];

    pipe(_pipe);
    _routeSock = socket(AF_ROUTE, SOCK_RAW, 0);

    // Run the monitor loop on a background thread.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [self _monitorLoop];
    });
}

- (void)stopSuppressing {
    if (!_suppressing) return;
    _suppressing = NO;

    // Signal the loop to quit.
    if (_pipe[1] >= 0) {
        char q = 'Q';
        write(_pipe[1], &q, 1);
    }

    [self setAWDLUp:YES];
}

- (void)_monitorLoop {
    struct pollfd fds[2];
    fds[0].fd = _routeSock;   fds[0].events = POLLIN;
    fds[1].fd = _pipe[0];     fds[1].events = POLLIN;

    while (1) {
        if (poll(fds, 2, -1) < 0) break;

        // Check control pipe first.
        if (fds[1].revents & POLLIN) {
            char cmd = 0;
            read(_pipe[0], &cmd, 1);
            if (cmd == 'Q') break;
        }

        // Check route socket for interface state changes.
        if (fds[0].revents & POLLIN) {
            char buf[4096];
            ssize_t n = read(_routeSock, buf, sizeof(buf));
            if (n >= (ssize_t)sizeof(struct if_msghdr)) {
                struct if_msghdr *ifm = (struct if_msghdr *)buf;
                // RTM_IFINFO fires when an interface's flags change.
                if (ifm->ifm_type == RTM_IFINFO &&
                    ifm->ifm_index == (int)_awdlIfIndex &&
                    (ifm->ifm_flags & IFF_UP)) {
                    // Something brought awdl0 up — push it back down.
                    os_log(sLog, "awdl0 came up unexpectedly, suppressing");
                    [self setAWDLUp:NO];
                }
            }
        }
    }

    if (_routeSock >= 0) { close(_routeSock); _routeSock = -1; }
    if (_pipe[0]   >= 0) { close(_pipe[0]);   _pipe[0]   = -1; }
    if (_pipe[1]   >= 0) { close(_pipe[1]);   _pipe[1]   = -1; }
}

@end
