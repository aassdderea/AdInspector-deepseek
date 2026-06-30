#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach/mach_time.h>

typedef struct __IOHIDEvent *IOHIDEventRef;

@interface TestWindow : UIWindow
@property (nonatomic, weak) UIView *panel;
@end
static TestWindow *s_window = nil;
static NSMutableString *s_log = nil;

@implementation TestWindow
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) { self.windowLevel = CGFLOAT_MAX; self.backgroundColor = [UIColor clearColor]; self.hidden = NO; }
    return self;
}

- (void)doTap {
    UIView *panel = self.panel;
    UITextField *xf = (UITextField *)[panel viewWithTag:10];
    UITextField *yf = (UITextField *)[panel viewWithTag:11];
    CGFloat x = [xf.text floatValue];
    CGFloat y = [yf.text floatValue];
    CGFloat scale = [UIScreen mainScreen].scale;
    double px = x * scale, py = y * scale;
    
    logMsg([NSString stringWithFormat:@"\n🖐 测试坐标 (%.0f, %.0f)", x, y]);
    
    extern IOHIDEventRef (*IOHIDEventCreateDigitizerFingerEventPtr)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, Boolean, Boolean, double, double, double, double, double, double);
    extern void *(*IOHIDEventSystemClientCreatePtr)(CFAllocatorRef);
    extern void (*IOHIDEventSystemClientDispatchEventPtr)(void *, IOHIDEventRef);
    extern void *GSSendEventPtr;
    extern void *GSEventCreateWithEventRecordPtr;
    extern void *GSEventSetTypePtr;
    
    if (IOHIDEventCreateDigitizerFingerEventPtr && IOHIDEventSystemClientCreatePtr && IOHIDEventSystemClientDispatchEventPtr) {
        uint64_t ts = mach_absolute_time();
        IOHIDEventRef down = IOHIDEventCreateDigitizerFingerEventPtr(kCFAllocatorDefault, ts, 0, 2, 0x01, NO, YES, px, py, 0, 1.0, 0, 0);
        if (down) { void *c = IOHIDEventSystemClientCreatePtr(kCFAllocatorDefault); if (c) { IOHIDEventSystemClientDispatchEventPtr(c, down); CFRelease(c); } CFRelease(down); }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            IOHIDEventRef up = IOHIDEventCreateDigitizerFingerEventPtr(kCFAllocatorDefault, mach_absolute_time(), 0, 2, 0x01, NO, NO, px, py, 0, 1.0, 0, 0);
            if (up) { void *c = IOHIDEventSystemClientCreatePtr(kCFAllocatorDefault); if (c) { IOHIDEventSystemClientDispatchEventPtr(c, up); CFRelease(c); } CFRelease(up); logMsg(@"IOKit ✅"); }
        });
    }
    if (GSSendEventPtr && GSEventCreateWithEventRecordPtr && IOHIDEventCreateDigitizerFingerEventPtr) {
        IOHIDEventRef hid = IOHIDEventCreateDigitizerFingerEventPtr(kCFAllocatorDefault, mach_absolute_time(), 0, 2, 0x01, NO, YES, px, py, 0, 1.0, 0, 0);
        if (hid) {
            void *gs = ((void *(*)(void *))GSEventCreateWithEventRecordPtr)(NULL);
            if (gs) { ((void (*)(void *, int))GSEventSetTypePtr)(gs, 3001); ((void (*)(void *))GSSendEventPtr)(gs); logMsg(@"GSSendEvent ✅"); }
            else { logMsg(@"GSEventCreateWithEventRecord ❌"); }
            CFRelease(hid);
        }
    }
    Class AXUIElement = NSClassFromString(@"AXUIElement");
    if (AXUIElement) {
        @try {
            id elem = ((id (*)(id, SEL, void *))objc_msgSend)(AXUIElement, NSSelectorFromString(@"elementWithAXUIElementRef:"), NULL);
            if (elem) { ((void (*)(id, SEL, int))objc_msgSend)(elem, NSSelectorFromString(@"performAction:"), 1); logMsg(@"AXUIElement ✅"); }
            else { logMsg(@"AXUIElement ❌"); }
        } @catch (NSException *e) { logMsg([NSString stringWithFormat:@"AX: %@", e.reason]); }
    }
    UIView *circle = [[UIView alloc] initWithFrame:CGRectMake(x - 15, y - 15, 30, 30)];
    circle.backgroundColor = [UIColor clearColor]; circle.layer.cornerRadius = 15; circle.layer.borderWidth = 2;
    circle.layer.borderColor = [UIColor redColor].CGColor; circle.layer.zPosition = CGFLOAT_MAX; circle.userInteractionEnabled = NO;
    [self addSubview:circle];
    [UIView animateWithDuration:0.5 delay:0.3 options:UIViewAnimationOptionCurveEaseOut animations:^{ circle.alpha = 0; circle.transform = CGAffineTransformMakeScale(2, 2); } completion:^(BOOL f) { [circle removeFromSuperview]; }];
    [xf resignFirstResponder]; [yf resignFirstResponder];
}

- (void)doCopy {
    [[UIPasteboard generalPasteboard] setString:s_log];
    logMsg(@"📋 日志已复制");
}

- (void)doClear {
    [s_log setString:@""];
}
@end

static void logMsg(NSString *m) {
    [s_log appendFormat:@"%@\n", m];
}

IOHIDEventRef (*IOHIDEventCreateDigitizerFingerEventPtr)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, Boolean, Boolean, double, double, double, double, double, double) = NULL;
void *(*IOHIDEventSystemClientCreatePtr)(CFAllocatorRef) = NULL;
void (*IOHIDEventSystemClientDispatchEventPtr)(void *, IOHIDEventRef) = NULL;
void *GSSendEventPtr = NULL;
void *GSEventCreateWithEventRecordPtr = NULL;
void *GSEventSetTypePtr = NULL;

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
        
        UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(10, 80, [UIScreen mainScreen].bounds.size.width - 20, [UIScreen mainScreen].bounds.size.height - 100)];
        panel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
        panel.layer.cornerRadius = 10; panel.layer.borderWidth = 1; panel.layer.borderColor = [UIColor greenColor].CGColor;
        
        UITextField *xf = [[UITextField alloc] initWithFrame:CGRectMake(12, 8, 80, 30)];
        xf.borderStyle = UITextBorderStyleRoundedRect; xf.backgroundColor = [UIColor darkGrayColor]; xf.textColor = [UIColor whiteColor]; xf.text = @"100"; xf.tag = 10;
        [panel addSubview:xf];
        UITextField *yf = [[UITextField alloc] initWithFrame:CGRectMake(100, 8, 80, 30)];
        yf.borderStyle = UITextBorderStyleRoundedRect; yf.backgroundColor = [UIColor darkGrayColor]; yf.textColor = [UIColor whiteColor]; yf.text = @"200"; yf.tag = 11;
        [panel addSubview:yf];
        
        UIButton *tapBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        tapBtn.frame = CGRectMake(190, 8, 60, 30); [tapBtn setTitle:@"点击" forState:UIControlStateNormal]; [tapBtn setTitleColor:[UIColor greenColor] forState:UIControlStateNormal];
        [tapBtn addTarget:s_window action:@selector(doTap) forControlEvents:UIControlEventTouchUpInside];
        [panel addSubview:tapBtn];
        UIButton *copyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        copyBtn.frame = CGRectMake(260, 8, 60, 30); [copyBtn setTitle:@"复制" forState:UIControlStateNormal]; [copyBtn setTitleColor:[UIColor cyanColor] forState:UIControlStateNormal];
        [copyBtn addTarget:s_window action:@selector(doCopy) forControlEvents:UIControlEventTouchUpInside];
        [panel addSubview:copyBtn];
        UIButton *clearBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        clearBtn.frame = CGRectMake(320, 8, 50, 30); [clearBtn setTitle:@"清屏" forState:UIControlStateNormal]; [clearBtn setTitleColor:[UIColor grayColor] forState:UIControlStateNormal];
        [clearBtn addTarget:s_window action:@selector(doClear) forControlEvents:UIControlEventTouchUpInside];
        [panel addSubview:clearBtn];
        
        UITextView *logView = [[UITextView alloc] initWithFrame:CGRectMake(5, 44, panel.bounds.size.width - 10, panel.bounds.size.height - 50)];
        logView.backgroundColor = [UIColor clearColor]; logView.textColor = [UIColor greenColor]; logView.font = [UIFont systemFontOfSize:10]; logView.editable = NO; logView.tag = 20;
        [panel addSubview:logView];
        
        s_window.panel = panel;
        [s_window addSubview:panel];
        
        [NSTimer scheduledTimerWithTimeInterval:0.3 repeats:YES block:^(NSTimer *t) {
            UITextView *lv = (UITextView *)[panel viewWithTag:20];
            if (lv && ![lv.text isEqualToString:s_log]) { lv.text = s_log; [lv scrollRangeToVisible:NSMakeRange(s_log.length - 1, 1)]; }
        }];
    });
}
