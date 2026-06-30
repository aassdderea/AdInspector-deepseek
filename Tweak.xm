#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <AudioToolbox/AudioToolbox.h>

%hook UIApplication
- (void)sendEvent:(UIEvent *)e {
    %orig;
    @try {
        if (e.type == UIEventTypeTouches) {
            UITouch *t = [[e allTouches] anyObject];
            if (t.phase == UITouchPhaseEnded) {
                id gs = nil;
                @try { gs = [e valueForKey:@"_gsEvent"]; } @catch (NSException *ex) {}
                if (gs) {
                    NSData *d = [NSData dataWithBytes:(__bridge const void *)gs length:128];
                    [d writeToFile:@"/var/mobile/Documents/gsEvent.bin" atomically:YES];
                    AudioServicesPlaySystemSound(1519);
                }
            }
        }
    } @catch (NSException *ex) {}
}
%end
