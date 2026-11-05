#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and returns NO when it raised an Objective-C exception. Swift cannot catch one: AVAudioEngine reports a
/// format it dislikes that way, and the process would end. Nothing else is done with the exception.
BOOL CoucouTry(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
