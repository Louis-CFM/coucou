// Exercises the real parser/deadline with synthetic command descriptors; no playback commands.
#import "../Native/NowPlayingBridge.m"

@interface TestCommand : NSObject
@property uint32_t command;
@property(getter=isEnabled) BOOL enabled;
@end
@implementation TestCommand
@end

static CFTypeRef testPayload;
static BOOL neverReply;
static void fakeCapabilities(void *origin, dispatch_queue_t queue, void (^reply)(CFArrayRef)) {
    if (!neverReply) reply((CFArrayRef)testPayload);
}
static void *fakeOrigin(void) { return NULL; }
static void check(CFTypeRef payload, BOOL noReply, NSSet *expected) {
    dispatch_group_t completed = dispatch_group_create();
    dispatch_group_enter(completed);
    dispatch_async(work, ^{
        testPayload = payload; neverReply = noReply;
        supportedCommands(^(NSSet *value) {
            NSCAssert(expected ? [value isEqual:expected] : value == nil, @"Invalid capabilities result");
            dispatch_group_leave(completed);
        });
    });
    NSCAssert(dispatch_group_wait(completed, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) == 0, @"Capability lookup hung");
}
int main(void) {
    @autoreleasepool {
        void *system = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LOCAL | RTLD_LAZY);
        NSCAssert(system && dlsym(system, "MRMediaRemoteGetSupportedCommandsForOrigin") &&
                  dlsym(system, "MRMediaRemoteSendCommandToApp") &&
                  dlsym(system, "MRMediaRemoteGetLocalOrigin"), @"Required controls API missing on test Mac");
        NSCAssert(!eligibleBundle(nil) && !eligibleBundle(@"") &&
                  !eligibleBundle(@"com.apple.Music") && !eligibleBundle(@"com.spotify.client"), @"Excluded source accepted");
        NSCAssert(eligibleBundle(@"com.google.Chrome") && eligibleBundle(@"com.apple.Safari") &&
                  eligibleBundle(@"org.mozilla.firefox"), @"Compatible source rejected");
        work = dispatch_queue_create("local.coucou.tests.capabilities", DISPATCH_QUEUE_SERIAL);
        localOrigin = fakeOrigin; readSupported = fakeCapabilities;
        TestCommand *next = TestCommand.new; next.command = 4; next.enabled = YES;
        TestCommand *previous = TestCommand.new; previous.command = 5; previous.enabled = NO;
        NSArray *values = @[next, previous];
        check((__bridge CFTypeRef)values, NO, [NSSet setWithObject:@4]);
        check((__bridge CFTypeRef)@[], NO, nil);
        check((__bridge CFTypeRef)@[@"unexpected object"], NO, nil);
        check((__bridge CFTypeRef)@"not an array", NO, nil);
        check(NULL, YES, nil);
        sendToApp = dlsym(system, "MRMediaRemoteSendCommandToApp");
        NSDictionary *wireCapabilities = capabilitySnapshot([NSSet setWithObjects:@4, @5, @24, nil]);
        NSData *json = [NSJSONSerialization dataWithJSONObject:wireCapabilities options:0 error:nil];
        NSDictionary *roundTrip = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
        for (id value in roundTrip.allValues) {
            NSCAssert(CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID(), @"Numeric flag breaks Swift Bool decoding");
        }
        puts("Capabilities passed: enabled/disabled, empty, malformed, timeout, JSON Boolean flags; system symbols present.");
    }
}
