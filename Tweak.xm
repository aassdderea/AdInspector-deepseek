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

// ==================== 分析防抖 ====================
static NSDate *s_lastAnalysisTime = nil;
static const NSTimeInterval kMinAnalysisInterval = 0.3;

// ==================== 规则存储 Key ====================
static NSString *const kRulesKey = @"AdInspector_SkipRules";

// ==================== 悬浮窗（触摸穿透） ====================
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
        self.windowLevel = UIWindowLevelAlert + 1000;
        self.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.88];
        self.layer.cornerRadius = 10;
        self.layer.borderWidth = 1.5;
        self.layer.borderColor = [UIColor cyanColor].CGColor;
        self.hidden = NO;
        self.userInteractionEnabled = YES;
        self.clipsToBounds = NO;

        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, 120, 20)];
        title.text = @"🔍 AdInspector";
        title.textColor = [UIColor cyanColor];
        title.font = [UIFont boldSystemFontOfSize:14];
        title.tag = 1001;
        [self addSubview:title];

        UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
        close.frame = CGRectMake(self.bounds.size.width - 45, 3, 40, 30);
        [close setTitle:@"✕" forState:UIControlStateNormal];
        [close setTitleColor:[UIColor redColor] forState:UIControlStateNormal];
        close.titleLabel.font = [UIFont boldSystemFontOfSize:20];
        close.tag = 1002;
        [close addTarget:self action:@selector(hideSelf) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:close];

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

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hitView = [super hitTest:point withEvent:event];
    if (hitView == self) return nil;
    while (hitView && hitView != self) {
        NSInteger tag = hitView.tag;
        if (tag >= 1001 && tag <= 1005) return hitView;
        hitView = hitView.superview;
    }
    return nil;
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint t = [pan translationInView:self];
    self.center = CGPointMake(self.center.x + t.x, self.center.y + t.y);
    [pan setTranslation:CGPointZero inView:self];
}

- (void)hideSelf { self.hidden = YES; }

- (void)clearRulesTapped {
    clearAllRules();
    [self showLog:@"\n🗑️ 已清空所有学习规则\n"];
    UIView *toast = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 200, 40)];
    toast.center = CGPointMake(self.bounds.size.width/2, self.bounds.size.height/2);
    toast.backgroundColor = [[UIColor orangeColor] colorWithAlphaComponent:0.9];
    toast.layer.cornerRadius = 8;
    UILabel *label = [[UILabel alloc] initWithFrame:toast.bounds];
    label.text = @"规则已清除";
    label.textColor = [UIColor whiteColor];
    label.textAlignment = NSTextAlignmentCenter;
    label.font = [UIFont boldSystemFontOfSize:14];
    [toast addSubview:label];
    [self addSubview:toast];
    [UIView animateWithDuration:0.3 delay:1.0 options:0 animations:^{ toast.alpha = 0; } completion:^(BOOL finished) { [toast removeFromSuperview]; }];
}

- (void)showLog:(NSString *)log {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.logBuffer appendString:log];
        if (self.logBuffer.length > 8000) [self.logBuffer deleteCharactersInRange:NSMakeRange(0, self.logBuffer.length - 8000)];
        self.logTextView.text = self.logBuffer;
        if (self.logTextView.text.length > 0) [self.logTextView scrollRangeToVisible:NSMakeRange(self.logTextView.text.length - 1, 1)];
        self.hidden = NO;
    });
}
@end

// ==================== Toast ====================
static void showToast(NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        AdInspectorWindow *inspector = [AdInspectorWindow shared];
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
        CGFloat w = textRect.size.width + 30;
        CGFloat h = textRect.size.height + 16;
        label.frame = CGRectMake(15, 8, textRect.size.width, textRect.size.height);
        CGPoint screenCenter = CGPointMake([UIScreen mainScreen].bounds.size.width/2, [UIScreen mainScreen].bounds.size.height - 150);
        CGPoint centerInWindow = [inspector convertPoint:screenCenter fromView:nil];
        toast.frame = CGRectMake(centerInWindow.x - w/2, centerInWindow.y - h/2, w, h);
        [inspector addSubview:toast];
        [UIView animateWithDuration:0.3 delay:1.5 options:UIViewAnimationOptionCurveEaseOut animations:^{ toast.alpha = 0; } completion:^(BOOL finished) { [toast removeFromSuperview]; }];
    });
}

// ==================== 工具函数 ====================
static NSString *getControlEventName(UIControlEvents e) { /* 不变 */ }

static void saveToFile(NSString *log) { /* 不变 */ }

static void highlightView(UIView *view) { /* 不变 */ }

// ==================== 规则管理 ====================
static void saveRule(NSDictionary *rule) { /* 不变，含去重与Toast */ }

static UIView *findMatchingView(UIView *root, NSDictionary *rule) { /* 不变 */ }

static void clearAllRules(void) { /* 不变 */ }

// ==================== 增强后的 triggerSkip（支持动态手势解析） ====================
static void triggerSkip(UIView *view, NSDictionary *rule) {
    NSString *triggerType = rule[@"triggerType"];
    if ([triggerType isEqualToString:@"controlEvent"]) {
        if ([view isKindOfClass:[UIControl class]]) {
            UIControlEvents events = [rule[@"controlEvent"] unsignedIntegerValue];
            [(UIControl *)view sendActionsForControlEvents:events];
            showToast(@"⏩ 已自动跳过");
        }
    } else if ([triggerType isEqualToString:@"gesture"]) {
        NSString *gestureClass = rule[@"gestureClass"];
        NSString *actionStr = rule[@"actionSelector"];
        NSString *targetClass = rule[@"targetClass"];
        NSString *gestureViewClass = rule[@"gestureViewClass"];

        // 优先使用已保存的 target/action
        if (actionStr && targetClass) {
            SEL action = NSSelectorFromString(actionStr);
            UIView *cur = view;
            while (cur) {
                for (UIGestureRecognizer *gr in cur.gestureRecognizers) {
                    if ([NSStringFromClass([gr class]) isEqualToString:gestureClass]) {
                        @try {
                            NSArray *tgts = [gr valueForKey:@"_targets"];
                            for (id t in tgts) {
                                id target = [t valueForKey:@"_target"];
                                if ([NSStringFromClass([target class]) isEqualToString:targetClass]) {
                                    ((void (*)(id, SEL, id))objc_msgSend)(target, action, gr);
                                    showToast(@"⏩ 已自动跳过");
                                    return;
                                }
                            }
                        } @catch (NSException *e) {}
                    }
                }
                cur = cur.superview;
            }
        }

        // 动态解析：重新查找并触发手势（通用 fallback）
        UIView *cur = view;
        while (cur) {
            for (UIGestureRecognizer *gr in cur.gestureRecognizers) {
                if ([NSStringFromClass([gr class]) isEqualToString:gestureClass] &&
                    (!gestureViewClass || [NSStringFromClass([cur class]) isEqualToString:gestureViewClass])) {
                    // 动态尝试触发
                    @try {
                        NSArray *tgts = [gr valueForKey:@"_targets"];
                        for (id t in tgts) {
                            id target = [t valueForKey:@"_target"];
                            id actionObj = [t valueForKey:@"_action"];
                            SEL action = NULL;
                            if ([actionObj isKindOfClass:[NSString class]]) {
                                action = NSSelectorFromString(actionObj);
                            } else if ([actionObj isKindOfClass:[NSValue class]]) {
                                action = (SEL)[actionObj pointerValue];
                            }
                            if (target && action) {
                                ((void (*)(id, SEL, id))objc_msgSend)(target, action, gr);
                                showToast(@"⏩ 已自动跳过 (动态)");
                                return;
                            }
                        }
                    } @catch (NSException *e) {}
                }
            }
            cur = cur.superview;
        }
    }
}

// ==================== applyAllSavedRules 保持不变 ====================
static void applyAllSavedRules(void) { /* 不变 */ }

// ==================== 核心分析（强化手势解析 + 万能fallback） ====================
static void analyzeTouchView(UIView *view, CGPoint point) {
    if (!view) return;
    NSDate *now = [NSDate date];
    if (s_lastAnalysisTime && [now timeIntervalSinceDate:s_lastAnalysisTime] < kMinAnalysisInterval) return;
    s_lastAnalysisTime = now;

    @try {
        // ---- 构建输出与层级链 ----
        NSMutableString *out = [NSMutableString string];
        [out appendFormat:@"\n══════ %@ ══════\n",
         [NSDateFormatter localizedStringFromDate:now dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle]];

        NSMutableArray *chainArray = [NSMutableArray array];
        UIView *cur = view;
        while (cur && ![cur isKindOfClass:[UIWindow class]]) {
            [chainArray addObject:NSStringFromClass([cur class])];
            cur = cur.superview;
        }
        NSString *windowClass = cur ? NSStringFromClass([cur class]) : @"";

        [out appendString:@"📊 视图层级链:\n"];
        cur = view;
        int depth = 0;
        while (cur && depth < 15) {
            // ... 层级输出（略，与之前一致）
        }

        // ---- Target-Action 与手势解析（重点增强） ----
        [out appendString:@"\n🎯 Target-Action & 手势:\n"];
        BOOL found = NO;
        NSMutableArray *taInfo = [NSMutableArray array];
        cur = view;
        depth = 0;
        while (cur && depth < 8) {
            // UIControl 解析（不变）
            // ...

            // 手势解析增强
            for (UIGestureRecognizer *gr in cur.gestureRecognizers) {
                found = YES;
                [out appendFormat:@"  [%@] 手势:%@ (en:%d ct:%d)\n",
                 NSStringFromClass([cur class]),
                 NSStringFromClass([gr class]),
                 gr.enabled, gr.cancelsTouchesInView];
                // 尝试获取 _targets
                BOOL gotTargetInfo = NO;
                if ([gr respondsToSelector:@selector(_targets)]) {
                    NSArray *tgts = [gr valueForKey:@"_targets"];
                    if (tgts && [tgts isKindOfClass:[NSArray class]]) {
                        for (id t in tgts) {
                            id target = [t valueForKey:@"_target"];
                            id actionObj = [t valueForKey:@"_action"];
                            NSString *actionStr = nil;
                            if ([actionObj isKindOfClass:[NSString class]]) {
                                actionStr = actionObj;
                            } else if ([actionObj respondsToSelector:@selector(selector)]) {
                                actionStr = NSStringFromSelector([actionObj selector]);
                            } else if ([actionObj isKindOfClass:[NSValue class]]) {
                                actionStr = NSStringFromSelector((SEL)[actionObj pointerValue]);
                            }
                            if (target && actionStr) {
                                [out appendFormat:@"    → %@.%@\n", NSStringFromClass([target class]), actionStr];
                                [taInfo addObject:@{
                                    @"viewClass": NSStringFromClass([cur class]),
                                    @"gestureClass": NSStringFromClass([gr class]),
                                    @"targetClass": NSStringFromClass([target class]),
                                    @"action": actionStr
                                }];
                                gotTargetInfo = YES;
                            } else {
                                [out appendFormat:@"    → (目标:%@ 动作:%@)\n", target, actionObj];
                            }
                        }
                    }
                }
                if (!gotTargetInfo) {
                    [out appendString:@"    (无法提取 target/action，将使用备用规则)\n"];
                }
            }
            cur = cur.superview;
            depth++;
        }

        // ---- 诊断信息与输出 ----
        // ... 不变

        // ---- 学习规则 ----
        NSString *buttonText = nil;
        if ([view isKindOfClass:[UIButton class]]) {
            buttonText = [(UIButton *)view titleForState:UIControlStateNormal];
        } else if ([view isKindOfClass:[UILabel class]]) {
            buttonText = [(UILabel *)view text];
        }
        if (!buttonText) buttonText = @"";

        NSMutableDictionary *rule = [NSMutableDictionary dictionary];
        rule[@"buttonClass"] = NSStringFromClass([view class]);
        rule[@"buttonTextPattern"] = buttonText;
        rule[@"hierarchyChain"] = chainArray;
        rule[@"windowClass"] = windowClass;

        BOOL hasRule = NO;
        // 优先控件事件
        for (NSDictionary *info in taInfo) {
            if (info[@"event"] && [info[@"event"] unsignedIntegerValue] == UIControlEventTouchUpInside) {
                rule[@"triggerType"] = @"controlEvent";
                rule[@"controlEvent"] = @(UIControlEventTouchUpInside);
                hasRule = YES;
                break;
            }
        }
        // 其次明确的手势 target/action
        if (!hasRule) {
            for (NSDictionary *info in taInfo) {
                if (info[@"gestureClass"] && info[@"targetClass"] && info[@"action"]) {
                    rule[@"triggerType"] = @"gesture";
                    rule[@"gestureClass"] = info[@"gestureClass"];
                    rule[@"targetClass"] = info[@"targetClass"];
                    rule[@"actionSelector"] = info[@"action"];
                    if (info[@"viewClass"]) rule[@"gestureViewClass"] = info[@"viewClass"];
                    hasRule = YES;
                    break;
                }
            }
        }
        // 万能备用：记录最近一个手势的类名和所在视图
        if (!hasRule) {
            cur = view;
            while (cur && !hasRule) {
                for (UIGestureRecognizer *gr in cur.gestureRecognizers) {
                    rule[@"triggerType"] = @"gesture";
                    rule[@"gestureClass"] = NSStringFromClass([gr class]);
                    rule[@"gestureViewClass"] = NSStringFromClass([cur class]);
                    hasRule = YES;
                    break;
                }
                cur = cur.superview;
            }
        }
        // 最终兜底：如果按钮本身是 UIControl
        if (!hasRule && [view isKindOfClass:[UIControl class]]) {
            rule[@"triggerType"] = @"controlEvent";
            rule[@"controlEvent"] = @(UIControlEventTouchUpInside);
            hasRule = YES;
        }

        if (hasRule) {
            saveRule(rule);
        } else {
            showToast(@"❌ 无法识别触发方式，未学习");
        }
    } @catch (NSException *e) {
        NSLog(@"[AdInspector] 分析异常: %@", e);
    }
}

// ==================== Hook UIApplication sendEvent: ====================
%hook UIApplication
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

%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [AdInspectorWindow shared];
        showToast(@"🔍 AdInspector 已激活");
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
            applyAllSavedRules();
        }];
        // 日志初始化...
    });
}
