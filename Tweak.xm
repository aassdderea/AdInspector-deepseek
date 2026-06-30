#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static void showToast(NSString *m) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *kw = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]] && s.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *w in [(UIWindowScene *)s windows]) { if (w.isKeyWindow) { kw = w; break; } }
            }
        }
        if (!kw) return;
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(10, 100, kw.bounds.size.width - 20, 80)];
        l.text = m; l.textColor = [UIColor whiteColor]; l.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.9];
        l.font = [UIFont boldSystemFontOfSize:16]; l.numberOfLines = 3; l.textAlignment = NSTextAlignmentCenter;
        l.layer.cornerRadius = 8; l.clipsToBounds = YES;
        [kw addSubview:l];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [l removeFromSuperview]; });
    });
}

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
                    showToast([NSString stringWithFormat:@"✅ _gsEvent: %@", NSStringFromClass([gs class])]);
                } else {
                    showToast(@"❌ _gsEvent 不存在");
                }
            }
        }
    } @catch (NSException *ex) {}
}
%end
