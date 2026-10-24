#import "ConduitObjCTry.h"

BOOL ConduitObjCTry(NS_NOESCAPE void (^block)(void), NSError **error) {
  @try {
    block();
    return YES;
  } @catch (NSException *exception) {
    if (error) {
      *error = [NSError errorWithDomain:exception.name
                                   code:-1
                               userInfo:@{
                                 NSLocalizedDescriptionKey : exception.reason ?: exception.name
                               }];
    }
    return NO;
  }
}
