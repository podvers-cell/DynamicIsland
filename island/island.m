// Every now playing session macOS knows about (what Control Center lists), not only the
// elected one. Built into MediaRemoteAdapter.framework and called from island.pl, because
// only an entitled binary like /usr/bin/perl may read MediaRemote on macOS 15.4+.
//
// Private API signatures from ungive/mediaremote-adapter PR #42.

#import <Foundation/Foundation.h>
#include <dlfcn.h>

typedef void (^ClientsCB)(NSArray *clients);
typedef void (^InfoCB)(NSDictionary *info, NSError *error);
typedef void (^StateCB)(unsigned int state);
typedef void (^SendCB)(id result);

static void *mr(const char *name) {
    static void *h;
    if (!h) h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    return dlsym(h, name);
}

#define MR(ret, name, ...) static ret (*name)(__VA_ARGS__);
MR(void, MRMediaRemoteGetNowPlayingClients, dispatch_queue_t, ClientsCB)
MR(CFStringRef, MRNowPlayingClientGetBundleIdentifier, id)
MR(CFStringRef, MRNowPlayingClientGetParentAppBundleIdentifier, id)
MR(id, MRMediaRemoteGetLocalOrigin, void)
MR(CFTypeRef, MRNowPlayingPlayerPathCreate, id, id, id)
MR(void, MRMediaRemoteGetNowPlayingInfoForPlayer, id, void *, dispatch_queue_t, InfoCB)
MR(void, MRMediaRemoteGetPlaybackStateForPlayer, id, dispatch_queue_t, StateCB)
MR(void, MRMediaRemoteSendCommandToPlayer, unsigned int, CFDictionaryRef, id, unsigned int, dispatch_queue_t, SendCB)

static void load(void) {
#define L(name) name = mr(#name)
    L(MRMediaRemoteGetNowPlayingClients); L(MRNowPlayingClientGetBundleIdentifier);
    L(MRNowPlayingClientGetParentAppBundleIdentifier); L(MRMediaRemoteGetLocalOrigin);
    L(MRNowPlayingPlayerPathCreate); L(MRMediaRemoteGetNowPlayingInfoForPlayer);
    L(MRMediaRemoteGetPlaybackStateForPlayer); L(MRMediaRemoteSendCommandToPlayer);
}

static NSString *bundleOf(id client) {
    // Browser tabs and helpers report a child bundle; group them under the app.
    CFStringRef parent = MRNowPlayingClientGetParentAppBundleIdentifier ? MRNowPlayingClientGetParentAppBundleIdentifier(client) : NULL;
    CFStringRef b = parent ?: MRNowPlayingClientGetBundleIdentifier(client);
    return b ? (__bridge NSString *)b : nil;
}

static NSArray *clients(void) {
    __block NSArray *out = @[];
    dispatch_semaphore_t s = dispatch_semaphore_create(0);
    MRMediaRemoteGetNowPlayingClients(dispatch_get_global_queue(0, 0), ^(NSArray *c) { out = c ?: @[]; dispatch_semaphore_signal(s); });
    dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    return out;
}

static id pathFor(id client) {
    return (__bridge_transfer id)MRNowPlayingPlayerPathCreate(MRMediaRemoteGetLocalOrigin(), client, nil);
}

// Prints one JSON line per second: [{bundle, playing, title, artist, duration, elapsed, timestamp, artwork?}]
// artwork (base64) is only sent when a session's track changes.
void island_sessions(void) {
    load();
    NSMutableDictionary *lastTrack = [NSMutableDictionary dictionary];
    for (;;) {
        @autoreleasepool {
            NSMutableArray *rows = [NSMutableArray array];
            NSMutableSet *seen = [NSMutableSet set];
            for (id c in clients()) {
                NSString *bundle = bundleOf(c);
                if (!bundle || [seen containsObject:bundle]) continue;
                id path = pathFor(c);
                __block NSDictionary *info = nil;
                __block unsigned int state = 0;
                dispatch_group_t g = dispatch_group_create();
                dispatch_group_enter(g);
                MRMediaRemoteGetNowPlayingInfoForPlayer(path, NULL, dispatch_get_global_queue(0, 0), ^(NSDictionary *i, NSError *e) { info = i; dispatch_group_leave(g); });
                dispatch_group_enter(g);
                MRMediaRemoteGetPlaybackStateForPlayer(path, dispatch_get_global_queue(0, 0), ^(unsigned int st) { state = st; dispatch_group_leave(g); });
                dispatch_group_wait(g, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));

                NSString *title = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
                if (![title isKindOfClass:NSString.class] || title.length == 0) continue;
                [seen addObject:bundle];
                NSMutableDictionary *row = [@{@"bundle": bundle, @"title": title, @"playing": @(state == 1)} mutableCopy];
                id v;
                if ((v = info[@"kMRMediaRemoteNowPlayingInfoArtist"]) && [v isKindOfClass:NSString.class]) row[@"artist"] = v;
                if ((v = info[@"kMRMediaRemoteNowPlayingInfoDuration"]) && [v isKindOfClass:NSNumber.class]) row[@"duration"] = v;
                if ((v = info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"]) && [v isKindOfClass:NSNumber.class]) row[@"elapsed"] = v;
                if ((v = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"]) && [v isKindOfClass:NSDate.class]) row[@"timestamp"] = @([v timeIntervalSince1970]);
                NSString *key = [NSString stringWithFormat:@"%@|%@", title, row[@"artist"] ?: @""];
                NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                if ([art isKindOfClass:NSData.class] && ![lastTrack[bundle] isEqual:key]) {
                    row[@"artwork"] = [art base64EncodedStringWithOptions:0];
                    lastTrack[bundle] = key;
                }
                [rows addObject:row];
            }
            NSData *json = [NSJSONSerialization dataWithJSONObject:rows options:0 error:nil];
            fwrite(json.bytes, 1, json.length, stdout);
            fputc('\n', stdout);
            fflush(stdout);
        }
        sleep(1);
        if (getppid() == 1) exit(0);  // the app quit or crashed: don't linger as an orphan
    }
}

// ISLAND_BUNDLE + ISLAND_COMMAND (MediaRemote command id), optional ISLAND_POSITION (seconds, for seek = 24).
void island_send(void) {
    load();
    NSString *target = NSProcessInfo.processInfo.environment[@"ISLAND_BUNDLE"];
    unsigned int cmd = (unsigned int)[NSProcessInfo.processInfo.environment[@"ISLAND_COMMAND"] intValue];
    NSString *pos = NSProcessInfo.processInfo.environment[@"ISLAND_POSITION"];
    for (id c in clients()) {
        if (![bundleOf(c) isEqualToString:target]) continue;
        NSDictionary *opts = pos ? @{@"kMRMediaRemoteOptionPlaybackPosition": @(pos.doubleValue)} : @{};
        dispatch_semaphore_t s = dispatch_semaphore_create(0);
        MRMediaRemoteSendCommandToPlayer(cmd, (__bridge CFDictionaryRef)opts, pathFor(c), 0, dispatch_get_global_queue(0, 0), ^(id r) { dispatch_semaphore_signal(s); });
        dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
        return;
    }
}
