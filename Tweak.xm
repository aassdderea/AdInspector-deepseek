#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>
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
        [log appendString:@"=== 全部触摸相关 API 测试 ===\n\n"];
        
        // 框架列表
        NSArray *frameworks = @[
            @"/System/Library/PrivateFrameworks/BackboardServices.framework/BackboardServices",
            @"/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
            @"/System/Library/PrivateFrameworks/BaseBoard.framework/BaseBoard",
            @"/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices",
            @"/System/Library/PrivateFrameworks/GraphicsServices.framework/GraphicsServices",
            @"/System/Library/Frameworks/UIKit.framework/UIKit",
            @"/System/Library/Frameworks/IOKit.framework/IOKit",
            @"/System/Library/PrivateFrameworks/Accessibility.framework/Accessibility",
            @"/System/Library/PrivateFrameworks/AccessibilityUI.framework/AccessibilityUI",
            @"/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities",
            @"/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime",
            @"/System/Library/PrivateFrameworks/XCTestCore.framework/XCTestCore",
            @"/System/Library/PrivateFrameworks/XCTAutomationSupport.framework/XCTAutomationSupport",
            @"/System/Library/Frameworks/XCTest.framework/XCTest",
        ];
        
        for (NSString *fw in frameworks) {
            void *h = dlopen([fw UTF8String], RTLD_NOW);
            [log appendFormat:@"%@: %@\n", [fw lastPathComponent], h ? @"✅" : @"❌"];
        }
        
        [log appendString:@"\n=== IOKit 符号 ===\n"];
        void *iok1 = dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerFingerEvent");
        void *iok2 = dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreate");
        void *iok3 = dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientDispatchEvent");
        void *iok4 = dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerEvent");
        void *iok5 = dlsym(RTLD_DEFAULT, "IOHIDEventSetFloatValue");
        void *iok6 = dlsym(RTLD_DEFAULT, "IOHIDEventSetIntegerValue");
        void *iok7 = dlsym(RTLD_DEFAULT, "IOHIDEventSetSenderID");
        [log appendFormat:@"IOHIDEventCreateDigitizerFingerEvent: %@\n", iok1 ? @"✅" : @"❌"];
        [log appendFormat:@"IOHIDEventSystemClientCreate: %@\n", iok2 ? @"✅" : @"❌"];
        [log appendFormat:@"IOHIDEventSystemClientDispatchEvent: %@\n", iok3 ? @"✅" : @"❌"];
        [log appendFormat:@"IOHIDEventCreateDigitizerEvent: %@\n", iok4 ? @"✅" : @"❌"];
        [log appendFormat:@"IOHIDEventSetFloatValue: %@\n", iok5 ? @"✅" : @"❌"];
        [log appendFormat:@"IOHIDEventSetIntegerValue: %@\n", iok6 ? @"✅" : @"❌"];
        [log appendFormat:@"IOHIDEventSetSenderID: %@\n", iok7 ? @"✅" : @"❌"];
        
        [log appendString:@"\n=== BackboardServices 符号 ===\n"];
        NSArray *bsSyms = @[
            @"BKSHIDEventSetDigitizerInfo", @"BKSHIDEventSetDigitizerPath",
            @"BKSHIDEventCreateDigitizerEvent", @"BKSHIDEventSendEvent",
            @"BKSHIDEventDigitizerPathCreate", @"BKSHIDEventDigitizerPathSetDigitizerInfo",
            @"BKSHIDEventDigitizerPathSend", @"BKSHIDEventDigitizerPathCreateWithTouches",
            @"BKSHIDEventDigitizerPathAttributeCreate", @"BKSHIDEventDigitizerPathAttributeSetTouch",
            @"BKSHIDEventSetDigitizerPathIdentity", @"BKSHIDEventSend",
            @"BKSHIDEventCreate", @"BKSHIDEventDigitizerPathAppendEvent",
            @"BKSHIDEventDigitizerPathInfoCreate", @"BKSHIDEventDigitizerPathInfoSetValue",
            @"BKSHIDEventDigitizerPathCreateFromTouches", @"BKSHIDigitizerPathCreate",
            @"BKSHIDEventDigitizerPathSetIdentity", @"BKSHIDEventDigitizerPathSetPhase",
            @"BKSHIDEventDigitizerPathSetLocation", @"BKSHIDEventDigitizerPathSetTouch",
            @"BKSHIDEventDigitizerPathSetFlags",
        ];
        for (NSString *sym in bsSyms) {
            void *f = dlsym(RTLD_DEFAULT, [sym UTF8String]);
            [log appendFormat:@"%@: %@\n", sym, f ? @"✅" : @"❌"];
        }
        
        [log appendString:@"\n=== SpringBoardServices 符号 ===\n"];
        NSArray *sbsSyms = @[
            @"SBSProcessIDForDisplayIdentifier", @"SBSSystemServiceClient",
            @"SBSApplicationShortcutService", @"SBSSystemGestureManager",
            @"SBSTouchEvent", @"SBSTouchEventService", @"SBSEventSender",
            @"SBSDispatchEvent", @"SBSSendEvent",
        ];
        for (NSString *sym in sbsSyms) {
            void *f = dlsym(RTLD_DEFAULT, [sym UTF8String]);
            [log appendFormat:@"%@: %@\n", sym, f ? @"✅" : @"❌"];
        }
        
        [log appendString:@"\n=== 系统手势相关符号 ===\n"];
        NSArray *gsSyms = @[
            @"GSCreateEvent", @"GSSendEvent", @"GSEventCreateWithEventRecord",
            @"GSEventRecordCreate", @"GSEventSetLocation", @"GSEventSetType",
            @"GSEventSetTimestamp", @"GSEventSetSubtype",
            @"_UIApplicationSendEvent", @"_UISendEvent",
            @"UIApplicationMainSendEvent", @"_UIGestureRecognizerSendEvent",
            @"_UIApplicationHandleEvent", @"_UIApplicationHandleEventQueue",
        ];
        for (NSString *sym in gsSyms) {
            void *f = dlsym(RTLD_DEFAULT, [sym UTF8String]);
            [log appendFormat:@"%@: %@\n", sym, f ? @"✅" : @"❌"];
        }
        
        [log appendString:@"\n=== 类测试 ===\n"];
        NSArray *classes = @[
            @"SBSyntheticTouch", @"SBSystemGestureManager", @"SBFakeTouch",
            @"SBTouchTemplate", @"ASTTouchProvider", @"AXAssertion",
            @"AXUIClient", @"AXUIElement", @"XCSynthesizedEventRecord",
            @"XCPointerEventPath", @"XCTouchGesture", @"XCSynthesizedEventRecorder",
            @"UIEventFetcher", @"UIInternalEvent", @"UIEventDispatcher",
            @"_UIApplicationEventDispatcher", @"UIApplicationEventDispatcher",
            @"BSAction", @"BSActionResponder", @"BSEvent",
            @"BKTouchEvent", @"BKEvent", @"BKEventSender",
            @"FBSSystemService", @"FBSOpenApplicationService",
            @"GSEvent", @"GSEventRecord", @"GSEventFactory",
        ];
        for (NSString *cn in classes) {
            Class cls = NSClassFromString(cn);
            if (!cls) cls = objc_getClass([cn UTF8String]);
            [log appendFormat:@"%@: %@\n", cn, cls ? @"✅" : @"❌"];
        }
        
        // 滚动视图
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
