#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach/mach_time.h>

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
        [log appendString:@"=== GSSendEvent 触摸测试 ===\n"];
        
        void *GSSendEventPtr = dlsym(RTLD_DEFAULT, "GSSendEvent");
        void *GSEventCreateWithEventRecordPtr = dlsym(RTLD_DEFAULT, "GSEventCreateWithEventRecord");
        void *GSEventSetTypePtr = dlsym(RTLD_DEFAULT, "GSEventSetType");
        void *GSEventSetLocationPtr = dlsym(RTLD_DEFAULT, "GSEventSetLocation");
        void *GSEventSetTimestampPtr = dlsym(RTLD_DEFAULT, "GSEventSetTimestamp");
        void *GSEventCreatePtr = dlsym(RTLD_DEFAULT, "GSEventCreate");
        void *GSEventSetSubtypePtr = dlsym(RTLD_DEFAULT, "GSEventSetSubtype");
        
        [log appendFormat:@"GSSendEvent: %@\n", GSSendEventPtr ? @"✅" : @"❌"];
        [log appendFormat:@"GSEventCreateWithEventRecord: %@\n", GSEventCreateWithEventRecordPtr ? @"✅" : @"❌"];
        [log appendFormat:@"GSEventSetType: %@\n", GSEventSetTypePtr ? @"✅" : @"❌"];
        [log appendFormat:@"GSEventSetLocation: %@\n", GSEventSetLocationPtr ? @"✅" : @"❌"];
        [log appendFormat:@"GSEventSetTimestamp: %@\n", GSEventSetTimestampPtr ? @"✅" : @"❌"];
        [log appendFormat:@"GSEventCreate: %@\n", GSEventCreatePtr ? @"✅" : @"❌"];
        [log appendFormat:@"GSEventSetSubtype: %@\n", GSEventSetSubtypePtr ? @"✅" : @"❌"];
        
        [log appendString:@"\n=== BKSHIDEventSetDigitizerInfo ===\n"];
        void *bk = dlsym(RTLD_DEFAULT, "BKSHIDEventSetDigitizerInfo");
        [log appendFormat:@"符号: %@\n", bk ? @"✅" : @"❌"];
        
        [log appendString:@"\n=== AXUIElement 测试 ===\n"];
        Class AXUIElement = NSClassFromString(@"AXUIElement");
        [log appendFormat:@"AXUIElement类: %@\n", AXUIElement ? @"✅" : @"❌"];
        
        UIScrollView *sv = [[UIScrollView alloc] initWithFrame:CGRectMake(5, 100, [UIScreen mainScreen].bounds.size.width - 10, [UIScreen mainScreen].bounds.size.height - 120)];
        sv.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.9];
        sv.layer.cornerRadius = 8;
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(8, 8, sv.bounds.size.width - 16, 0)];
        label.text = log;
        label.textColor = [UIColor greenColor];
        label.font = [UIFont systemFontOfSize:11];
        label.numberOfLines = 0;
        [label sizeToFit];
        sv.contentSize = CGSizeMake(sv.bounds.size.width, label.frame.size.height + 16);
        [sv addSubview:label];
        [s_window addSubview:sv];
    });
}
