#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>

static NSMutableString *s_log = nil;
static void logMsg(NSString *m) {
    if (!s_log) s_log = [NSMutableString string];
    [s_log appendFormat:@"%@\n", m];
}

%hook UIApplication
- (void)sendEvent:(UIEvent *)e {
    %orig;
    @try {
        if (e.type == UIEventTypeTouches) {
            UITouch *t = [[e allTouches] anyObject];
            if (t.phase == UITouchPhaseEnded) {
                CGPoint loc = [t locationInView:nil];
                logMsg([NSString stringWithFormat:@"📐 触摸坐标: (%.0f, %.0f)", loc.x, loc.y]);
                
                id gs = nil;
                @try { gs = [e valueForKey:@"_gsEvent"]; } @catch (NSException *ex) {}
                if (gs) {
                    logMsg([NSString stringWithFormat:@"✅ _gsEvent 存在: %@", NSStringFromClass([gs class])]);
                    @try {
                        NSData *d = [NSData dataWithBytes:(__bridge const void *)gs length:128];
                        const uint8_t *b = (const uint8_t *)d.bytes;
                        NSMutableString *h = [NSMutableString string];
                        for (int i = 0; i < 128; i++) {
                            [h appendFormat:@"%02X ", b[i]];
                            if ((i + 1) % 16 == 0) [h appendString:@"\n"];
                        }
                        logMsg([NSString stringWithFormat:@"📐 _gsEvent 128字节:\n%@", h]);
                    } @catch (NSException *e2) {}
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
        
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(10, 100, [UIScreen mainScreen].bounds.size.width - 20, 200)];
        label.text = @"用手触摸App按钮，看日志";
        label.textColor = [UIColor greenColor];
        label.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.9];
        label.font = [UIFont systemFontOfSize:13];
        label.numberOfLines = 0;
        label.layer.cornerRadius = 8;
        label.clipsToBounds = YES;
        label.userInteractionEnabled = NO;
        
        UIWindow *w = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        w.windowLevel = UIWindowLevelAlert + 1;
        w.backgroundColor = [UIColor clearColor];
        w.hidden = NO;
        [w addSubview:label];
        
        [NSTimer scheduledTimerWithTimeInterval:0.3 repeats:YES block:^(NSTimer *t) {
            label.text = s_log;
        }];
    });
}
