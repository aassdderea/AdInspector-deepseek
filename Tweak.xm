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

// ==================== 分析防抖 ====================
static NSDate *s_lastAnalysisTime = nil;
static const NSTimeInterval kMinAnalysisInterval = 0.3;

// ==================== 规则存储 Key ====================
static NSString *const kRulesKey = @"AdInspector_SkipRules";

// ==================== 悬浮窗（保持最早结构 + 增加清除按钮）====================
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
        self.windowLevel = UIWindowLevelAlert + 999; // 保持与原始一致的层级，足够高但不会阻挡触摸事件
        self.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.88];
        self.layer.cornerRadius = 10;
        self.layer.borderWidth = 1.5;
        self.layer.borderColor = [UIColor cyanColor].CGColor;
        self.hidden = NO;
        self.userInteractionEnabled = YES; // 允许操作悬浮窗上的按钮
        self.clipsToBounds = NO;

        // ---- 标题 ----
        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, 150, 20)];
        title.text = @"🔍 AdInspector";
        title.textColor = [UIColor cyanColor];
        title.font = [UIFont boldSystemFontOfSize:14];
        [self addSubview:title];

        // ---- 关闭按钮 ----
        UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
        close.frame = CGRectMake(self.bounds.size.width - 45, 3, 40, 30);
        [close setTitle:@"✕" forState:UIControlStateNormal];
        [close setTitleColor:[UIColor redColor] forState:UIControlStateNormal];
        close.titleLabel.font = [UIFont boldSystemFontOfSize:20];
        [close addTarget:self action:@selector(hideSelf) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:close];

        // ---- 清除规则按钮（新） ----
        UIButton *clearBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        clearBtn.frame = CGRectMake(self.bounds.size.width - 90, 3, 45, 30);
        [clearBtn setTitle:@"清空" forState:UIControlStateNormal];
        [clearBtn setTitleColor:[UIColor orangeColor] forState:UIControlStateNormal];
        clearBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
        [clearBtn addTarget:self action:@selector(clearRulesTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:clearBtn];

        // ---- 拖动手柄 ----
        UIView *handle = [[UIView alloc] initWithFrame:CGRectMake(self.bounds.size.width/2 - 15, 4, 30, 4)];
        handle.backgroundColor = [UIColor colorWithWhite:0.4 alpha:0.6];
        handle.layer.cornerRadius = 2;
        [self addSubview:handle];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];

        // ---- 日志文本区 ----
        CGFloat tvY = 32;
        self.logTextView = [[UITextView alloc] initWithFrame:CGRectMake(5, tvY, self.bounds.size.width - 10, self.bounds.size.height - tvY - 5)];
        self.logTextView.backgroundColor = [UIColor clearColor];
        self.logTextView.textColor = [UIColor greenColor];
        self.logTextView.font = [UIFont fontWithName:@"Courier" size:10] ?: [UIFont systemFontOfSize:10];
        self.logTextView.editable = NO;
        self.logTextView.selectable = YES;
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

- (void)clearRulesTapped {
    clearAllRules();
    [self showLog:@"\n🗑️ 已清空所有学习规则\n"];
    // 简单Toast提示
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
    [UIView animateWithDuration:0.3 delay:1.0 options:0 animations:^{
        toast.alpha = 0;
    } completion:^(BOOL finished) {
        [toast removeFromSuperview];
    }];
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

// ==================== 通用 Toast（显示在悬浮窗上） ====================
static void showToast(NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        AdInspectorWindow *inspector = [AdInspectorWindow shared];
        UIView *toast = [[UIView alloc] init];
        toast.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
        toast.layer.cornerRadius = 12;
        toast.clipsToBounds = YES;

        UILabel *label = [[UILabel alloc] init];
        label.text = message;
        label.textColor = [UIColor whiteColor];
        label.font = [UIFont boldSystemFontOfSize:14];
        label.numberOfLines = 0;
        label.textAlignment = NSTextAlignmentCenter;
        [toast addSubview:label];

        CGSize maxSize = CGSizeMake([UIScreen mainScreen].bounds.size.width - 60, CGFLOAT_MAX);
        CGRect textRect = [message boundingRectWithSize:maxSize
                                                options:NSStringDrawingUsesLineFragmentOrigin
                                             attributes:@{NSFontAttributeName: label.font}
                                                context:nil];
        CGFloat w = textRect.size.width + 30;
        CGFloat h = textRect.size.height + 16;
        label.frame = CGRectMake(15, 8, textRect.size.width, textRect.size.height);

        CGPoint screenCenter = CGPointMake([UIScreen mainScreen].bounds.size.width / 2,
                                           [UIScreen mainScreen].bounds.size.height - 150);
        CGPoint centerInWindow = [inspector convertPoint:screenCenter fromView:nil];
        toast.frame = CGRectMake(centerInWindow.x - w/2, centerInWindow.y - h/2, w, h);

        [inspector addSubview:toast];

        [UIView animateWithDuration:0.3 delay:1.5 options:UIViewAnimationOptionCurveEaseOut animations:^{
            toast.alpha = 0;
        } completion:^(BOOL finished) {
            [toast removeFromSuperview];
        }];
    });
}

// ==================== 工具函数实现 ====================

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
    if (oldCG != NULL) oldColor = [UIColor colorWithCGColor:oldCG];
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

// ==================== 规则管理（C 函数） ====================

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
    NSLog(@"[AdInspector] 规则已保存: %@", rule);
    showToast([NSString stringWithFormat:@"✅ 已学习：%@", rule[@"buttonTextPattern"]]);
}

static UIView *findMatchingView(UIView *root, NSDictionary *rule) {
    NSString *targetClass = rule[@"buttonClass"];
    NSString *textPattern = rule[@"buttonTextPattern"];
    NSArray *chain = rule[@"hierarchyChain"];

    if ([NSStringFromClass([root class]) isEqualToString:targetClass]) {
        NSString *currentText = nil;
        if ([root isKindOfClass:[UIButton class]]) {
            currentText = [(UIButton *)root titleForState:UIControlStateNormal];
        } else if ([root isKindOfClass:[UILabel class]]) {
            currentText = [(UILabel *)root text];
        }
        if (currentText && [currentText hasPrefix:textPattern]) {
            NSMutableArray *currentChain = [NSMutableArray array];
            UIView *cur = root;
            while (cur && ![cur isKindOfClass:[UIWindow class]]) {
                [currentChain addObject:NSStringFromClass([cur class])];
                cur = cur.superview;
            }
            if ([currentChain isEqualToArray:chain]) {
                return root;
            }
        }
    }
    for (UIView *sub in root.subviews) {
        UIView *found = findMatchingView(sub, rule);
        if (found) return found;
    }
    return nil;
}

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
        SEL action = NSSelectorFromString(actionStr);
        UIView *cur = view;
        while (cur) {
            for (UIGestureRecognizer *gr in cur.gestureRecognizers) {
                if ([NSStringFromClass([gr class]) isEqualToString:gestureClass]) {
                    @try {
                        NSArray *targets = [gr valueForKey:@"_targets"];
                        for (id t in targets) {
                            if ([t isKindOfClass:[NSArray class]] && [t count] >= 2) {
                                id target = t[0];
                                if ([NSStringFromClass([target class]) isEqualToString:targetClass]) {
                                    ((void (*)(id, SEL, id))objc_msgSend)(target, action, gr);
                                    showToast(@"⏩ 已自动跳过");
                                    return;
                                }
                            }
                        }
                    } @catch (NSException *e) {}
                }
            }
            cur = cur.superview;
        }
        if ([view isKindOfClass:[UIControl class]]) {
            [(UIControl *)view sendActionsForControlEvents:UIControlEventTouchUpInside];
            showToast(@"⏩ 已自动跳过");
        }
    }
}

static void applyAllSavedRules(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSArray *rules = [ud arrayForKey:kRulesKey];
    if (!rules.count) return;

    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) {
            for (NSDictionary *rule in rules) {
                UIView *matched = findMatchingView(window, rule);
                if (matched) {
                    NSLog(@"[AutoSkip] 规则匹配成功，自动跳过");
                    triggerSkip(matched, rule);
                    return;
                }
            }
        }
    }
}

static void clearAllRules(void) {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kRulesKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

// ==================== 核心分析函数（完全保留原逻辑，加入学习）====================

static void analyzeTouchView(UIView *view, CGPoint point) {
    if (!view) return;
    NSDate *now = [NSDate date];
    if (s_lastAnalysisTime && [now timeIntervalSinceDate:s_lastAnalysisTime] < kMinAnalysisInterval) return;
    s_lastAnalysisTime = now;

    @try {
        NSMutableString *out = [NSMutableString string];
        [out appendFormat:@"\n══════ %@ ══════\n",
         [NSDateFormatter localizedStringFromDate:now dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle]];

        // ---- 层级链 ----
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
            if (tags.count) [out appendFormat:@" [%@]", [tags componentsJoinedByString:@", "]];
            [out appendFormat:@"\n%@  %@\n", indent, NSStringFromCGRect(cur.frame)];
            cur = cur.superview;
            depth++;
        }

        // ---- Target-Action & 手势 ----
        [out appendString:@"\n🎯 Target-Action & 手势:\n"];
        BOOL found = NO;
        NSMutableArray *taInfo = [NSMutableArray array];
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
                            [taInfo addObject:@{
                                @"viewClass": NSStringFromClass([cur class]),
                                @"targetClass": NSStringFromClass([tgt class]),
                                @"action": acts[0],
                                @"event": @(checkEvents[i])
                            }];
                        }
                    }
                }
            }
            for (UIGestureRecognizer *gr in cur.gestureRecognizers) {
                found = YES;
                [out appendFormat:@"  [%@] 手势:%@ (en:%d ct:%d)\n",
                 NSStringFromClass([cur class]),
                 NSStringFromClass([gr class]),
                 gr.enabled, gr.cancelsTouchesInView];
                @try {
                    if ([gr respondsToSelector:NSSelectorFromString(@"_targets")]) {
                        NSArray *tgts = [gr valueForKey:@"_targets"];
                        for (id t in tgts) {
                            [out appendFormat:@"    → %@\n", t];
                            if ([t isKindOfClass:[NSArray class]] && [t count] >= 2) {
                                id target = t[0];
                                id actionObj = t[1];
                                if ([actionObj isKindOfClass:[NSString class]]) {
                                    [taInfo addObject:@{
                                        @"viewClass": NSStringFromClass([cur class]),
                                        @"gestureClass": NSStringFromClass([gr class]),
                                        @"targetClass": NSStringFromClass([target class]),
                                        @"action": actionObj
                                    }];
                                }
                            }
                        }
                    }
                } @catch (...) {}
            }
            cur = cur.superview;
            depth++;
        }
        if (!found) [out appendString:@"  (未检测到绑定)\n"];

        // ---- 诊断信息 ----
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

        // ---------- 学习规则（自动识别触发方式） ----------
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

        BOOL hasControlEvent = NO;
        for (NSDictionary *info in taInfo) {
            if (info[@"event"] && [info[@"event"] unsignedIntegerValue] == UIControlEventTouchUpInside) {
                rule[@"triggerType"] = @"controlEvent";
                rule[@"controlEvent"] = @(UIControlEventTouchUpInside);
                hasControlEvent = YES;
                break;
            }
        }
        if (!hasControlEvent) {
            for (NSDictionary *info in taInfo) {
                if (info[@"gestureClass"] && info[@"targetClass"] && info[@"action"]) {
                    rule[@"triggerType"] = @"gesture";
                    rule[@"gestureClass"] = info[@"gestureClass"];
                    rule[@"targetClass"] = info[@"targetClass"];
                    rule[@"actionSelector"] = info[@"action"];
                    hasControlEvent = YES;
                    break;
                }
            }
        }
        if (!hasControlEvent) {
            if ([view isKindOfClass:[UIControl class]]) {
                rule[@"triggerType"] = @"controlEvent";
                rule[@"controlEvent"] = @(UIControlEventTouchUpInside);
            } else {
                showToast(@"❌ 无法识别触发方式，未学习");
                return;
            }
        }

        saveRule(rule);

    } @catch (NSException *e) {
        NSLog(@"[AdInspector] 分析异常: %@", e);
    }
}

// ==================== Hook 实现（完全保留原始结构） ====================
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

// ==================== 初始化（加入定时扫描） ====================
%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [AdInspectorWindow shared];
        showToast(@"🔍 AdInspector 已激活");

        // 定时扫描广告按钮并自动跳过（仅应用已学规则，不会主动学习）
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
            applyAllSavedRules();
        }];

        @try {
            NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
            if (paths.count > 0) {
                NSString *path = [paths[0] stringByAppendingPathComponent:@"AdInspector_Logs.txt"];
                NSString *header = [NSString stringWithFormat:@"\n=== AdInspector v3.0 (自学习+清除) [%@] ===\n",
                                   [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                                  dateStyle:NSDateFormatterShortStyle
                                                                  timeStyle:NSDateFormatterMediumStyle]];
                [header writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }
        } @catch (...) {}
    });
}
