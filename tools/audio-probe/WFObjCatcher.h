// WFObjCatcher.h — public header (see include/ note in Package.swift).
#import <Foundation/Foundation.h>

/// Run a throwaway AVAudioEngine prepare/start/stop cycle, catching the
/// ObjC NSException that AVAudioEngine raises when another process holds
/// the audio input. Swift cannot catch NSException, so it lives here.
/// Returns YES if the engine ran, NO if input was unavailable/held.
BOOL WFTryPrepareAudioEngine(NSTimeInterval runSeconds);
