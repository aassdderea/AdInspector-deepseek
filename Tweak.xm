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
static UIView *findSkipLabelInView(UIView *root);

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

// ==================== 独立悬浮窗（永不消失） ====================
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
        if (tag >= 1001 && tag <= 1006) return check;
        check = check.superview;
    }
    return nil;
}

- (void)setHidden:(BOOL)hidden {
    if (hidden && !self.isHidden) {
        NSLog(@"[AdInspectorWindow] 拒绝隐藏调用");
        return;
    }
    [super setHidden:hidden];
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

        UIButton *viewBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        viewBtn.frame = CGRectMake(self.bounds.size.width - 135, 3, 45, 30);
        [viewBtn setTitle:@"查看" forState:UIControlStateNormal];
        [viewBtn setTitleColor:[UIColor yellowColor] forState:UIControlStateNormal];
        viewBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
        viewBtn.tag = 1006;
        [viewBtn addTarget:self action:@selector(viewRulesTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:viewBtn];

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

- (void)viewRulesTapped {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSArray *rules = [ud arrayForKey:kRulesKey];
    if (rules.count == 0) {
        [self showLog:@"\n📋 当前无已保存规则\n"];
    } else {
        NSMutableString *out = [NSMutableString stringWithFormat:@"\n📋 已保存规则 (%lu条):\n", (unsigned long)rules.count];
        for (NSInteger i = 0; i < rules.count; i++) {
            NSDictionary *rule = rules[i];
            [out appendFormat:@"\n规则%ld: %@ \"%@\" 触发:%@ 容器:%@ 目标:%@.%@\n层级链:%@\n",
             (long)i+1,
             rule[@"buttonClass"],
             rule[@"buttonTextPattern"],
             rule[@"triggerType"] ?: @"未知",
             rule[@"containerClass"] ?: @"未知",
             rule[@"targetClass"] ?: @"-",
             rule[@"actionSelector"] ?: @"-",
             [rule[@"hierarchyChain"] componentsJoinedByString:@" → "]];
        }
        [self showLog:out];
    }
}

- (void)forceShow {
    if (!s_floatWindow) {
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
    showToast(@"👆 面板已呼出");
    [self viewRulesTapped];
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
static NSString *getControlEventName(UIControlEvents e) {
    switch (e) {
        case UIControlEventTouchDown: return @"TouchDown";
        case UIControlEventTouchDownRepeat: return @"TouchDownRepeat";
        case UIControlEventTouchDragInside: return @"DragInside";
        case UIControlEventTouchDragOutside: return @"DragOutside";
        case UIControlEventTouchUpInside: return @"TouchUpInside";
        case UIControlEventTouchUpOutside: return @"TouchUpOutside";
        case UIControlEventTouchCancel: return @"TouchCancel";
        case UIControlEventValueChanged: return @"ValueChanged";
        case UIControlEventPrimaryActionTriggered: return @"PrimaryAction";
        case UIControlEventEditingDidBegin: return @"EditingBegin";
        case UIControlEventEditingDidEnd: return @"EditingEnd";
        default: return [NSString stringWithFormat:@"Evt%lu", (unsigned long)e];
    }
}

static void saveToFile(NSString *log) { /* 同上，略 */ }
static void highlightView(UIView *view) { /* 同上，略 */ }

// ==================== 规则管理 ====================
static void saveRule(NSDictionary *rule) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSArray *existing = [ud arrayForKey:kRulesKey] ?: @[];
    for (NSDictionary *r in existing) {
        if ([r[@"buttonClass"] isEqualToString:rule[@"buttonClass"]] &&
            [r[@"buttonTextPattern"] isEqualToString:rule[@"buttonTextPattern"]] &&
            [r[@"hierarchyChain"] isEqualToArray:rule[@"hierarchyChain"]]) {
            showToast(@"规则已存在，无需重复学习");
            return;
        }
    }
    NSMutableArray *newRules = [existing mutableCopy];
    [newRules addObject:rule];
    [ud setObject:newRules forKey:kRulesKey];
    [ud synchronize];
    showToast([NSString stringWithFormat:@"✅ 已学习：%@", rule[@"buttonTextPattern"]]);
}

static UIView *findMatchingView(UIView *root, NSDictionary *rule) {
    if ([root isKindOfClass:[AdInspectorPanel class]] || 
        [root.window isKindOfClass:[AdInspectorWindow class]]) {
        return nil;
    }
    NSString *targetClass = rule[@"buttonClass"];
    NSString *textPattern = rule[@"buttonTextPattern"];
    NSArray *chain = rule[@"hierarchyChain"];

    if ([NSStringFromClass([root class]) isEqualToString:targetClass]) {
        NSString *currentText = nil;
        if ([root isKindOfClass:[UIButton class]]) currentText = [(UIButton *)root titleForState:UIControlStateNormal];
        else if ([root isKindOfClass:[UILabel class]]) currentText = [(UILabel *)root text] ?: [(UILabel *)root attributedText].string;
        else currentText = root.accessibilityLabel;

        if (currentText) {
            BOOL textMatches = NO;
            if (textPattern.length <= 2) {
                textMatches = [currentText isEqualToString:textPattern];
            } else {
                textMatches = ([currentText rangeOfString:textPattern].location != NSNotFound && currentText.length <= 15);
            }
            if (textMatches) {
                NSMutableArray *currentChain = [NSMutableArray array];
                UIView *cur = root;
                while (cur && ![cur isKindOfClass:[UIWindow class]]) {
                    [currentChain addObject:NSStringFromClass([cur class])];
                    cur = cur.superview;
                }
                if ([currentChain isEqualToArray:chain]) return root;
            }
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
}

// ==================== 自动跳过（恢复为旧版可靠逻辑） ====================
static void triggerSkip(UIView *view, NSDictionary *rule) {
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
                // 强制设置手势状态
                [gr setValue:@(UIGestureRecognizerStateRecognized) forKey:@"state"];
                // 延迟隐藏窗口，确保广告关闭
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    if (!view.window || view.window.hidden) return;
                    // 只隐藏广告窗口，如果窗口是主窗口则尝试移除容器（保护）
                    if (view.window == getKeyWindow()) {
                        // 如果是主窗口，不隐藏，而是移除广告容器
                        UIView *container = view;
                        while (container && ![container isKindOfClass:[UIWindow class]]) {
                            if ([NSStringFromClass([container class]) containsString:@"Splash"] ||
                                [NSStringFromClass([container class]) containsString:@"Root"] ||
                                [NSStringFromClass([container class]) containsString:@"Ad"]) {
                                [container removeFromSuperview];
                                break;
                            }
                            container = container.superview;
                        }
                    } else {
                        view.window.hidden = YES;
                    }
                    showToast(@"⏩ 已强制关闭广告窗口");
                });
                return;
            }
        }
        cur = cur.superview;
    }

    // 最终兜底：隐藏窗口
    if (view.window && view.window != getKeyWindow()) {
        view.window.hidden = YES;
        showToast(@"⏩ 已强制关闭广告窗口");
    }
}

// ==================== 自动跳过扫描 ====================
static void applyAllSavedRules(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSArray *rules = [ud arrayForKey:kRulesKey];
    if (!rules.count) return;

    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in [(UIWindowScene *)scene windows]) {
            if ([window isKindOfClass:[AdInspectorWindow class]]) continue;
            for (NSDictionary *rule in rules) {
                UIView *matched = findMatchingView(window, rule);
                if (matched) {
                    triggerSkip(matched, rule);
                    return;
                }
            }
        }
    }
}

// ==================== 按钮识别 ====================
static BOOL isSkipText(NSString *text) { /* 同上 */ }
static UIView *findSkipLabelInView(UIView *root) { /* 同上 */ }

// ==================== 核心分析 ====================
static void analyzeTouchView(UIView *view, CGPoint point) { /* 同上，完整实现 */ }

// ==================== Hook UIApplication sendEvent: ====================
%hook UIApplication
- (void)sendEvent:(UIEvent *)event { /* 同上 */ }
%end

%hook UIControl
- (void)addTarget:(id)target action:(SEL)action forControlEvents:(UIControlEvents)controlEvents { /* 同上 */ }
%end

%ctor {
    // 初始化代码同上
}
