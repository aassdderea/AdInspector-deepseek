#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>

static NSMutableString *s_log = nil;
static void logMsg(NSString *m) {
    if (!s_log) s_log = [NSMutableString string];
    [s_log appendFormat:@"%@\n", m];
}

@interface LogWindow : UIWindow
@end
@implementation LogWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self) return nil;
    return hit;
}
@end

%hook UIApplication
- (void)sendEvent:(UIEvent *)e {
    %orig;
    @try {
        if (e.type == UIEventTypeTouches) {
            UITouch *t = [[e allTouches] anyObject];
            if (t.phase == UITouchPhaseEnded) {
                CGPoint loc = [t locationInView:nil];
                logMsg([NSString stringWithFormat:@"📐 坐标: (%.0f, %.0f)", loc.x, loc.y]);
                id gs = nil;
                @try { gs = [e valueForKey:@"_gsEvent"]; } @catch (NSException *ex) {}
                if (gs) {
                    logMsg([NSString stringWithFormat:@"✅ _gsEvent: %@", NSStringFromClass([gs class])]);
                } else {
                    logMsg(@"❌ _gsEvent 不存在");
                }
            }
        }
    } @catch (NSException *ex) {}
}
%end

%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        s_log = [NSMutableString string];
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(10, 100, [UIScreen mainScreen].bounds.size.width - 20, 400)];
        label.text = @"用手触摸App按钮";
        label.textColor = [UIColor greenColor];
        label.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.9];
        label.font = [UIFont systemFontOfSize:11];
        label.numberOfLines = 0;
        LogWindow *w = [[LogWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        w.windowLevel = CGFLOAT_MAX;
        w.backgroundColor = [UIColor clearColor];
        w.hidden = NO;
        [w addSubview:label];
        [NSTimer scheduledTimerWithTimeInterval:0.3 repeats:YES block:^(NSTimer *t) { label.text = s_log; }];
    });
}
