#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>

@interface TestWindow : UIWindow
@end
static TestWindow *s_window = nil;

@implementation TestWindow
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) { self.windowLevel = CGFLOAT_MAX; self.backgroundColor = [UIColor clearColor]; self.hidden = NO; }
    return self;
}
@end

%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindowScene *as = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]] && s.activationState == UISceneActivationStateForegroundActive) { as = (UIWindowScene *)s; break; }
        }
        if (as) { s_window = [[TestWindow alloc] initWithFrame:as.coordinateSpace.bounds]; s_window.windowScene = as; }
        
        NSMutableString *log = [NSMutableString string];
        [log appendString:@"=== BackboardServices 符号测试 ===\n"];
        
        void *bsHandle = dlopen("/System/Library/PrivateFrameworks/BackboardServices.framework/BackboardServices", RTLD_NOW);
        [log appendFormat:@"dlopen: %@\n", bsHandle ? @"✅" : @"❌"];
        
        if (bsHandle) {
            void *f1 = dlsym(bsHandle, "BKSHIDEventSetDigitizerInfo");
            void *f2 = dlsym(bsHandle, "BKSHIDEventSetDigitizerPath");
            void *f3 = dlsym(bsHandle, "BKSHIDEventCreateDigitizerEvent");
            void *f4 = dlsym(bsHandle, "BKSHIDEventSendEvent");
            void *f5 = dlsym(bsHandle, "BKSHIDEventDigitizerPathCreate");
            void *f6 = dlsym(bsHandle, "BKSHIDEventDigitizerPathSetDigitizerInfo");
            void *f7 = dlsym(bsHandle, "BKSHIDEventDigitizerPathSend");
            [log appendFormat:@"BKSHIDEventSetDigitizerInfo: %@\n", f1 ? @"✅" : @"❌"];
            [log appendFormat:@"BKSHIDEventSetDigitizerPath: %@\n", f2 ? @"✅" : @"❌"];
            [log appendFormat:@"BKSHIDEventCreateDigitizerEvent: %@\n", f3 ? @"✅" : @"❌"];
            [log appendFormat:@"BKSHIDEventSendEvent: %@\n", f4 ? @"✅" : @"❌"];
            [log appendFormat:@"BKSHIDEventDigitizerPathCreate: %@\n", f5 ? @"✅" : @"❌"];
            [log appendFormat:@"BKSHIDEventDigitizerPathSetDigitizerInfo: %@\n", f6 ? @"✅" : @"❌"];
            [log appendFormat:@"BKSHIDEventDigitizerPathSend: %@\n", f7 ? @"✅" : @"❌"];
        }
        
        [log appendString:@"\n=== RTLD_DEFAULT 测试 ===\n"];
        void *r1 = dlsym(RTLD_DEFAULT, "BKSHIDEventSetDigitizerInfo");
        [log appendFormat:@"BKSHIDEventSetDigitizerInfo: %@\n", r1 ? @"✅" : @"❌"];
        
        [log appendString:@"\n=== 备用符号测试 ===\n"];
        void *a1 = dlsym(RTLD_DEFAULT, "BKSHIDEventDigitizerPathCreateWithTouches");
        void *a2 = dlsym(RTLD_DEFAULT, "BKSHIDEventDigitizerPathAttributeCreate");
        void *a3 = dlsym(RTLD_DEFAULT, "BKSHIDEventDigitizerPathAttributeSetTouch");
        [log appendFormat:@"BKSHIDEventDigitizerPathCreateWithTouches: %@\n", a1 ? @"✅" : @"❌"];
        [log appendFormat:@"BKSHIDEventDigitizerPathAttributeCreate: %@\n", a2 ? @"✅" : @"❌"];
        [log appendFormat:@"BKSHIDEventDigitizerPathAttributeSetTouch: %@\n", a3 ? @"✅" : @"❌"];
        
        // 显示结果
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(10, 100, [UIScreen mainScreen].bounds.size.width - 20, 600)];
        label.text = log;
        label.textColor = [UIColor greenColor];
        label.font = [UIFont systemFontOfSize:11];
        label.numberOfLines = 0;
        label.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.9];
        label.layer.cornerRadius = 8;
        label.clipsToBounds = YES;
        [s_window addSubview:label];
    });
}
