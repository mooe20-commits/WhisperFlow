// WFObjCatcher.m — @try/@catch shim Swift cannot express.
#import "WFObjCatcher.h"
#import <AVFoundation/AVFoundation.h>

BOOL WFTryPrepareAudioEngine(NSTimeInterval runSeconds) {
  @try {
    AVAudioEngine *engine = [[AVAudioEngine alloc] init];
    [engine prepare];
    NSError *startError = nil;
    if (![engine startAndReturnError:&startError]) {
      return NO;
    }
    [NSThread sleepForTimeInterval:runSeconds];
    [engine stop];
    return YES;
  } @catch (NSException *exception) {
    return NO;
  }
}
