#pragma once
#import <Foundation/Foundation.h>

// Runs as root inside the privileged helper. Monitors awdl0 via an AF_ROUTE
// socket and immediately brings it back down whenever macOS raises it.
@interface AWDLMonitor : NSObject

- (BOOL)isAWDLUp;
- (void)setAWDLUp:(BOOL)up;   // one-shot toggle
- (void)startSuppressing;     // begin watcher loop
- (void)stopSuppressing;      // end watcher loop, restore awdl0

@end
