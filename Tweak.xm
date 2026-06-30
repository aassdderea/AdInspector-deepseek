#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach/mach_time.h>

typedef struct __IOHIDEvent *IOHIDEventRef;

static NSMutableString *s_log = nil;
static void logMsg(NSString *m) {
    if (!s_log) s_log = [NSMutableString string];
    [s_log appendFormat:@"%@\n", m];
}

IOHIDEventRef (*IOHIDEventCreateDigitizerFingerEventPtr)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, Boolean, Boolean, double, double, double, double, double, double) = NULL;
void *(*IOHIDEventSystemClientCreatePtr)(CFAllocatorRef) = NULL;
void (*IOHIDEventSystemClientDispatchEventPtr)(void *, IOHIDEventRef) = NULL;
void *GSSendEventPtr = NULL;
void *GSEventCreateWithEventRecordPtr = NULL;
void *GSEventSetTypePtr = NULL;

@interface TestWindow : UIWindow
@property (nonatomic, weak) UIView *panel;
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

- (void)doTap {
    UIView *panel = self.panel;
    UITextField *xf = (UITextField *)[panel viewWithTag:10];
    UITextField *yf = (UITextField *)[panel viewWithTag:11];
    CGFloat x = [xf.text floatValue], y = [yf.text floatValue];
    CGFloat scale = [UIScreen mainScreen].scale;
    double px = x * scale, py = y * scale;
    logMsg([NSString stringWithFormat:@"\n🖐 测试坐标 (%.0f, %.0f)", x, y]);
    
    // IOKit
    if (IOHIDEventCreateDigitizerFingerEventPtr && IOHIDEventSystemClientCreatePtr && IOHIDEventSystemClientDispatchEventPtr) {
        @try {
            uint64_t ts = mach_absolute_time();
            IOHIDEventRef down = IOHIDEventCreateDigitizerFingerEventPtr(kCFAllocatorDefault, ts, 0, 2, 0x01, NO, YES, px, py, 0, 1.0, 0, 0);
            if (down) { void *c = IOHIDEventSystemClientCreatePtr(kCFAllocatorDefault); if (c) { IOHIDEventSystemClientDispatchEventPtr(c, down); CFRelease(c); } CFRelease(down); }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                IOHIDEventRef up = IOHIDEventCreateDigitizerFingerEventPtr(kCFAllocatorDefault, mach_absolute_time(), 0, 2, 0x01, NO, NO, px, py, 0, 1.0, 0, 0);
                if (up) { void *c = IOHIDEventSystemClientCreatePtr(kCFAllocatorDefault); if (c) { IOHIDEventSystemClientDispatchEventPtr(c, up); CFRelease(c); } CFRelease(up); logMsg(@"IOKit ✅"); }
            });
        } @catch (NSException *e) { logMsg([NSString stringWithFormat:@"IOKit异常: %@", e.reason]); }
    }
    
    // GSSendEvent: 尝试不同大小的 GSEventRecord
    if (GSSendEventPtr && GSEventCreateWithEventRecordPtr) {
        @try {
            int sizes[] = {72, 80, 88, 96, 104, 112, 120, 128, 136, 144, 152, 160};
            BOOL found = NO;
            for (int i = 0; i < 12 && !found; i++) {
                void *buf = calloc(1, sizes[i]);
                *(int *)buf = 3001;                          // type
                *((int *)buf + 1) = 1;                       // subtype (began)
                *((uint64_t *)(buf + 8)) = mach_absolute_time(); // timestamp
                *((CGFloat *)(buf + 24)) = x;                // location.x
                *((CGFloat *)(buf + 32)) = y;                // location.y
                if (sizes[i] >= 56) {
                    *((CGFloat *)(buf + 40)) = 1.0;          // pressure
                    *((int *)(buf + 52)) = 1;                // tapCount
                }
                void *gs = ((void *(*)(void *))GSEventCreateWithEventRecordPtr)(buf);
                if (gs) {
                    ((void (*)(void *))GSSendEventPtr)(gs);
                    logMsg([NSString stringWithFormat:@"GSSendEvent(%d字节) ✅", sizes[i]]);
                    found = YES;
                }
                free(buf);
            }
            if (!found) logMsg(@"GSSendEvent 所有大小都失败 ❌");
        } @catch (NSException *e) { logMsg([NSString stringWithFormat:@"GSEvent异常: %@", e.reason]); }
    }
    
    UIView *circle = [[UIView alloc] initWithFrame:CGRectMake(x - 15, y - 15, 30, 30)];
    circle.backgroundColor = [UIColor clearColor]; circle.layer.cornerRadius = 15; circle.layer.borderWidth = 2;
    circle.layer.borderColor = [UIColor redColor].CGColor; circle.layer.zPosition = CGFLOAT_MAX; circle.userInteractionEnabled = NO;
    [self addSubview:circle];
    [UIView animateWithDuration:0.5 delay:0.3 options:UIViewAnimationOptionCurveEaseOut animations:^{ circle.alpha = 0; circle.transform = CGAffineTransformMakeScale(2, 2); } completion:^(BOOL f) { [circle removeFromSuperview]; }];
    [xf resignFirstResponder]; [yf resignFirstResponder];
}
- (void)doCopy { [[UIPasteboard generalPasteboard] setString:s_log]; logMsg(@"📋 日志已复制"); }
- (void)doClear { [s_log setString:@""]; }
@end

%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindowScene *as = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]] && s.activationState == UISceneActivationStateForegroundActive) { as = (UIWindowScene *)s; break; }
        }
        if (as) { s_window = [[TestWindow alloc] initWithFrame:as.coordinateSpace.bounds]; s_window.windowScene = as; }
        s_log = [NSMutableString string];
        
        IOHIDEventCreateDigitizerFingerEventPtr = (IOHIDEventRef (*)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, Boolean, Boolean, double, double, double, double, double, double))dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerFingerEvent");
        IOHIDEventSystemClientCreatePtr = (void *(*)(CFAllocatorRef))dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreate");
        IOHIDEventSystemClientDispatchEventPtr = (void (*)(void *, IOHIDEventRef))dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientDispatchEvent");
        GSSendEventPtr = dlsym(RTLD_DEFAULT, "GSSendEvent");
        GSEventCreateWithEventRecordPtr = dlsym(RTLD_DEFAULT, "GSEventCreateWithEventRecord");
        GSEventSetTypePtr = dlsym(RTLD_DEFAULT, "GSEventSetType");
        
        logMsg(@"=== 符号状态 ===");
        logMsg([NSString stringWithFormat:@"IOKit: %@", IOHIDEventCreateDigitizerFingerEventPtr ? @"✅" : @"❌"]);
        logMsg([NSString stringWithFormat:@"GSSendEvent: %@", GSSendEventPtr ? @"✅" : @"❌"]);
        logMsg([NSString stringWithFormat:@"GSEventCreateWithEventRecord: %@", GSEventCreateWithEventRecordPtr ? @"✅" : @"❌"]);
        logMsg([NSString stringWithFormat:@"GSEventSetType: %@", GSEventSetTypePtr ? @"✅" : @"❌"]);
        
        CGFloat pw = [UIScreen mainScreen].bounds.size.width - 20;
        CGFloat ph = 250;
        UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(10, 120, pw, ph)];
        panel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85]; panel.layer.cornerRadius = 10; panel.layer.borderWidth = 1; panel.layer.borderColor = [UIColor greenColor].CGColor;
        UITextField *xf = [[UITextField alloc] initWithFrame:CGRectMake(12, 8, 80, 30)]; xf.borderStyle = UITextBorderStyleRoundedRect; xf.backgroundColor = [UIColor darkGrayColor]; xf.textColor = [UIColor whiteColor]; xf.text = @"100"; xf.tag = 10; [panel addSubview:xf];
        UITextField *yf = [[UITextField alloc] initWithFrame:CGRectMake(100, 8, 80, 30)]; yf.borderStyle = UITextBorderStyleRoundedRect; yf.backgroundColor = [UIColor darkGrayColor]; yf.textColor = [UIColor whiteColor]; yf.text = @"200"; yf.tag = 11; [panel addSubview:yf];
        UIButton *tb = [UIButton buttonWithType:UIButtonTypeSystem]; tb.frame = CGRectMake(190, 8, 60, 30); [tb setTitle:@"点击" forState:UIControlStateNormal]; [tb setTitleColor:[UIColor greenColor] forState:UIControlStateNormal]; [tb addTarget:s_window action:@selector(doTap) forControlEvents:UIControlEventTouchUpInside]; [panel addSubview:tb];
        UIButton *cb = [UIButton buttonWithType:UIButtonTypeSystem]; cb.frame = CGRectMake(260, 8, 60, 30); [cb setTitle:@"复制" forState:UIControlStateNormal]; [cb setTitleColor:[UIColor cyanColor] forState:UIControlStateNormal]; [cb addTarget:s_window action:@selector(doCopy) forControlEvents:UIControlEventTouchUpInside]; [panel addSubview:cb];
        UIButton *clb = [UIButton buttonWithType:UIButtonTypeSystem]; clb.frame = CGRectMake(320, 8, 50, 30); [clb setTitle:@"清屏" forState:UIControlStateNormal]; [clb setTitleColor:[UIColor grayColor] forState:UIControlStateNormal]; [clb addTarget:s_window action:@selector(doClear) forControlEvents:UIControlEventTouchUpInside]; [panel addSubview:clb];
        UITextView *lv = [[UITextView alloc] initWithFrame:CGRectMake(5, 44, pw - 10, ph - 50)]; lv.backgroundColor = [UIColor clearColor]; lv.textColor = [UIColor greenColor]; lv.font = [UIFont systemFontOfSize:10]; lv.editable = NO; lv.tag = 20; [panel addSubview:lv];
        s_window.panel = panel; [s_window addSubview:panel];
        [NSTimer scheduledTimerWithTimeInterval:0.3 repeats:YES block:^(NSTimer *t) { UITextView *v = (UITextView *)[panel viewWithTag:20]; if (v && ![v.text isEqualToString:s_log]) { v.text = s_log; [v scrollRangeToVisible:NSMakeRange(s_log.length - 1, 1)]; } }];
    });
}
