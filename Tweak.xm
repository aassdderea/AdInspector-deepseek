#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>
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

typedef struct __GSEvent *GSEventRef;

%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindowScene *as = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]] && s.activationState == UISceneActivationStateForegroundActive) { as = (UIWindowScene *)s; break; }
        }
        if (as) { s_window = [[TestWindow alloc] initWithFrame:as.coordinateSpace.bounds]; s_window.windowScene = as; }
        
        NSMutableString *log = [NSMutableString string];
        [log appendString:@"=== GSSendEvent 触摸测试 ===\n"];
        
        // 动态加载
        void (*GSSendEventPtr)(GSEventRef) = dlsym(RTLD_DEFAULT, "GSSendEvent");
        GSEventRef (*GSEventCreateWithEventRecordPtr)(void *) = dlsym(RTLD_DEFAULT, "GSEventCreateWithEventRecord");
        void (*GSEventSetTypePtr)(GSEventRef, int) = dlsym(RTLD_DEFAULT, "GSEventSetType");
        void (*GSEventSetLocationPtr)(GSEventRef, CGPoint) = dlsym(RTLD_DEFAULT, "GSEventSetLocation");
        void (*GSEventSetTimestampPtr)(GSEventRef, uint64_t) = dlsym(RTLD_DEFAULT, "GSEventSetTimestamp");
        GSEventRef (*GSEventCreatePtr)(int, int) = dlsym(RTLD_DEFAULT, "GSEventCreate");
        void (*GSEventSetSubtypePtr)(GSEventRef, int) = dlsym(RTLD_DEFAULT, "GSEventSetSubtype");
        
        [log appendFormat:@"GSSendEvent: %@\n", GSSendEventPtr ? @"✅" : @"❌"];
        [log appendFormat:@"GSEventCreateWithEventRecord: %@\n", GSEventCreateWithEventRecordPtr ? @"✅" : @"❌"];
        [log appendFormat:@"GSEventSetType: %@\n", GSEventSetTypePtr ? @"✅" : @"❌"];
        [log appendFormat:@"GSEventSetLocation: %@\n", GSEventSetLocationPtr ? @"✅" : @"❌"];
        [log appendFormat:@"GSEventSetTimestamp: %@\n", GSEventSetTimestampPtr ? @"✅" : @"❌"];
        [log appendFormat:@"GSEventCreate: %@\n", GSEventCreatePtr ? @"✅" : @"❌"];
        [log appendFormat:@"GSEventSetSubtype: %@\n", GSEventSetSubtypePtr ? @"✅" : @"❌"];
        
        // BKSHIDEventSetDigitizerInfo 签名探测
        [log appendString:@"\n=== BKSHIDEventSetDigitizerInfo 签名 ===\n"];
        void *bk = dlsym(RTLD_DEFAULT, "BKSHIDEventSetDigitizerInfo");
        if (bk) {
            [log appendString:@"函数指针存在，尝试多种参数组合...\n"];
            
            // 尝试1: 直接传坐标
            @try {
                ((void (*)(int, float, float, float, float))bk)(1, 100, 200, 0, 1.0);
                [log appendString:@"尝试1 (int,float,float,float,float): ✅ 没崩溃\n"];
            } @catch (NSException *e) {
                [log appendFormat:@"尝试1: ❌ %@\n", e.reason];
            }
        }
        
        // 用 AXUIElement 试试
        [log appendString:@"\n=== AXUIElement 测试 ===\n"];
        Class AXUIElement = NSClassFromString(@"AXUIElement");
        [log appendFormat:@"AXUIElement: %@\n", AXUIElement ? @"✅" : @"❌"];
        Class AXUIClient = NSClassFromString(@"AXUIClient");
        [log appendFormat:@"AXUIClient: %@\n", AXUIClient ? @"✅" : @"❌"];
        if (AXUIElement) {
            @try {
                id elem = [AXUIElement performSelector:@selector(elementWithAXUIElementRef:) withObject:nil];
                [log appendFormat:@"elementWithAXUIElementRef: %@\n", elem ? @"✅" : @"❌"];
            } @catch (NSException *e) {
                [log appendFormat:@"❌ %@\n", e.reason];
            }
        }
        
        // FBSSystemService
        [log appendString:@"\n=== FBSSystemService 测试 ===\n"];
        Class FBSSystemService = NSClassFromString(@"FBSSystemService");
        if (FBSSystemService) {
            id svc = [FBSSystemService performSelector:@selector(sharedService)];
            [log appendFormat:@"FBSSystemService: %@\n", svc ? @"✅" : @"❌"];
        }
        
        // 显示
        UIScrollView *sv = [[UIScrollView alloc] initWithFrame:CGRectMake(5, 100, [UIScreen mainScreen].bounds.size.width - 10, [UIScreen mainScreen].bounds.size.height - 120)];
        sv.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.9];
        sv.layer.cornerRadius = 8;
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(8, 8, sv.bounds.size.width - 16, 0)];
        label.text = log;
        label.textColor = [UIColor greenColor];
        label.font = [UIFont systemFontOfSize:10];
        label.numberOfLines = 0;
        [label sizeToFit];
        sv.contentSize = CGSizeMake(sv.bounds.size.width, label.frame.size.height + 16);
        [sv addSubview:label];
        [s_window addSubview:sv];
    });
}
