#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs [block] and turns an Objective-C exception it raises into an error.
///
/// AVAudioEngine reports misuse by raising NSException, which Swift cannot
/// catch and which ends the app. Returns NO with [error] set when [block]
/// raised.
BOOL ConduitObjCTry(NS_NOESCAPE void (^block)(void), NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
