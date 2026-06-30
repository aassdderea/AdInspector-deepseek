#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach/mach_time.h>
#import <mach/mach.h>

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

- (void)handlePan:(UIPanGestureRecognizer *)p {
    UIView *v = p.view;
    CGPoint t = [p translationInView:v];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [p setTranslation:CGPointZero inView:v];
}

- (void)doTap {
    UIView *panel = self.panel;
    UITextField *xf = (UITextField *)[panel viewWithTag:10];
    UITextField *yf = (UITextField *)[panel viewWithTag:11];
    CGFloat x = [xf.text floatValue], y = [yf.text floatValue];
    CGFloat scale = [UIScreen mainScreen].scale;
    double px = x * scale, py = y * scale;
    logMsg([NSString stringWithFormat:@"\n🖐 测试坐标 (%.0f, %.0f)", x, y]);
    
    // IOKit 直接 mach_msg 发送
    if (IOHIDEventCreateDigitizerFingerEventPtr && IOHIDEventSystemClientCreatePtr) {
        @try {
            void *client = IOHIDEventSystemClientCreatePtr(kCFAllocatorDefault);
            if (client) {
                int offsets[] = {8, 16, 24, 32, 40, 48, 56, 64};
                mach_port_t port = 0;
                int foundOffset = -1;
                for (int i = 0; i < 8; i++) {
                    mach_port_t p = *(mach_port_t *)((uint8_t *)client + offsets[i]);
                    if (p > 0 && p < 0x10000) {
                        mach_port_type_t ptype;
                        if (mach_port_type(mach_task_self(), p, &ptype) == KERN_SUCCESS) {
                            port = p;
                            foundOffset = offsets[i];
                            break;
                        }
                    }
                }
                
                if (port && foundOffset >= 0) {
                    logMsg([NSString stringWithFormat:@"🔍 找到HID port: 0x%X 偏移:%d", port, foundOffset]);
                    
                    uint64_t ts = mach_absolute_time();
                    IOHIDEventRef hidDown = IOHIDEventCreateDigitizerFingerEventPtr(kCFAllocatorDefault, ts, 0, 2, 0x01, NO, YES, px, py, 0, 1.0, 0, 0);
                    if (hidDown) {
                        size_t eventSize = 128;
                        mach_msg_header_t *msg = (mach_msg_header_t *)calloc(1, sizeof(mach_msg_header_t) + eventSize);
                        msg->msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
                        msg->msgh_remote_port = port;
                        msg->msgh_size = sizeof(mach_msg_header_t) + eventSize;
                        msg->msgh_id = 0;
                        memcpy((uint8_t *)msg + sizeof(mach_msg_header_t), (uint8_t *)hidDown, eventSize);
                        
                        kern_return_t kr = mach_msg_send(msg);
                        logMsg([NSString stringWithFormat:@"mach_msg_send(down): %s", mach_error_string(kr)]);
                        free(msg);
                        CFRelease(hidDown);
                    }
                    
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        IOHIDEventRef hidUp = IOHIDEventCreateDigitizerFingerEventPtr(kCFAllocatorDefault, mach_absolute_time(), 0, 2, 0x01, NO, NO, px, py, 0, 1.0, 0, 0);
                        if (hidUp) {
                            size_t eventSize = 128;
                            mach_msg_header_t *msg = (mach_msg_header_t *)calloc(1, sizeof(mach_msg_header_t) + eventSize);
                            msg->msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
                            msg->msgh_remote_port = port;
                            msg->msgh_size = sizeof(mach_msg_header_t) + eventSize;
                            memcpy((uint8_t *)msg + sizeof(mach_msg_header_t), (uint8_t *)hidUp, eventSize);
                            mach_msg_send(msg);
                            free(msg);
                            CFRelease(hidUp);
                            logMsg(@"mach_msg up ✅");
                        }
                    });
                } else {
                    logMsg(@"❌ 未找到HID port");
                }
                CFRelease(client);
            }
        } @catch (NSException *e) { logMsg([NSString stringWithFormat:@"mach异常: %@", e.reason]); }
    }
    
    if (GSSendEventPtr && GSEventCreateWithEventRecordPtr) {
        @try {
            uint8_t *buf = (uint8_t *)calloc(1, 72);
            *(int *)buf = 3001;
            *((int *)buf + 1) = 1;
            *((uint64_t *)(buf + 8)) = mach_absolute_time();
            *((CGFloat *)(buf + 24)) = x;
            *((CGFloat *)(buf + 32)) = y;
            *((CGFloat *)(buf + 40)) = 1.0;
            *((int *)(buf + 52)) = 1;
            void *gs = ((void *(*)(void *))GSEventCreateWithEventRecordPtr)(buf);
            if (gs) { ((void (*)(void *))GSSendEventPtr)(gs); logMsg(@"GSSendEvent began ✅"); }
            free(buf);
            
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                uint8_t *buf2 = (uint8_t *)calloc(1, 72);
                *(int *)buf2 = 3001;
                *((int *)buf2 + 1) = 3;
                *((uint64_t *)(buf2 + 8)) = mach_absolute_time();
                *((CGFloat *)(buf2 + 24)) = x;
                *((CGFloat *)(buf2 + 32)) = y;
                *((CGFloat *)(buf2 + 40)) = 1.0;
                *((int *)(buf2 + 52)) = 1;
                void *gs2 = ((void *(*)(void *))GSEventCreateWithEventRecordPtr)(buf2);
                if (gs2) { ((void (*)(void *))GSSendEventPtr)(gs2); logMsg(@"GSSendEvent ended ✅"); }
                free(buf2);
            });
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

%hook UIApplication
- (void)sendEvent:(UIEvent *)e {
    %orig;
    if (e.type == UIEventTypeTouches) {
        @try {
            NSSet *touches = [e allTouches];
            UITouch *t = [touches anyObject];
            if (t.phase == UITouchPhaseEnded) {
                id record = [t valueForKey:@"_touchRecord"];
                if (record) {
                    NSData *data = [record valueForKey:@"recordData"];
                    if (!data) data = [NSData dataWithBytes:(__bridge void *)record length:72];
                    if (data.length >= 72) {
                        const uint8_t *bytes = (const uint8_t *)data.bytes;
                        NSMutableString *hex = [NSMutableString string];
                        for (int i = 0; i < 72; i++) [hex appendFormat:@"%02X ", bytes[i]];
                        logMsg([NSString stringWithFormat:@"📐 TouchRecord 72字节:\n%@", hex]);
                    }
                }
            }
        } @catch (NSException *ex) {}
    }
}
%end

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
        void *IOHIDEventSystemClientCopyServicePtr = dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCopyService");

        logMsg(@"=== 符号状态 ===");
        logMsg([NSString stringWithFormat:@"IOKit: %@", IOHIDEventCreateDigitizerFingerEventPtr ? @"✅" : @"❌"]);
        logMsg([NSString stringWithFormat:@"GSSendEvent: %@", GSSendEventPtr ? @"✅" : @"❌"]);
        logMsg([NSString stringWithFormat:@"GSEventCreateWithEventRecord: %@", GSEventCreateWithEventRecordPtr ? @"✅" : @"❌"]);
        logMsg([NSString stringWithFormat:@"GSEventSetType: %@", GSEventSetTypePtr ? @"✅" : @"❌"]);
        logMsg([NSString stringWithFormat:@"IOHIDEventSystemClientCopyService: %@", IOHIDEventSystemClientCopyServicePtr ? @"✅" : @"❌"]);
        
        CGFloat pw = [UIScreen mainScreen].bounds.size.width - 60;
        CGFloat ph = 200;
        UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(30, 150, pw, ph)];
        panel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
        panel.layer.cornerRadius = 10; panel.layer.borderWidth = 1; panel.layer.borderColor = [UIColor greenColor].CGColor;
        UIView *handle = [[UIView alloc] initWithFrame:CGRectMake(pw/2 - 20, 4, 40, 4)]; handle.backgroundColor = [UIColor colorWithWhite:0.4 alpha:0.6]; handle.layer.cornerRadius = 2;
        [panel addSubview:handle];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:s_window action:@selector(handlePan:)];
        [panel addGestureRecognizer:pan];
        UITextField *xf = [[UITextField alloc] initWithFrame:CGRectMake(12, 14, 70, 28)]; xf.borderStyle = UITextBorderStyleRoundedRect; xf.backgroundColor = [UIColor darkGrayColor]; xf.textColor = [UIColor whiteColor]; xf.font = [UIFont systemFontOfSize:12]; xf.text = @"100"; xf.tag = 10; [panel addSubview:xf];
        UITextField *yf = [[UITextField alloc] initWithFrame:CGRectMake(88, 14, 70, 28)]; yf.borderStyle = UITextBorderStyleRoundedRect; yf.backgroundColor = [UIColor darkGrayColor]; yf.textColor = [UIColor whiteColor]; yf.font = [UIFont systemFontOfSize:12]; yf.text = @"200"; yf.tag = 11; [panel addSubview:yf];
        UIButton *tb = [UIButton buttonWithType:UIButtonTypeSystem]; tb.frame = CGRectMake(165, 12, 55, 30); [tb setTitle:@"点击" forState:UIControlStateNormal]; [tb setTitleColor:[UIColor greenColor] forState:UIControlStateNormal]; tb.titleLabel.font = [UIFont boldSystemFontOfSize:13]; [tb addTarget:s_window action:@selector(doTap) forControlEvents:UIControlEventTouchUpInside]; [panel addSubview:tb];
        UIButton *cb = [UIButton buttonWithType:UIButtonTypeSystem]; cb.frame = CGRectMake(225, 12, 55, 30); [cb setTitle:@"复制" forState:UIControlStateNormal]; [cb setTitleColor:[UIColor cyanColor] forState:UIControlStateNormal]; cb.titleLabel.font = [UIFont boldSystemFontOfSize:11]; [cb addTarget:s_window action:@selector(doCopy) forControlEvents:UIControlEventTouchUpInside]; [panel addSubview:cb];
        UIButton *clb = [UIButton buttonWithType:UIButtonTypeSystem]; clb.frame = CGRectMake(282, 12, 45, 30); [clb setTitle:@"清屏" forState:UIControlStateNormal]; [clb setTitleColor:[UIColor grayColor] forState:UIControlStateNormal]; clb.titleLabel.font = [UIFont systemFontOfSize:11]; [clb addTarget:s_window action:@selector(doClear) forControlEvents:UIControlEventTouchUpInside]; [panel addSubview:clb];
        UITextView *lv = [[UITextView alloc] initWithFrame:CGRectMake(5, 50, pw - 10, ph - 55)]; lv.backgroundColor = [UIColor clearColor]; lv.textColor = [UIColor greenColor]; lv.font = [UIFont systemFontOfSize:10]; lv.editable = NO; lv.tag = 20; [panel addSubview:lv];
        s_window.panel = panel; [s_window addSubview:panel];
        [NSTimer scheduledTimerWithTimeInterval:0.3 repeats:YES block:^(NSTimer *t) { UITextView *v = (UITextView *)[panel viewWithTag:20]; if (v && ![v.text isEqualToString:s_log]) { v.text = s_log; [v scrollRangeToVisible:NSMakeRange(s_log.length - 1, 1)]; } }];
    });
}
