#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach/mach_time.h>

static NSMutableString *s_log = nil;
static void logMsg(NSString *m) {
    if (!s_log) s_log = [NSMutableString string];
    [s_log appendFormat:@"%@\n", m];
}

@interface TestWindow : UIWindow
@end
static TestWindow *s_window = nil;

@implementation TestWindow
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) { self.windowLevel = CGFLOAT_MAX; self.backgroundColor = [UIColor clearColor]; self.hidden = NO; }
    return self;
}
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self) return nil;
    return hit;
}
@end

%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindowScene *as = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]] && s.activationState == UISceneActivationStateForegroundActive) { as = (UIWindowScene *)s; break; }
        }
        if (as) { s_window = [[TestWindow alloc] initWithFrame:as.coordinateSpace.bounds]; s_window.windowScene = as; }
        s_log = [NSMutableString string];
        
        void *BKS = dlsym(RTLD_DEFAULT, "BKSHIDEventSetDigitizerInfo");
        void *GSSend = dlsym(RTLD_DEFAULT, "GSSendEvent");
        void *GSCreate = dlsym(RTLD_DEFAULT, "GSEventCreateWithEventRecord");
        
        logMsg([NSString stringWithFormat:@"BKSHIDEventSetDigitizerInfo: %@", BKS ? @"✅" : @"❌"]);
        logMsg([NSString stringWithFormat:@"GSSendEvent: %@", GSSend ? @"✅" : @"❌"]);
        logMsg([NSString stringWithFormat:@"GSEventCreateWithEventRecord: %@", GSCreate ? @"✅" : @"❌"]);
        
        UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(30, 200, 300, 120)];
        panel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
        panel.layer.cornerRadius = 10; panel.layer.borderWidth = 1; panel.layer.borderColor = [UIColor greenColor].CGColor;
        
        UITextField *xf = [[UITextField alloc] initWithFrame:CGRectMake(12, 12, 80, 30)]; xf.text = @"100"; xf.borderStyle = UITextBorderStyleRoundedRect; xf.backgroundColor = [UIColor darkGrayColor]; xf.textColor = [UIColor whiteColor];
        [panel addSubview:xf];
        UITextField *yf = [[UITextField alloc] initWithFrame:CGRectMake(100, 12, 80, 30)]; yf.text = @"200"; yf.borderStyle = UITextBorderStyleRoundedRect; yf.backgroundColor = [UIColor darkGrayColor]; yf.textColor = [UIColor whiteColor];
        [panel addSubview:yf];
        
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem]; btn.frame = CGRectMake(190, 10, 100, 34);
        [btn setTitle:@"BKS+GSE" forState:UIControlStateNormal]; [btn setTitleColor:[UIColor greenColor] forState:UIControlStateNormal];
        [panel addSubview:btn];
        
        UILabel *status = [[UILabel alloc] initWithFrame:CGRectMake(12, 50, 280, 60)];
        status.textColor = [UIColor greenColor]; status.font = [UIFont systemFontOfSize:11]; status.numberOfLines = 3;
        [panel addSubview:status];
        
        [s_window addSubview:panel];
        
        [btn addAction:[UIAction actionWithHandler:^(UIAction *a) {
            CGFloat x = [xf.text floatValue], y = [yf.text floatValue];
            NSMutableString *result = [NSMutableString string];
            [result appendFormat:@"测试 (%.0f,%.0f)\n", x, y];
            
            if (BKS && GSCreate && GSSend) {
                @try {
                    // 尝试不同参数个数的 BKSHIDEventSetDigitizerInfo
                    // 尝试1: 5个参数
                    ((void (*)(int, float, float, float, float))BKS)(1, (float)x, (float)y, 0.0f, 1.0f);
                    [result appendString:@"BKS(5参数) ✅\n"];
                } @catch (NSException *e) {
                    [result appendFormat:@"BKS(5参数): %@\n", e.reason];
                    @try {
                        // 尝试2: 6个参数
                        ((void (*)(int, float, float, float, float, float))BKS)(1, (float)x, (float)y, 0.0f, 1.0f, 0.0f);
                        [result appendString:@"BKS(6参数) ✅\n"];
                    } @catch (NSException *e2) {
                        [result appendFormat:@"BKS(6参数): %@\n", e2.reason];
                    }
                }
                
                // GSSendEvent
                uint8_t *buf = (uint8_t *)calloc(1, 72);
                *(int *)buf = 3001; *((int *)buf + 1) = 1;
                *((uint64_t *)(buf + 8)) = mach_absolute_time();
                *((CGFloat *)(buf + 24)) = x; *((CGFloat *)(buf + 32)) = y;
                *((CGFloat *)(buf + 40)) = 1.0; *((int *)(buf + 52)) = 1;
                void *gs = ((void *(*)(void *))GSCreate)(buf);
                if (gs) { ((void (*)(void *))GSSend)(gs); [result appendString:@"GSSendEvent ✅\n"]; }
                else { [result appendString:@"GSCreate ❌\n"]; }
                free(buf);
            }
            
            status.text = result;
            logMsg(result);
            
            // 红圈
            UIView *c = [[UIView alloc] initWithFrame:CGRectMake(x-15, y-15, 30, 30)];
            c.backgroundColor = [UIColor clearColor]; c.layer.cornerRadius = 15; c.layer.borderWidth = 2;
            c.layer.borderColor = [UIColor redColor].CGColor; c.layer.zPosition = CGFLOAT_MAX; c.userInteractionEnabled = NO;
            [s_window addSubview:c];
            [UIView animateWithDuration:0.5 delay:0.3 options:UIViewAnimationOptionCurveEaseOut animations:^{ c.alpha = 0; c.transform = CGAffineTransformMakeScale(2, 2); } completion:^(BOOL f) { [c removeFromSuperview]; }];
            [xf resignFirstResponder]; [yf resignFirstResponder];
        }] forControlEvents:UIControlEventTouchUpInside];
    });
}
