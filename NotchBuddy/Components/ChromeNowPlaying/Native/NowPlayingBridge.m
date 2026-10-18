// Original Coucou Media Lab implementation. No third-party source is included.
// Private macOS symbols are confined to this optional helper.
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <signal.h>
#import <unistd.h>
#import <math.h>
#import <limits.h>

static dispatch_queue_t work;
static void (*readInfo)(dispatch_queue_t, void (^)(NSDictionary *));
static void (*readPID)(dispatch_queue_t, void (^)(int));
static void (*readPlaying)(dispatch_queue_t, void (^)(BOOL));
static void (*subscribe)(dispatch_queue_t);
static void (*unsubscribe)(void);
// Signatures verified against Apple's public WebKit MediaRemote SPI declarations.

static void *(*localOrigin)(void);
static void (*readSupported)(void *, dispatch_queue_t, void (^)(CFArrayRef));
static Boolean (*sendToApp)(uint32_t, CFDictionaryRef, void *, CFStringRef, uint32_t,
                           dispatch_queue_t, void (^)(uint32_t, CFArrayRef));

static BOOL (*sendBasic)(unsigned int, NSDictionary *);
static void (*seekBasic)(double);
@protocol CoucouCommandInfo <NSObject>
- (uint32_t)command;
- (BOOL)isEnabled;
@end

static NSDictionary *previous;
static NSMutableData *input;
static BOOL pending, fetching, rerun;
static NSUInteger artworkRevision;
static NSData *lastArtwork;
static NSString *lastIdentity;
static dispatch_source_t stdinSource;
static NSUInteger readGeneration;

static void emit(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    if (!data) return;
    // Serial queue: one bounded JSON line at a time, never metadata to stderr.
    const uint8_t newline = '\n';
    NSMutableData *line = [data mutableCopy];
    [line appendBytes:&newline length:1];
    const uint8_t *bytes = line.bytes;
    NSUInteger remaining = line.length;
    while (remaining) {
        ssize_t count = write(STDOUT_FILENO, bytes, remaining);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) _exit(0); // Parent closed its pipe; no orphan helper.
        remaining -= (NSUInteger)count;
        bytes += count;
    }
}

static void stopWithError(NSString *message) {
    emit(@{@"type":@"error", @"message":message});
    exit(1);
}

static double finiteNumber(id value, double fallback) {
    if (![value isKindOfClass:NSNumber.class]) return fallback;
    double number = [value doubleValue];
    return isfinite(number) ? number : fallback;
}

static NSString *text(id value) {
    if (![value isKindOfClass:NSString.class]) return @"";
    NSString *s = value;
    return s.length > 2048 ? [s substringToIndex:2048] : s;
}

// Dedicated integrations own these players, even when their cards are disabled.
static BOOL eligibleBundle(NSString *bundle) {
    return bundle.length > 0 && bundle.length <= 2048 &&
        ![bundle isEqualToString:@"com.apple.Music"] &&
        ![bundle isEqualToString:@"com.spotify.client"];
}

static void supportedCommands(void (^completion)(NSSet<NSNumber *> *)) {
    if (!readSupported || !localOrigin) {
        completion(nil);
        return;
    }
    __block BOOL finished = NO;
    readSupported(localOrigin(), work, ^(CFArrayRef raw) {
        if (finished) return;
        finished = YES;
        if (!raw || CFGetTypeID(raw) != CFArrayGetTypeID()) {
            completion(nil);
            return;
        }
        NSArray *entries = (__bridge NSArray *)raw;
        if (entries.count > 256) {
            completion(nil);
            return;
        }
        NSMutableSet *commands = NSMutableSet.set;
        for (id entry in entries) {
            if (![entry respondsToSelector:@selector(command)] || ![entry respondsToSelector:@selector(isEnabled)]) {
                completion(nil); return;
            }
            id<CoucouCommandInfo> value = entry;
            if (value.isEnabled) [commands addObject:@(value.command)];
        }
        // An empty result while a media session exists is not reliable evidence
        // that all actions (including Play/Pause) are unavailable. Keep it unknown.
        completion(entries.count ? commands : nil);
    });
    // Optional capability lookup must not prevent metadata from being displayed.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), work, ^{
        if (!finished) {
            finished = YES;
            completion(nil);
        }
    });
}

static NSDictionary *capabilitySnapshot(NSSet<NSNumber *> *commands) {
    // C logical expressions box as numbers unless converted to explicit CF booleans.
    return @{
        @"controlsKnown": commands ? @YES : @NO,
        @"canPrevious": (sendToApp && (!commands || [commands containsObject:@5])) ? @YES : @NO,
        @"canNext": (sendToApp && (!commands || [commands containsObject:@4])) ? @YES : @NO,
        @"canSeek": (seekBasic != NULL) ? @YES : @NO
    };
}

static void publish(int pid, BOOL playing, NSDictionary *info, NSSet<NSNumber *> *commands) {
    NSRunningApplication *app = pid > 0 ? [NSRunningApplication runningApplicationWithProcessIdentifier:pid] : nil;
    // Exclude dedicated integrations before publishing any metadata.
    if (!eligibleBundle(app.bundleIdentifier)) {
        NSDictionary *idle = @{@"type":@"snapshot", @"active":@NO};
        if (![idle isEqual:previous]) {
            previous = idle;
            emit(idle);
        }
        lastArtwork = nil; lastIdentity = nil;
        return;
    }
    NSString *title = text(info[@"kMRMediaRemoteNowPlayingInfoTitle"]);
    NSString *artist = text(info[@"kMRMediaRemoteNowPlayingInfoArtist"]);
    NSString *identity = [NSString stringWithFormat:@"%d|%@|%@|%@|%@", pid,
        text(info[@"kMRMediaRemoteNowPlayingInfoContentItemIdentifier"]), title, artist,
        text(info[@"kMRMediaRemoteNowPlayingInfoAlbum"])];
    BOOL changed = ![identity isEqualToString:lastIdentity];
    if (changed) {
        lastArtwork = nil;
        lastIdentity = identity;
    }
    id rawArtwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
    BOOL artworkChanged = NO;
    if ([rawArtwork isKindOfClass:NSData.class] && [rawArtwork length] <= 4 * 1024 * 1024 &&
        ![rawArtwork isEqual:lastArtwork]) {
        lastArtwork = rawArtwork;
        artworkChanged = YES;
    }
    if (changed || artworkChanged) artworkRevision++;
    double elapsed = fmin(604800, fmax(0, finiteNumber(info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"], 0)));
    double duration = fmin(604800, fmax(0, finiteNumber(info[@"kMRMediaRemoteNowPlayingInfoDuration"], 0)));
    double rate = playing ? fmin(16, fmax(0, finiteNumber(info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"], 1))) : 0;
    id timestamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    double anchoredAt = [timestamp isKindOfClass:NSDate.class] ? [timestamp timeIntervalSince1970] : now;
    if (!isfinite(anchoredAt) || anchoredAt > now + 5 || anchoredAt < 0) anchoredAt = now;
    NSMutableDictionary *snapshot = [@{@"type":@"snapshot", @"active":@YES,
        @"pid":@(pid), @"source":text(app.localizedName ?: app.bundleIdentifier),
        @"bundleIdentifier":app.bundleIdentifier, @"title":title, @"artist":artist,
        @"duration":@(duration), @"position":@(elapsed), @"timestamp":@(anchoredAt),
        @"rate":@(rate), @"playing":@(playing), @"identity":identity,
        @"artworkRevision":@(artworkRevision)} mutableCopy];
    [snapshot addEntriesFromDictionary:capabilitySnapshot(commands)];
    // Reconstruct a complete logical snapshot, but send artwork bytes only on change.
    if (![snapshot isEqual:previous]) {
        previous = [snapshot copy];
        if (changed || artworkChanged) snapshot[@"artwork"] = lastArtwork ? [lastArtwork base64EncodedStringWithOptions:0] : NSNull.null;
        emit(snapshot);
    }
}

static void refresh(void);
static void finishRead(int pid, BOOL playing, NSDictionary *info, NSSet<NSNumber *> *commands) {
    publish(pid, playing, info ?: @{}, commands);
    fetching = NO;
    if (rerun) {
        rerun = NO;
        refresh();
    }
}

static void refresh(void) {
    if (fetching) {
        rerun = YES;
        return;
    }
    fetching = YES;
    NSUInteger token = ++readGeneration;
    // A single deadline per outstanding read, not a recurring polling timer.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), work, ^{
        if (fetching && token == readGeneration) stopWithError(@"Ahora suena dejó de responder. Receptor cerrado.");
    });
    // Read application identity first. Avoid retrieving another player's metadata.
    readPID(work, ^(int pid) {
        NSRunningApplication *app = pid > 0 ? [NSRunningApplication runningApplicationWithProcessIdentifier:pid] : nil;
        if (!eligibleBundle(app.bundleIdentifier)) {
            finishRead(pid, NO, @{}, nil); return;
        }
        dispatch_group_t group = dispatch_group_create();
        __block NSDictionary *info;
        __block BOOL playing;
        __block NSSet<NSNumber *> *commands;
        dispatch_group_enter(group);
        readInfo(work, ^(NSDictionary *value) { info = value; dispatch_group_leave(group); });
        dispatch_group_enter(group);
        readPlaying(work, ^(BOOL value) { playing = value; dispatch_group_leave(group); });
        dispatch_group_enter(group);
        supportedCommands(^(NSSet<NSNumber *> *value) { commands = value; dispatch_group_leave(group); });
        dispatch_group_notify(group, work, ^{
            // Recheck identity before combining independently delivered callbacks.
            readPID(work, ^(int current) {
                if (current != pid) {
                    fetching = NO;
                    refresh();
                    return;
                }
                finishRead(pid, playing, info, commands);
            });
        });
    });
}

static void scheduleRefresh(void) {
    if (pending) return;
    pending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), work, ^{
        pending = NO; refresh();
    });
}

static void command(NSData *line) {
    id parsed = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
    if (![parsed isKindOfClass:NSDictionary.class]) return;
    NSDictionary *message = parsed;
    NSString *name = text(message[@"command"]);
    NSString *requestID = text(message[@"requestID"]);
    NSString *expectedBundle = text(message[@"bundleIdentifier"]);
    if (!eligibleBundle(expectedBundle)) return;
    if (requestID.length > 64) return;
    double requestedPID = finiteNumber(message[@"pid"], 0);
    if (requestedPID <= 0 || requestedPID > INT_MAX || floor(requestedPID) != requestedPID) return;
    int expected = (int)requestedPID;
    NSNumber *code = @{@"play":@0, @"pause":@1, @"next":@4, @"previous":@5, @"seek":@24}[name];
    if (!code) return;
    double seconds = finiteNumber(message[@"seconds"], -1);
    if ([name isEqualToString:@"seek"] && !(seconds >= 0 && seconds <= 604800)) return;
    void (^reply)(BOOL, NSString *) = ^(BOOL accepted, NSString *reason) {
        emit(@{@"type":@"command", @"requestID":requestID, @"accepted":@(accepted), @"message":reason});
    };
    readPID(work, ^(int pid) {
        NSRunningApplication *app = pid > 0 ? [NSRunningApplication runningApplicationWithProcessIdentifier:pid] : nil;
        if (pid != expected || !eligibleBundle(app.bundleIdentifier) ||
            ![app.bundleIdentifier isEqualToString:expectedBundle]) {
            reply(NO, @"El reproductor activo cambió."); return;
        }
        // Preserve the already verified Play/Pause/seek path. Capability replies
        // can omit Play while paused, so must not veto these basic commands.
        if (code.unsignedIntValue != 4 && code.unsignedIntValue != 5) {
            BOOL accepted = NO;
            if ([name isEqualToString:@"seek"] && seekBasic) {
                seekBasic(seconds);
                accepted = YES;
            }
            else if (![name isEqualToString:@"seek"] && sendBasic) accepted = sendBasic(code.unsignedIntValue, nil);
            reply(accepted, accepted ? @"Orden enviada al reproductor activo." : @"No se pudo enviar la orden.");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), work, ^{ refresh(); });
            return;
        }
        if (!sendToApp) {
            reply(NO, @"No está disponible el control directo del reproductor.");
            return;
        }
        supportedCommands(^(NSSet<NSNumber *> *commands) {
            if (commands && ![commands containsObject:code]) {
                reply(NO, [name isEqualToString:@"previous"] ? @"El reproductor no ofrece Anterior para este contenido."
                    : [name isEqualToString:@"next"] ? @"El reproductor no ofrece Siguiente para este contenido."
                    : @"El reproductor no ofrece este control ahora.");
                scheduleRefresh(); return;
            }
            // Recheck after the asynchronous lookup and direct navigation to this player.
            readPID(work, ^(int current) {
                NSRunningApplication *currentApp = [NSRunningApplication runningApplicationWithProcessIdentifier:current];
                if (current != expected || !eligibleBundle(currentApp.bundleIdentifier) ||
                    ![currentApp.bundleIdentifier isEqualToString:expectedBundle]) {
                    reply(NO, @"El reproductor activo cambió.");
                    return;
                }
                NSDictionary *options = nil;
                __block BOOL completed = NO;
                Boolean queued = sendToApp(code.unsignedIntValue, (__bridge CFDictionaryRef)options,
                    localOrigin ? localOrigin() : NULL, (__bridge CFStringRef)expectedBundle, 0, work,
                    ^(uint32_t error, CFArrayRef rawStatuses) {
                        if (completed) return;
                        completed = YES;
                        BOOL failed = error != 0;
                        BOOL success = NO;
                        if (rawStatuses && CFGetTypeID(rawStatuses) == CFArrayGetTypeID()) {
                            for (id status in (__bridge NSArray *)rawStatuses) {
                                if (![status isKindOfClass:NSNumber.class]) continue;
                                if ([status unsignedIntValue] == 0) success = YES;
                                else failed = YES;
                            }
                        }
                        BOOL accepted = error == 0 && (!failed || success);
                        reply(accepted, accepted ? @"Orden enviada al reproductor; esperando el cambio."
                                                : @"El reproductor rechazó la orden o no puede ejecutarla ahora.");
                        // Single confirmation read after an explicit user action, never polling.
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), work, ^{ refresh(); });
                    });
                if (!queued && !completed) {
                    completed = YES;
                    reply(NO, @"macOS no pudo enviar la orden al reproductor.");
                }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), work, ^{
                    if (!completed) {
                        completed = YES;
                        reply(NO, @"El reproductor no respondió a la orden.");
                    }
                });
            });
        });
    });
}
__attribute__((visibility("default"))) void coucou_listen(void) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);
        work = dispatch_queue_create("local.coucou.media-lab.bridge",
            dispatch_queue_attr_make_with_autorelease_frequency(DISPATCH_QUEUE_SERIAL, DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM));
        void *library = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LOCAL | RTLD_LAZY);
        if (!library) stopWithError(@"MediaRemote no está disponible.");
        readInfo = dlsym(library, "MRMediaRemoteGetNowPlayingInfo");
        readPID = dlsym(library, "MRMediaRemoteGetNowPlayingApplicationPID");
        readPlaying = dlsym(library, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
        subscribe = dlsym(library, "MRMediaRemoteRegisterForNowPlayingNotifications");
        unsubscribe = dlsym(library, "MRMediaRemoteUnregisterForNowPlayingNotifications");
        sendBasic = dlsym(library, "MRMediaRemoteSendCommand");
        seekBasic = dlsym(library, "MRMediaRemoteSetElapsedTime");
        localOrigin = dlsym(library, "MRMediaRemoteGetLocalOrigin");
        readSupported = dlsym(library, "MRMediaRemoteGetSupportedCommandsForOrigin");
        sendToApp = dlsym(library, "MRMediaRemoteSendCommandToApp");
        if (!readInfo || !readPID || !readPlaying || !subscribe || !unsubscribe)
            stopWithError(@"Esta versión de macOS no ofrece las funciones requeridas.");
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        for (NSString *name in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
             @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
             @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification"]) {
            [center addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
                dispatch_async(work, ^{ scheduleRefresh(); });
            }];
        }
        CFStringRef *capabilityNotification = dlsym(library, "kMRMediaRemoteSupportedCommandsDidChangeNotification");
        if (capabilityNotification && *capabilityNotification) {
            [center addObserverForName:(__bridge NSString *)*capabilityNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
                dispatch_async(work, ^{ scheduleRefresh(); });
            }];
        }
        input = NSMutableData.data;
        fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL) | O_NONBLOCK);
        stdinSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, work);
        dispatch_source_set_event_handler(stdinSource, ^{
            uint8_t buffer[4096];
            ssize_t count;
            while ((count = read(STDIN_FILENO, buffer, sizeof buffer)) > 0) {
                [input appendBytes:buffer length:(NSUInteger)count];
                if (input.length > 16 * 1024) _exit(2);
            }
            if (count == 0) {
                unsubscribe();
                _exit(0);
            }
            const uint8_t *bytes = input.bytes;
            NSUInteger consumed = 0;
            for (NSUInteger i = 0; i < input.length; i++) {
                if (bytes[i] == '\n') {
                    command([input subdataWithRange:NSMakeRange(consumed, i - consumed)]);
                    consumed = i + 1;
                }
            }
            if (consumed) [input replaceBytesInRange:NSMakeRange(0, consumed) withBytes:NULL length:0];
        });
        dispatch_resume(stdinSource);
        subscribe(work);
        emit(@{@"type":@"ready"});
        dispatch_async(work, ^{ refresh(); });
        CFRunLoopRun();
        unsubscribe();
        exit(0);
    }
}
