#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach/mach_time.h>

typedef struct __IOHIDEvent *IOHIDEventRef;

@interface TestWindow : UIWindow
@end
static TestWindow *s_window = nil;
static NSMutableString *s_log = nil;

@implementation TestWindow
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) { self.windowLevel = CGFLOAT_MAX; self.backgroundColor = [UIColor clearColor]; self.hidden = NO; }
    return self;
}
@end

static void logMsg(NSString *m) {
    [s_log appendFormat:@"%@\n", m];
}

// IOKit 函数指针
static IOHIDEventRef (*IOHIDEventCreateDigitizerFingerEventPtr)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, Boolean, Boolean, double, double, double, double, double, double) = NULL;
static void * (*IOHIDEventSystemClientCreatePtr)(CFAllocatorRef) = NULL;
static void (*IOHIDEventSystemClientDispatchEventPtr)(void *, IOHIDEventRef) = NULL;
static IOHIDEventRef (*IOHIDEventCreateDigitizerEventPtr)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, Boolean, Boolean, uint32_t, double, double, double, double, double, double, uint32_t) = NULL;

// GSSendEvent 函数指针
static void (*GSSendEventPtr)(void *) = NULL;
static void * (*GSEventCreateWithEventRecordPtr)(void *) = NULL;
static void (*GSEventSetTypePtr)(void *, int) = NULL;

%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindowScene *as = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]] && s.activationState == UISceneActivationStateForegroundActive) { as = (UIWindowScene *)s; break; }
        }
        if (as) { s_window = [[TestWindow alloc] initWithFrame:as.coordinateSpace.bounds]; s_window.windowScene = as; }
        s_log = [NSMutableString string];
        
        // 加载符号
        IOHIDEventCreateDigitizerFingerEventPtr = (IOHIDEventRef (*)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, Boolean, Boolean, double, double, double, double, double, double))dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerFingerEvent");
        IOHIDEventSystemClientCreatePtr = (void *(*)(CFAllocatorRef))dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreate");
        IOHIDEventSystemClientDispatchEventPtr = (void (*)(void *, IOHIDEventRef))dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientDispatchEvent");
        IOHIDEventCreateDigitizerEventPtr = (IOHIDEventRef (*)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, Boolean, Boolean, uint32_t, double, double, double, double, double, double, uint32_t))dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerEvent");
        GSSendEventPtr = dlsym(RTLD_DEFAULT, "GSSendEvent");
        GSEventCreateWithEventRecordPtr = dlsym(RTLD_DEFAULT, "GSEventCreateWithEventRecord");
        GSEventSetTypePtr = dlsym(RTLD_DEFAULT, "GSEventSetType");
        
        logMsg(@"=== 符号加载状态 ===");
        logMsg([NSString stringWithFormat:@"IOHIDEventCreateDigitizerFingerEvent: %@", IOHIDEventCreateDigitizerFingerEventPtr ? @"✅" : @"❌"]);
        logMsg([NSString stringWithFormat:@"IOHIDEventSystemClientCreate: %@", IOHIDEventSystemClientCreatePtr ? @"✅" : @"❌"]);
        logMsg([NSString stringWithFormat:@"IOHIDEventSystemClientDispatchEvent: %@", IOHIDEventSystemClientDispatchEventPtr ? @"✅" : @"❌"]);
        logMsg([NSString stringWithFormat:@"IOHIDEventCreateDigitizerEvent: %@", IOHIDEventCreateDigitizerEventPtr ? @"✅" : @"❌"]);
        logMsg([NSString stringWithFormat:@"GSSendEvent: %@", GSSendEventPtr ? @"✅" : @"❌"]);
        logMsg([NSString stringWithFormat:@"GSEventCreateWithEventRecord: %@", GSEventCreateWithEventRecordPtr ? @"✅" : @"❌"]);
        logMsg([NSString stringWithFormat:@"GSEventSetType: %@", GSEventSetTypePtr ? @"✅" : @"❌"]);
        
        // 创建 UI：输入框 + 执行按钮 + 日志
        UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(10, 80, [UIScreen mainScreen].bounds.size.width - 20, [UIScreen mainScreen].bounds.size.height - 100)];
        panel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
        panel.layer.cornerRadius = 10;
        panel.layer.borderWidth = 1;
        panel.layer.borderColor = [UIColor greenColor].CGColor;
        
        UITextField *xField = [[UITextField alloc] initWithFrame:CGRectMake(12, 8, 80, 30)];
        xField.borderStyle = UITextBorderStyleRoundedRect;
        xField.backgroundColor = [UIColor darkGrayColor];
        xField.textColor = [UIColor whiteColor];
        xField.text = @"100";
        xField.placeholder = @"X";
        [panel addSubview:xField];
        
        UITextField *yField = [[UITextField alloc] initWithFrame:CGRectMake(100, 8, 80, 30)];
        yField.borderStyle = UITextBorderStyleRoundedRect;
        yField.backgroundColor = [UIColor darkGrayColor];
        yField.textColor = [UIColor whiteColor];
        yField.text = @"200";
        yField.placeholder = @"Y";
        [panel addSubview:yField];
        
        UIButton *tapBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        tapBtn.frame = CGRectMake(190, 8, 60, 30);
        [tapBtn setTitle:@"点击" forState:UIControlStateNormal];
        [tapBtn setTitleColor:[UIColor greenColor] forState:UIControlStateNormal];
        tapBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        [panel addSubview:tapBtn];
        
        UIButton *copyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        copyBtn.frame = CGRectMake(260, 8, 60, 30);
        [copyBtn setTitle:@"复制" forState:UIControlStateNormal];
        [copyBtn setTitleColor:[UIColor cyanColor] forState:UIControlStateNormal];
        copyBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
        [panel addSubview:copyBtn];
        
        UIButton *clearBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        clearBtn.frame = CGRectMake(320, 8, 50, 30);
        [clearBtn setTitle:@"清屏" forState:UIControlStateNormal];
        [clearBtn setTitleColor:[UIColor grayColor] forState:UIControlStateNormal];
        clearBtn.titleLabel.font = [UIFont systemFontOfSize:12];
        [panel addSubview:clearBtn];
        
        UITextView *logView = [[UITextView alloc] initWithFrame:CGRectMake(5, 44, panel.bounds.size.width - 10, panel.bounds.size.height - 50)];
        logView.backgroundColor = [UIColor clearColor];
        logView.textColor = [UIColor greenColor];
        logView.font = [UIFont systemFontOfSize:10];
        logView.editable = NO;
        logView.text = s_log;
        [panel addSubview:logView];
        
        [s_window addSubview:panel];
        
        // 按钮事件
        tapBtn.tag = 1;
        copyBtn.tag = 2;
        clearBtn.tag = 3;
        xField.tag = 10;
        yField.tag = 11;
        logView.tag = 20;
        panel.tag = 30;
        
        // 定时刷新日志
        [NSTimer scheduledTimerWithTimeInterval:0.3 repeats:YES block:^(NSTimer *t) {
            UITextView *lv = (UITextView *)[panel viewWithTag:20];
            if (lv && ![lv.text isEqualToString:s_log]) {
                lv.text = s_log;
                [lv scrollRangeToVisible:NSMakeRange(s_log.length - 1, 1)];
            }
        }];
        
        // 点击事件
        [tapBtn addTarget:^(UIButton *btn) {
            UITextField *xf = (UITextField *)[panel viewWithTag:10];
            UITextField *yf = (UITextField *)[panel viewWithTag:11];
            CGFloat x = [xf.text floatValue];
            CGFloat y = [yf.text floatValue];
            CGFloat scale = [UIScreen mainScreen].scale;
            double px = x * scale, py = y * scale;
            
            logMsg([NSString stringWithFormat:@"\n🖐 测试坐标 (%.0f, %.0f)", x, y]);
            
            // 方案1: IOKit 直发
            if (IOHIDEventCreateDigitizerFingerEventPtr && IOHIDEventSystemClientCreatePtr && IOHIDEventSystemClientDispatchEventPtr) {
                uint64_t ts = mach_absolute_time();
                IOHIDEventRef down = IOHIDEventCreateDigitizerFingerEventPtr(kCFAllocatorDefault, ts, 0, 2, 0x01, NO, YES, px, py, 0, 1.0, 0, 0);
                if (down) {
                    void *c = IOHIDEventSystemClientCreatePtr(kCFAllocatorDefault);
                    if (c) { IOHIDEventSystemClientDispatchEventPtr(c, down); CFRelease(c); }
                    CFRelease(down);
                    logMsg(@"IOKit down 已发送");
                }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    IOHIDEventRef up = IOHIDEventCreateDigitizerFingerEventPtr(kCFAllocatorDefault, mach_absolute_time(), 0, 2, 0x01, NO, NO, px, py, 0, 1.0, 0, 0);
                    if (up) {
                        void *c = IOHIDEventSystemClientCreatePtr(kCFAllocatorDefault);
                        if (c) { IOHIDEventSystemClientDispatchEventPtr(c, up); CFRelease(c); }
                        CFRelease(up);
                        logMsg(@"IOKit up 已发送 ✅");
                    }
                });
            }
            
            // 方案2: GSSendEvent
            if (GSSendEventPtr && GSEventCreateWithEventRecordPtr && IOHIDEventCreateDigitizerFingerEventPtr) {
                uint64_t ts = mach_absolute_time();
                IOHIDEventRef hidEvent = IOHIDEventCreateDigitizerFingerEventPtr(kCFAllocatorDefault, ts, 0, 2, 0x01, NO, YES, px, py, 0, 1.0, 0, 0);
                if (hidEvent) {
                    void *gsEvent = GSEventCreateWithEventRecordPtr((__bridge void *)[NSNull null]);
                    if (gsEvent) {
                        GSEventSetTypePtr(gsEvent, 3001); // 触摸事件类型
                        GSSendEventPtr(gsEvent);
                        logMsg(@"GSSendEvent 已发送 ✅");
                    } else {
                        // 用 NSDictionary 构造 record
                        NSDictionary *record = @{@"type": @3001, @"x": @(x), @"y": @(y)};
                        void *gsEvent2 = GSEventCreateWithEventRecordPtr((__bridge void *)record);
                        if (gsEvent2) {
                            GSSendEventPtr(gsEvent2);
                            logMsg(@"GSSendEvent(dict) 已发送 ✅");
                        } else {
                            logMsg(@"GSEventCreateWithEventRecord 失败 ❌");
                        }
                    }
                    CFRelease(hidEvent);
                }
            }
            
            // 方案3: AXUIElement
            Class AXUIElement = NSClassFromString(@"AXUIElement");
            if (AXUIElement) {
                SEL sel = NSSelectorFromString(@"elementWithAXUIElementRef:");
                @try {
                    id elem = ((id (*)(id, SEL, void *))objc_msgSend)(AXUIElement, sel, NULL);
                    if (elem) {
                        SEL pressSel = NSSelectorFromString(@"performAction:");
                        ((void (*)(id, SEL, int))objc_msgSend)(elem, pressSel, 1);
                        logMsg(@"AXUIElement 已执行 ✅");
                    } else {
                        logMsg(@"AXUIElement 创建失败 ❌");
                    }
                } @catch (NSException *e) {
                    logMsg([NSString stringWithFormat:@"AXUIElement 异常: %@", e.reason]);
                }
            }
            
            // 红圈指示器
            UIView *circle = [[UIView alloc] initWithFrame:CGRectMake(x - 15, y - 15, 30, 30)];
            circle.backgroundColor = [UIColor clearColor];
            circle.layer.cornerRadius = 15;
            circle.layer.borderWidth = 2;
            circle.layer.borderColor = [UIColor redColor].CGColor;
            circle.layer.zPosition = CGFLOAT_MAX;
            circle.userInteractionEnabled = NO;
            [s_window addSubview:circle];
            [UIView animateWithDuration:0.5 delay:0.3 options:UIViewAnimationOptionCurveEaseOut animations:^{
                circle.alpha = 0;
                circle.transform = CGAffineTransformMakeScale(2, 2);
            } completion:^(BOOL f) { [circle removeFromSuperview]; }];
            
            [xf resignFirstResponder];
            [yf resignFirstResponder];
        } forControlEvents:UIControlEventTouchUpInside];
        
        [copyBtn addTarget:^(UIButton *btn) {
            [[UIPasteboard generalPasteboard] setString:s_log];
            logMsg(@"📋 日志已复制");
        } forControlEvents:UIControlEventTouchUpInside];
        
        [clearBtn addTarget:^(UIButton *btn) {
            [s_log setString:@""];
        } forControlEvents:UIControlEventTouchUpInside];
    });
}
