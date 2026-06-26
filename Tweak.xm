#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ==================== 前置声明 ====================
static NSString *getControlEventName(UIControlEvents event);
static void saveToFile(NSString *log);
static void analyzeTouchView(UIView *view, CGPoint touchPoint);
static void highlightView(UIView *view);
static void saveRule(NSDictionary *rule);
static void applyAllSavedRules(void);
static UIView *findMatchingView(UIView *root, NSDictionary *rule);
static void triggerSkip(UIView *view, NSDictionary *rule);
static void clearAllRules(void);
static void showToast(NSString *message);
static UIWindow *getKeyWindow(void);

// ==================== 分析防抖 ====================
static NSDate *s_lastAnalysisTime = nil;
static const NSTimeInterval kMinAnalysisInterval = 0.3;

// ==================== 双指长按呼出面板 ====================
static NSDate *s_twoFingerStart = nil;
static const NSTimeInterval kTwoFingerHoldDuration = 0.5;
static NSDate *s_ignoreSingleTouchUntil = nil;

// ==================== 规则存储 Key ====================
static NSString *const kRulesKey = @"AdInspector_SkipRules";

// ==================== 获取 keyWindow ====================
static UIWindow *getKeyWindow(void) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            for (UIWindow *window in windowScene.windows) {
                if (window.isKeyWindow) return window;
            }
        }
    }
    return nil;
}

// ==================== 独立悬浮窗 ====================
@class AdInspectorPanel;
@interface AdInspectorWindow : UIWindow
@property (nonatomic, weak) AdInspectorPanel *panel;
@end

static AdInspectorWindow *s_floatWindow = nil;

@implementation AdInspectorWindow

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.windowLevel = CGFLOAT_MAX;
        self.backgroundColor = [UIColor clearColor];
        self.hidden = NO;
        self.userInteractionEnabled = YES;
        s_floatWindow = self;
    }
    return self;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hitView = [super hitTest:point withEvent:event];
    if (hitView == self || (id)hitView == (id)self.panel) {
        return nil;
    }
    UIView *check = hitView;
    while (check && (id)check != (id)self.panel) {
        NSInteger tag = check.tag;
        if (tag >= 1001 && tag <= 1005) return check;
        check = check.superview;
    }
    return nil;
}

- (void)setHidden:(BOOL)hidden {
    if (!hidden || self.isHidden) {
        [super setHidden:hidden];
    }
    // 禁止其他逻辑隐藏本窗口
    if (hidden) {
        [super setHidden:NO];
    }
}
@end

// ==================== 悬浮面板 ====================
@interface AdInspectorPanel : UIView
@property (nonatomic, strong) UITextView *logTextView;
@property (nonatomic, strong) NSMutableString *logBuffer;
+ (instancetype)shared;
- (void)showLog:(NSString *)log;
- (void)forceShow;
- (void)hidePanel;
@end

@implementation AdInspectorPanel

+ (instancetype)shared {
    static AdInspectorPanel *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AdInspectorPanel alloc] initWithFrame:CGRectMake(5, 160, [UIScreen mainScreen].bounds.size.width - 10, 280)];
    });
    return instance;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.88];
        self.layer.cornerRadius = 10;
        self.layer.borderWidth = 1.5;
        self.layer.borderColor = [UIColor cyanColor].CGColor;
        self.userInteractionEnabled = YES;
        self.clipsToBounds = NO;
        self.hidden = YES;

        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, 120, 20)];
        title.text = @"🔍 AdInspector";
        title.textColor = [UIColor cyanColor];
        title.font = [UIFont boldSystemFontOfSize:14];
        title.tag = 1001;
        [self addSubview:title];

        UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        closeBtn.frame = CGRectMake(self.bounds.size.width - 45, 3, 40, 30);
        [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
        [closeBtn setTitleColor:[UIColor redColor] forState:UIControlStateNormal];
        closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:20];
        closeBtn.tag = 1002;
        [closeBtn addTarget:self action:@selector(hidePanel) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:closeBtn];

        UIButton *clearBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        clearBtn.frame = CGRectMake(self.bounds.size.width - 90, 3, 45, 30);
        [clearBtn setTitle:@"清空" forState:UIControlStateNormal];
        [clearBtn setTitleColor:[UIColor orangeColor] forState:UIControlStateNormal];
        clearBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
        clearBtn.tag = 1003;
        [clearBtn addTarget:self action:@selector(clearRulesTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:clearBtn];

        UIView *handle = [[UIView alloc] initWithFrame:CGRectMake(self.bounds.size.width/2 - 15, 4, 30, 4)];
        handle.backgroundColor = [UIColor colorWithWhite:0.4 alpha:0.6];
        handle.layer.cornerRadius = 2;
        handle.tag = 1004;
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
        self.logTextView.tag = 1005;
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

- (void)hidePanel { self.hidden = YES; }

- (void)clearRulesTapped {
    clearAllRules();
    [self showLog:@"\n🗑️ 已清空所有学习规则\n"];
    showToast(@"🗑️ 规则已清除");
}

- (void)forceShow {
    if (!s_floatWindow) {
        // 尝试重新创建浮动窗口
        UIWindowScene *activeScene = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
                activeScene = (UIWindowScene *)scene;
                break;
            }
        }
        if (activeScene) {
            s_floatWindow = [[AdInspectorWindow alloc] initWithFrame:activeScene.coordinateSpace.bounds];
            s_floatWindow.windowScene = activeScene;
            [s_floatWindow addSubview:self];
            self.frame = CGRectMake(5, 160, s_floatWindow.bounds.size.width - 10, 280);
            self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
            s_floatWindow.panel = self;
            s_floatWindow.hidden = NO;
        }
    } else {
        if (!self.superview) {
            [s_floatWindow addSubview:self];
            self.frame = CGRectMake(5, 160, s_floatWindow.bounds.size.width - 10, 280);
            self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
            s_floatWindow.panel = self;
        }
        s_floatWindow.hidden = NO;
        s_floatWindow.alpha = 1.0;
        [s_floatWindow bringSubviewToFront:self];
    }
    self.hidden = NO;
    self.alpha = 1.0;
    NSLog(@"[AdInspector] 面板已呼出");
    showToast(@"👆 面板已呼出");
}

- (void)showLog:(NSString *)log {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.logBuffer appendString:log];
        if (self.logBuffer.length > 8000) [self.logBuffer deleteCharactersInRange:NSMakeRange(0, self.logBuffer.length - 8000)];
        self.logTextView.text = self.logBuffer;
        if (self.logTextView.text.length > 0) [self.logTextView scrollRangeToVisible:NSMakeRange(self.logTextView.text.length - 1, 1)];
    });
}
@end

// ==================== Toast ====================
static void showToast(NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *hostWindow = getKeyWindow();
        if (!hostWindow) return;

        UIView *toast = [[UIView alloc] init];
        toast.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
        toast.layer.cornerRadius = 12;
        UILabel *label = [[UILabel alloc] init];
        label.text = message;
        label.textColor = [UIColor whiteColor];
        label.font = [UIFont boldSystemFontOfSize:14];
        label.numberOfLines = 0;
        label.textAlignment = NSTextAlignmentCenter;
        [toast addSubview:label];
        CGSize maxSize = CGSizeMake([UIScreen mainScreen].bounds.size.width - 60, CGFLOAT_MAX);
        CGRect textRect = [message boundingRectWithSize:maxSize options:NSStringDrawingUsesLineFragmentOrigin attributes:@{NSFontAttributeName: label.font} context:nil];
        CGFloat w = textRect.size.width + 30, h = textRect.size.height + 16;
        label.frame = CGRectMake(15, 8, textRect.size.width, textRect.size.height);
        CGPoint center = CGPointMake(hostWindow.bounds.size.width/2, hostWindow.bounds.size.height - 150);
        toast.frame = CGRectMake(center.x - w/2, center.y - h/2, w, h);
        toast.layer.zPosition = CGFLOAT_MAX;
        [hostWindow addSubview:toast];

        [UIView animateWithDuration:0.3 delay:1.5 options:UIViewAnimationOptionCurveEaseOut animations:^{
            toast.alpha = 0;
        } completion:^(BOOL finished) {
            [toast removeFromSuperview];
        }];
    });
}

// ==================== 工具函数 ====================
static NSString *getControlEventName(UIControlEvents e) { /* 不变 */ }
static void saveToFile(NSString *log) { /* 不变 */ }
static void highlightView(UIView *view) { /* 不变 */ }

// ==================== 规则管理 ====================
static void saveRule(NSDictionary *rule) { /* 不变 */ }

static UIView *findMatchingView(UIView *root, NSDictionary *rule) {
    // 排除插件自身的视图
    if ([root isKindOfClass:[AdInspectorPanel class]] || [root.window isKindOfClass:[AdInspectorWindow class]]) {
        return nil;
    }
    // 原始匹配逻辑
    NSString *targetClass = rule[@"buttonClass"];
    NSString *textPattern = rule[@"buttonTextPattern"];
    NSArray *chain = rule[@"hierarchyChain"];

    if ([NSStringFromClass([root class]) isEqualToString:targetClass]) {
        NSString *currentText = nil;
        if ([root isKindOfClass:[UIButton class]]) currentText = [(UIButton *)root titleForState:UIControlStateNormal];
        else if ([root isKindOfClass:[UILabel class]]) currentText = [(UILabel *)root text];
        if (currentText && [currentText hasPrefix:textPattern]) {
            NSMutableArray *currentChain = [NSMutableArray array];
            UIView *cur = root;
            while (cur && ![cur isKindOfClass:[UIWindow class]]) {
                [currentChain addObject:NSStringFromClass([cur class])];
                cur = cur.superview;
            }
            if ([currentChain isEqualToArray:chain]) return root;
        }
    }
    for (UIView *sub in root.subviews) {
        UIView *found = findMatchingView(sub, rule);
        if (found) return found;
    }
    return nil;
}

static void clearAllRules(void) {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kRulesKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    showToast(@"🗑️ 所有规则已清除");
}

// ==================== 自动跳过（排除自身） ====================
static void triggerSkip(UIView *view, NSDictionary *rule) {
    // 绝不跳过插件自身的视图
    if ([view isDescendantOfView:[AdInspectorPanel shared]] ||
        [view.window isKindOfClass:[AdInspectorWindow class]]) {
        return;
    }

    NSString *triggerType = rule[@"triggerType"];
    if ([triggerType isEqualToString:@"controlEvent"]) {
        if ([view isKindOfClass:[UIControl class]]) {
            [(UIControl *)view sendActionsForControlEvents:[rule[@"controlEvent"] unsignedIntegerValue]];
            showToast(@"⏩ 已自动跳过");
            return;
        }
    }

    NSString *gestureClass = rule[@"gestureClass"];
    UIView *cur = view;
    while (cur) {
        for (UIGestureRecognizer *gr in cur.gestureRecognizers) {
            if ([NSStringFromClass([gr class]) isEqualToString:gestureClass]) {
                if (rule[@"targetClass"] && rule[@"actionSelector"]) {
                    SEL action = NSSelectorFromString(rule[@"actionSelector"]);
                    @try {
                        NSArray *tgts = [gr valueForKey:@"_targets"];
                        for (id t in tgts) {
                            id target = [t valueForKey:@"_target"];
                            if ([NSStringFromClass([target class]) isEqualToString:rule[@"targetClass"]]) {
                                ((void (*)(id, SEL, id))objc_msgSend)(target, action, gr);
                                showToast(@"⏩ 已自动跳过");
                                return;
                            }
                        }
                    } @catch (NSException *e) {}
                }
                [gr setValue:@(UIGestureRecognizerStateRecognized) forKey:@"state"];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    if (!view.window || view.window.hidden) return;
                    view.window.hidden = YES;
                    showToast(@"⏩ 已强制关闭广告窗口");
                });
                return;
            }
        }
        cur = cur.superview;
    }

    if (view.window) {
        view.window.hidden = YES;
        showToast(@"⏩ 已强制关闭广告窗口");
    }
}

static void applyAllSavedRules(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSArray *rules = [ud arrayForKey:kRulesKey];
    if (!rules.count) return;

    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in [(UIWindowScene *)scene windows]) {
            // 跳过插件自己的窗口，避免误伤
            if ([window isKindOfClass:[AdInspectorWindow class]]) continue;

            for (NSDictionary *rule in rules) {
                UIView *matched = findMatchingView(window, rule);
                if (matched) {
                    NSLog(@"[AutoSkip] 规则命中，自动跳过");
                    triggerSkip(matched, rule);
                    return;
                }
            }
        }
    }
}

// ==================== 辅助查找“跳过”文字 ====================
static UIView *findSkipLabelInView(UIView *root) {
    if ([root isKindOfClass:[AdInspectorPanel class]]) return nil;
    if ([root isKindOfClass:[UIButton class]]) {
        NSString *t = [(UIButton *)root titleForState:UIControlStateNormal];
        if (t && [t hasPrefix:@"跳过"]) return root;
    }
    if ([root isKindOfClass:[UILabel class]]) {
        NSString *t = [(UILabel *)root text];
        if (t && [t hasPrefix:@"跳过"]) return root;
    }
    for (UIView *sub in root.subviews) {
        UIView *found = findSkipLabelInView(sub);
        if (found) return found;
    }
    return nil;
}

// ==================== 核心分析 ====================
static void analyzeTouchView(UIView *view, CGPoint point) { /* 保持不变，省略具体实现与前面一致 */ }

// ==================== Hook UIApplication sendEvent: ====================
%hook UIApplication
- (void)sendEvent:(UIEvent *)event {
    %orig;
    if (event.type == UIEventTypeTouches) {
        NSSet *touches = [event allTouches];

        // 双指长按呼出面板
        if (touches.count >= 2) {
            BOOL allStationary = YES;
            for (UITouch *t in touches) {
                if (t.phase == UITouchPhaseEnded || t.phase == UITouchPhaseCancelled) {
                    allStationary = NO; break;
                }
            }
            if (allStationary && !s_twoFingerStart) {
                s_twoFingerStart = [NSDate date];
            }
            if (s_twoFingerStart && [[NSDate date] timeIntervalSinceDate:s_twoFingerStart] >= kTwoFingerHoldDuration) {
                AdInspectorPanel *panel = [AdInspectorPanel shared];
                if (panel.hidden) {
                    [panel forceShow];
                }
                s_twoFingerStart = nil;
                s_ignoreSingleTouchUntil = [NSDate dateWithTimeIntervalSinceNow:0.5];
            }
        } else {
            s_twoFingerStart = nil;
        }

        // 单指分析（抬起且不在冷却期）
        if (touches.count == 1) {
            UITouch *touch = [touches anyObject];
            if (touch.phase == UITouchPhaseEnded && touch.view && !s_twoFingerStart) {
                if (s_ignoreSingleTouchUntil && [[NSDate date] compare:s_ignoreSingleTouchUntil] == NSOrderedAscending) {
                    return;
                }
                analyzeTouchView(touch.view, [touch locationInView:nil]);
            }
        }
    }
}
%end

%hook UIControl
- (void)addTarget:(id)target action:(SEL)action forControlEvents:(UIControlEvents)controlEvents {
    NSLog(@"[AdInspector] 🔗 %@ → %@.%@ [%@]", NSStringFromClass([self class]), NSStringFromClass([target class]), NSStringFromSelector(action), getControlEventName(controlEvents));
    %orig;
}
%end

// ==================== 初始化 ====================
%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindowScene *activeScene = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
                activeScene = (UIWindowScene *)scene;
                break;
            }
        }
        if (activeScene) {
            s_floatWindow = [[AdInspectorWindow alloc] initWithFrame:activeScene.coordinateSpace.bounds];
            s_floatWindow.windowScene = activeScene;
            AdInspectorPanel *panel = [AdInspectorPanel shared];
            panel.frame = CGRectMake(5, 160, s_floatWindow.bounds.size.width - 10, 280);
            panel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
            [s_floatWindow addSubview:panel];
            s_floatWindow.panel = panel;
            s_floatWindow.hidden = NO;
        }

        showToast(@"🔍 已激活 | 点击“跳过”学习 | 双指长按呼出面板");
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
            applyAllSavedRules();
            // 保持窗口最前
            if (s_floatWindow) {
                s_floatWindow.hidden = NO;
                s_floatWindow.alpha = 1.0;
            }
            AdInspectorPanel *panel = [AdInspectorPanel shared];
            if (!panel.hidden && panel.superview) {
                [panel.superview bringSubviewToFront:panel];
            }
        }];
    });
}
