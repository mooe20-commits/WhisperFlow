// main.m — wf-audio-probe: exit 0 if a throwaway AVAudioEngine can
// prepare/start on the input (also warms BT route), exit 1 if held/busy.
// NSException (uncatchable in Swift) dies only in this child process.
#import "WFObjCatcher.h"

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    return WFTryPrepareAudioEngine(3.0) ? 0 : 1;
  }
}
