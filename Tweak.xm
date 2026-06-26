#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ==================== 前置声明 ====================
static NSString *getControlEventName(UIControlEvents event);
static void saveToFile(NSString *log);
static void analyzeTouchView(UIView *view, CGPoint touchPoint);
static void highlightView(UIView *view);
static void autoCheckAndSkipAd(void);

// ==================== 分析防抖 ====================
static NSDate *s_lastAnalysisTime = nil;
static const NSTimeInterval kMinAnalysisInterval = 0.3;

// ==================== 悬浮窗（略，保持原样） ====================
@interface AdInspectorWindow : UIWindow
// ... 不变 ...
@end
@implementation AdInspectorWindow
// ... 不变 ...
@end

// ==================== 工具函数（略，保持原样） ====================
static NSString *getControlEventName(UIControlEvents e) { /* ... 不变 ... */ }
static void saveToFile(NSString *log) { /* ... 不变 ... */ }
static void highlightView(UIView *view) { /* ... 不变 ... */ }
static void analyzeTouchView(UIView *view, CGPoint point) { /* ... 不变 ... */ }

// ==================== 自动跳过核心 ====================
static void autoCheckAndSkipAd(void) {
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        // 检查百度开屏广告窗口
        if ([window isKindOfClass:NSClassFromString(@"BDNCSplashAdvertiseBaseWindow")]) {
            UIButton *skipBtn = findSkipButtonInView(window);
            if (skipBtn && skipBtn.userInteractionEnabled && !skipBtn.hidden) {
                NSLog(@"[AutoSkip] 检测到广告，自动跳过: %@", skipBtn.titleLabel.text);
                [skipBtn sendActionsForControlEvents:UIControlEventTouchUpInside];
            }
        }
    }
}

static UIButton *findSkipButtonInView(UIView *view) {
    if ([view isKindOfClass:[UIButton class]]) {
        UIButton *btn = (UIButton *)view;
        NSString *title = [btn titleForState:UIControlStateNormal] ?: @"";
        if ([title hasPrefix:@"跳过"]) {
            return btn;
        }
    }
    for (UIView *subview in view.subviews) {
        UIButton *found = findSkipButtonInView(subview);
        if (found) return found;
    }
    return nil;
}

// ==================== Hook 实现 ====================
%hook UIWindow
- (void)sendEvent:(UIEvent *)event {
    %orig;
    if (event.type == UIEventTypeTouches) {
        NSSet *touches = [event allTouches];
        if (touches.count == 1) {
            UITouch *touch = [touches anyObject];
            if (touch.phase == UITouchPhaseEnded && touch.view) {
                analyzeTouchView(touch.view, [touch locationInView:nil]);
            }
        }
    }
}
%end

%hook UIControl
- (void)addTarget:(id)target action:(SEL)action forControlEvents:(UIControlEvents)controlEvents {
    NSLog(@"[AdInspector] 🔗 %@ → %@.%@ [%@]",
          NSStringFromClass([self class]),
          NSStringFromClass([target class]),
          NSStringFromSelector(action),
          getControlEventName(controlEvents));
    %orig;
}
%end

// ==================== 初始化（含定时器） ====================
%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [AdInspectorWindow shared];
        NSLog(@"[AdInspector] ✅ 已激活 - 自动跳过广告 + 分析点击");
        
        // 每0.5秒扫描一次广告窗口
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
            autoCheckAndSkipAd();
        }];
        
        // 初始化日志
        @try {
            NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
            if (paths.count > 0) {
                NSString *path = [paths[0] stringByAppendingPathComponent:@"AdInspector_Logs.txt"];
                NSString *header = [NSString stringWithFormat:@"\n=== AdInspector v2.0 [%@] ===\n",
                                   [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                                  dateStyle:NSDateFormatterShortStyle
                                                                  timeStyle:NSDateFormatterMediumStyle]];
                [header writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }
        } @catch (...) {}
    });
}
