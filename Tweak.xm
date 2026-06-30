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
    if (e.type == UIEventTypeTouches) {
        NSSet *touches = [e allTouches];
        UITouch *t = [touches anyObject];
        if (t.phase == UITouchPhaseEnded) {
            // dump UIEvent 的内存
            uint8_t *bytes = (__bridge uint8_t *)e;
            NSMutableString *hex = [NSMutableString string];
            for (int i = 0; i < 256; i++) {
                [hex appendFormat:@"%02X ", bytes[i]];
                if ((i + 1) % 16 == 0) [hex appendString:@"\n"];
            }
            logMsg([NSString stringWithFormat:@"📐 UIEvent 前256字节:\n%@", hex]);
            
            // 同时尝试读取 _gsEvent 或 _hidEvent
            id gs = [e valueForKey:@"_gsEvent"];
            if (gs) {
                uint8_t *b = (__bridge uint8_t *)gs;
                NSMutableString *h = [NSMutableString string];
                for (int i = 0; i < 128; i++) {
                    [h appendFormat:@"%02X ", b[i]];
                    if ((i + 1) % 16 == 0) [h appendString:@"\n"];
                }
                logMsg([NSString stringWithFormat:@"📐 _gsEvent 128字节:\n%@", h]);
            }
        }
    }
}
%end

%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        s_log = [NSMutableString string];
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(10, 100, [UIScreen mainScreen].bounds.size.width - 20, 600)];
        label.text = @"用手触摸屏幕";
        label.textColor = [UIColor greenColor];
        label.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.9];
        label.font = [UIFont systemFontOfSize:9];
        label.numberOfLines = 0;
        UIWindow *w = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        w.windowLevel = CGFLOAT_MAX; w.backgroundColor = [UIColor clearColor]; w.hidden = NO;
        [w addSubview:label];
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) { label.text = s_log; }];
    });
}
