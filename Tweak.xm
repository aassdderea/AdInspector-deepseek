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
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(20, kw.bounds.size.height - 200, kw.bounds.size.width - 40, 160)];
        l.text = m; l.textColor = [UIColor whiteColor]; l.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.9];
        l.font = [UIFont systemFontOfSize:10]; l.numberOfLines = 0; l.layer.cornerRadius = 8; l.clipsToBounds = YES;
        [kw addSubview:l];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [l removeFromSuperview]; });
    });
}

%hook UIApplication
- (void)sendEvent:(UIEvent *)e {
    %orig;
    @try {
        if (e.type == UIEventTypeTouches) {
            UITouch *t = [[e allTouches] anyObject];
            if (t.phase == UITouchPhaseEnded) {
                NSMutableString *log = [NSMutableString string];
                [log appendFormat:@"触摸坐标: (%.0f,%.0f)\n", [t locationInView:nil].x, [t locationInView:nil].y];
                
                // 尝试所有可能的 key
                NSArray *keys = @[@"_gsEvent", @"_hidEvent", @"_event", @"_touchesEvent", @"_iohidEvent", @"_backboardEvent", @"_touchData", @"_touchEvent", @"_gsevent"];
                BOOL found = NO;
                for (NSString *k in keys) {
                    @try {
                        id v = [e valueForKey:k];
                        if (v) {
                            NSData *d = [NSData dataWithBytes:(__bridge const void *)v length:256];
                            NSString *path = [NSString stringWithFormat:@"/var/mobile/Documents/%@.bin", k];
                            [d writeToFile:path atomically:YES];
                            [log appendFormat:@"✅ %@ → %@\n", k, path];
                            found = YES;
                        }
                    } @catch (NSException *ex) {
                        [log appendFormat:@"❌ %@ 崩溃: %@\n", k, ex.reason];
                    }
                }
                
                // 如果都不存在，dump UIEvent 本身的 ivar
                if (!found) {
                    unsigned int count;
                    Ivar *ivars = class_copyIvarList([e class], &count);
                    for (unsigned int i = 0; i < count; i++) {
                        @try {
                            id v = object_getIvar(e, ivars[i]);
                            if (v) {
                                [log appendFormat:@"  ivar: %s = %@\n", ivar_getName(ivars[i]), NSStringFromClass([v class])];
                            }
                        } @catch (NSException *ex) {}
                    }
                    free(ivars);
                    
                    // 直接 dump UIEvent 内存
                    NSData *d = [NSData dataWithBytes:(__bridge const void *)e length:256];
                    [d writeToFile:@"/var/mobile/Documents/UIEvent.bin" atomically:YES];
                    [log appendString:@"UIEvent 内存 → UIEvent.bin\n"];
                }
                
                showToast(log);
            }
        }
    } @catch (NSException *ex) {}
}
%end
