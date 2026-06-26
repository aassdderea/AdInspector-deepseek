#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ==================== 前置声明 ====================
static NSString *getControlEventName(UIControlEvents event);
static void saveToFile(NSString *log);
static void analyzeTouchView(UIView *view, CGPoint touchPoint);
static void highlightView(UIView *view);
static void autoCheckAndSkipAd(void);
static UIButton *findSkipButtonInView(UIView *view);

// ==================== 分析防抖 ====================
static NSDate *s_lastAnalysisTime = nil;
static const NSTimeInterval kMinAnalysisInterval = 0.3;

// ==================== 悬浮窗 ====================
@interface AdInspectorWindow : UIWindow
@property (nonatomic, strong) UITextView *logTextView;
@property (nonatomic, strong) NSMutableString *logBuffer;
+ (instancetype)shared;
- (void)showLog:(NSString *)log;
@end

@implementation AdInspectorWindow

+ (instancetype)shared {
    static AdInspectorWindow *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AdInspectorWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    });
    return instance;
}

- (instancetype)initWithFrame:(CGRect)frame {
    CGFloat w = frame.size.width;
    self = [super initWithFrame:CGRectMake(5, 80, w - 10, 280)];
    if (self) {
        self.windowLevel = UIWindowLevelAlert + 999;
        self.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.88];
        self.layer.cornerRadius = 10;
        self.layer.borderWidth = 1.5;
        self.layer.borderColor = [UIColor cyanColor].CGColor;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOffset = CGSizeMake(0, 2);
        self.layer.shadowOpacity = 0.6;
        self.hidden = NO;
        self.userInteractionEnabled = YES;
        self.clipsToBounds = NO;

        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, 200, 20)];
        title.text = @"🔍 AdInspector";
        title.textColor = [UIColor cyanColor];
        title.font = [UIFont boldSystemFontOfSize:14];
        [self addSubview:title];

        UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
        close.frame = CGRectMake(self.bounds.size.width - 45, 3, 40, 30);
        [close setTitle:@"✕" forState:UIControlStateNormal];
        [close setTitleColor:[UIColor redColor] forState:UIControlStateNormal];
        close.titleLabel.font = [UIFont boldSystemFontOfSize:20];
        [close addTarget:self action:@selector(hideSelf) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:close];

        UIView *handle = [[UIView alloc] initWithFrame:CGRectMake(self.bounds.size.width/2 - 15, 4, 30, 4)];
        handle.backgroundColor = [UIColor colorWithWhite:0.4 alpha:0.6];
        handle.layer.cornerRadius = 2;
        [self addSubview:handle];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];

        CGFloat tvY = 32;
        self.logTextView = [[UITextView alloc] initWithFrame:CGRectMake(5, tvY, self.bounds.size.width - 10, self.bounds.size.height - tvY - 5)];
        self.logTextView.backgroundColor = [UIColor clearColor];
        self.logTextView.textColor = [UIColor greenColor];
        self.logTextView.font = [UIFont fontWithName:@"Courier" size:10] ?: [UIFont systemFontOfSize:10];
        self.logTextView.editable = NO;
        self.logTextView.selectable = YES;
        self.logTextView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
        self.logTextView.textContainerInset = UIEdgeInsetsMake(2, 2, 2, 2);
        [self addSubview:self.logTextView];

        self.logBuffer = [NSMutableString string];
    }
    return self;
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint t = [pan translationInView:self];
    self.center = CGPointMake(self.center.x + t.x, self.center.y + t.y);
    [pan setTranslation:CGPointZero inView:self];
}

- (void)hideSelf {
    self.hidden = YES;
}

- (void)showLog:(NSString *)log {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.logBuffer appendString:log];
        if (self.logBuffer.length > 8000) {
            [self.logBuffer deleteCharactersInRange:NSMakeRange(0, self.logBuffer.length - 8000)];
        }
        self.logTextView.text = self.logBuffer;
        if (self.logTextView.text.length > 0) {
            [self.logTextView scrollRangeToVisible:NSMakeRange(self.logTextView.text.length - 1, 1)];
        }
        self.hidden = NO;
    });
}
@end

// ==================== 工具函数实现 ====================

static NSString *getControlEventName(UIControlEvents e) {
    switch (e) {
        case UIControlEventTouchDown:           return @"TouchDown";
        case UIControlEventTouchDownRepeat:     return @"TouchDownRepeat";
        case UIControlEventTouchDragInside:     return @"DragInside";
        case UIControlEventTouchDragOutside:    return @"DragOutside";
        case UIControlEventTouchUpInside:       return @"TouchUpInside";
        case UIControlEventTouchUpOutside:      return @"TouchUpOutside";
        case UIControlEventTouchCancel:         return @"TouchCancel";
        case UIControlEventValueChanged:        return @"ValueChanged";
        case UIControlEventPrimaryActionTriggered: return @"PrimaryAction";
        case UIControlEventEditingDidBegin:     return @"EditingBegin";
        case UIControlEventEditingDidEnd:       return @"EditingEnd";
        default: return [NSString stringWithFormat:@"Evt%lu", (unsigned long)e];
    }
}

static void saveToFile(NSString *log) {
    @try {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        if (paths.count == 0) return;
        NSString *path = [paths[0] stringByAppendingPathComponent:@"AdInspector_Logs.txt"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [[NSData data] writeToFile:path atomically:YES];
        }
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:[log dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    } @catch (NSException *e) {
        NSLog(@"[AdInspector] 写入失败: %@", e);
    }
}

static void highlightView(UIView *view) {
    if (!view) return;
    UIColor *oldColor = nil;
    CGColorRef oldCG = view.layer.borderColor;
    if (oldCG != NULL) {
        oldColor = [UIColor colorWithCGColor:oldCG];
    }
    CGFloat oldWidth = view.layer.borderWidth;

    view.layer.borderColor = [UIColor redColor].CGColor;
    view.layer.borderWidth = 3.0;

    __weak UIView *wv = view;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong UIView *sv = wv;
        if (sv) {
            sv.layer.borderColor = oldColor ? oldColor.CGColor : NULL;
            sv.layer.borderWidth = oldWidth;
        }
    });
}

static void analyzeTouchView(UIView *view, CGPoint point) {
    if (!view) return;
    NSDate *now = [NSDate date];
    if (s_lastAnalysisTime && [now timeIntervalSinceDate:s_lastAnalysisTime] < kMinAnalysisInterval) {
        return;
    }
    s_lastAnalysisTime = now;

    @try {
        NSMutableString *out = [NSMutableString string];
        [out appendFormat:@"\n══════ %@ ══════\n",
         [NSDateFormatter localizedStringFromDate:now dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle]];

        [out appendString:@"📊 视图层级链:\n"];
        UIView *cur = view;
        int depth = 0;
        while (cur && depth < 15) {
            NSString *indent = [@"" stringByPaddingToLength:depth*2 withString:@" " startingAtIndex:0];
            [out appendFormat:@"%@▸ %@", indent, NSStringFromClass([cur class])];
            NSMutableArray *tags = [NSMutableArray array];
            if (cur.tag != 0) [tags addObject:[NSString stringWithFormat:@"tag:%ld", (long)cur.tag]];
            if ([cur isKindOfClass:[UIButton class]]) {
                NSString *t = [(UIButton *)cur titleForState:UIControlStateNormal];
                if (t.length) [tags addObject:[NSString stringWithFormat:@"\"%@\"", t]];
            }
            if ([cur isKindOfClass:[UILabel class]]) {
                NSString *t = [(UILabel *)cur text];
                if (t.length > 20) t = [[t substringToIndex:20] stringByAppendingString:@"..."];
                if (t.length) [tags addObject:[NSString stringWithFormat:@"\"%@\"", t]];
            }
            if (cur.accessibilityLabel.length) {
                [tags addObject:[NSString stringWithFormat:@"a11y:\"%@\"", cur.accessibilityLabel]];
            }
            if (tags.count) {
                [out appendFormat:@" [%@]", [tags componentsJoinedByString:@", "]];
            }
            [out appendFormat:@"\n%@  %@\n", indent, NSStringFromCGRect(cur.frame)];
            cur = cur.superview;
            depth++;
        }

        [out appendString:@"\n🎯 Target-Action & 手势:\n"];
        BOOL found = NO;
        cur = view;
        depth = 0;
        while (cur && depth < 8) {
            if ([cur isKindOfClass:[UIControl class]]) {
                UIControl *c = (UIControl *)cur;
                for (id tgt in c.allTargets) {
                    UIControlEvents checkEvents[] = {
                        UIControlEventTouchUpInside,
                        UIControlEventTouchDown,
                        UIControlEventValueChanged,
                        UIControlEventPrimaryActionTriggered
                    };
                    for (int i = 0; i < 4; i++) {
                        NSArray *acts = [c actionsForTarget:tgt forControlEvent:checkEvents[i]];
                        if (acts.count) {
                            found = YES;
                            [out appendFormat:@"  [%@] → %@.%@ (%@)\n",
                             NSStringFromClass([cur class]),
                             NSStringFromClass([tgt class]),
                             acts[0],
                             getControlEventName(checkEvents[i])];
                        }
                    }
                }
            }
            for (UIGestureRecognizer *gr in cur.gestureRecognizers) {
                found = YES;
                [out appendFormat:@"  [%@] 手势:%@ (en:%d ct:%d)\n",
                 NSStringFromClass([cur class]),
                 NSStringFromClass([gr class]),
                 gr.enabled,
                 gr.cancelsTouchesInView];
                @try {
                    if ([gr respondsToSelector:NSSelectorFromString(@"_targets")]) {
                        NSArray *tgts = [gr valueForKey:@"_targets"];
                        for (id t in tgts) {
                            [out appendFormat:@"    → %@\n", t];
                        }
                    }
                } @catch (...) {}
            }
            cur = cur.superview;
            depth++;
        }
        if (!found) [out appendString:@"  (未检测到绑定)\n"];

        [out appendString:@"\n🔍 诊断信息:\n"];
        [out appendFormat:@"  类: %@\n", NSStringFromClass([view class])];
        [out appendFormat:@"  frame: %@\n", NSStringFromCGRect(view.frame)];
        [out appendFormat:@"  bounds: %@\n", NSStringFromCGRect(view.bounds)];
        [out appendFormat:@"  userInteraction:%d hidden:%d alpha:%.2f\n",
         view.userInteractionEnabled, view.hidden, view.alpha];
        [out appendFormat:@"  backgroundColor: %@\n", view.backgroundColor ?: @"nil"];
        if (view.gestureRecognizers.count) {
            [out appendString:@"  视图手势: "];
            for (UIGestureRecognizer *gr in view.gestureRecognizers) {
                [out appendFormat:@"%@ ", NSStringFromClass([gr class])];
            }
            [out appendString:@"\n"];
        }
        [out appendString:@"  响应链: "];
        UIResponder *r = view.nextResponder;
        int rc = 0;
        while (r && rc < 6) {
            [out appendFormat:@"→%@ ", NSStringFromClass([r class])];
            r = r.nextResponder;
            rc++;
        }
        [out appendString:@"\n══════════════════════════\n"];

        [[AdInspectorWindow shared] showLog:out];
        saveToFile(out);
        highlightView(view);
    } @catch (NSException *e) {
        NSLog(@"[AdInspector] 分析异常: %@", e);
    }
}

// ==================== 自动跳过广告 ====================
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

static void autoCheckAndSkipAd(void) {
    // 适配 iOS 15+，避免使用废弃的 [UIApplication sharedApplication].windows
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) {
            if ([window isKindOfClass:NSClassFromString(@"BDNCSplashAdvertiseBaseWindow")]) {
                UIButton *skipBtn = findSkipButtonInView(window);
                if (skipBtn && skipBtn.userInteractionEnabled && !skipBtn.hidden) {
                    NSLog(@"[AutoSkip] 自动跳过广告: %@", skipBtn.titleLabel.text);
                    [skipBtn sendActionsForControlEvents:UIControlEventTouchUpInside];
                }
            }
        }
    }
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

// ==================== 初始化 ====================
%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [AdInspectorWindow shared];
        NSLog(@"[AdInspector] ✅ 已激活 - 自动跳过广告 + 分析点击");

        // 每 0.5 秒扫描一次广告窗口
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
