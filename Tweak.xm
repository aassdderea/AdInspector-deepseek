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

// ==================== 悬浮窗（最高层级 + 触摸穿透） ====================
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
        self.windowLevel = CGFLOAT_MAX; // 永不被遮挡
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
    showToast(@"🗑️ 规则已清除");
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
        CGFloat w = textRect.size.width + 30, h = textRect.size.height + 16;
        label.frame = CGRectMake(15, 8, textRect.size.width, textRect.size.height);
        CGPoint screenCenter = CGPointMake([UIScreen mainScreen].bounds.size.width/2, [UIScreen mainScreen].bounds.size.height - 150);
        CGPoint centerInWindow = [inspector convertPoint:screenCenter fromView:nil];
        toast.frame = CGRectMake(centerInWindow.x - w/2, centerInWindow.y - h/2, w, h);
        [inspector addSubview:toast];
        [UIView animateWithDuration:0.3 delay:1.5 options:UIViewAnimationOptionCurveEaseOut animations:^{ toast.alpha = 0; } completion:^(BOOL finished) { [toast removeFromSuperview]; }];
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

static void saveToFile(NSString *log) {
    @try {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        if (paths.count == 0) return;
        NSString *path = [paths[0] stringByAppendingPathComponent:@"AdInspector_Logs.txt"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) [[NSData data] writeToFile:path atomically:YES];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (fh) { [fh seekToEndOfFile]; [fh writeData:[log dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    } @catch (NSException *e) {}
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
        if (sv) { sv.layer.borderColor = oldColor ? oldColor.CGColor : NULL; sv.layer.borderWidth = oldWidth; }
    });
}

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
    NSLog(@"[AdInspector] 规则已保存至: %@", [[NSBundle mainBundle] bundleIdentifier]);
}

static UIView *findMatchingView(UIView *root, NSDictionary *rule) {
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
}

// ==================== 增强触发：多级 fallback ====================
static void triggerSkip(UIView *view, NSDictionary *rule) {
    NSString *triggerType = rule[@"triggerType"];
    if ([triggerType isEqualToString:@"controlEvent"]) {
        if ([view isKindOfClass:[UIControl class]]) {
            [(UIControl *)view sendActionsForControlEvents:[rule[@"controlEvent"] unsignedIntegerValue]];
            showToast(@"⏩ 已自动跳过");
            return;
        }
    }

    // 手势类型：优先用 target/action，否则强制设状态
    NSString *gestureClass = rule[@"gestureClass"];
    UIView *cur = view;
    while (cur) {
        for (UIGestureRecognizer *gr in cur.gestureRecognizers) {
            if ([NSStringFromClass([gr class]) isEqualToString:gestureClass]) {
                // 尝试调用 target/action
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
                // 强制触发手势（通用 fallback）
                [gr setValue:@(UIGestureRecognizerStateRecognized) forKey:@"_state"];
                showToast(@"⏩ 已自动跳过 (强制)");
                return;
            }
        }
        cur = cur.superview;
    }

    // 最后尝试：如果 view 是 UIControl 则发送事件
    if ([view isKindOfClass:[UIControl class]]) {
        [(UIControl *)view sendActionsForControlEvents:UIControlEventTouchUpInside];
        showToast(@"⏩ 已自动跳过 (兜底)");
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

// ==================== 辅助：递归查找“跳过”标签 ====================
static UIView *findSkipLabelInView(UIView *root) {
    if ([root isKindOfClass:[UIButton class]]) {
        NSString *t = [(UIButton *)root titleForState:UIControlStateNormal];
        if ([t hasPrefix:@"跳过"]) return root;
    }
    if ([root isKindOfClass:[UILabel class]]) {
        NSString *t = [(UILabel *)root text];
        if ([t hasPrefix:@"跳过"]) return root;
    }
    for (UIView *sub in root.subviews) {
        UIView *found = findSkipLabelInView(sub);
        if (found) return found;
    }
    return nil;
}

// ==================== 核心分析（强化学习） ====================
static void analyzeTouchView(UIView *view, CGPoint point) {
    if (!view) return;
    NSDate *now = [NSDate date];
    if (s_lastAnalysisTime && [now timeIntervalSinceDate:s_lastAnalysisTime] < kMinAnalysisInterval) return;
    s_lastAnalysisTime = now;

    // 自动寻找“跳过”文字标签（如果点偏了）
    UIView *actualView = findSkipLabelInView(view);
    if (!actualView) actualView = view; // 找不到则用原视图

    @try {
        NSMutableString *out = [NSMutableString string];
        [out appendFormat:@"\n══════ %@ ══════\n",
         [NSDateFormatter localizedStringFromDate:now dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle]];

        // ---- 层级链（基于 actualView） ----
        NSMutableArray *chainArray = [NSMutableArray array];
        UIView *cur = actualView;
        while (cur && ![cur isKindOfClass:[UIWindow class]]) {
            [chainArray addObject:NSStringFromClass([cur class])];
            cur = cur.superview;
        }
        NSString *windowClass = cur ? NSStringFromClass([cur class]) : @"";

        [out appendString:@"📊 视图层级链:\n"];
        cur = actualView;
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
            if (cur.accessibilityLabel.length) [tags addObject:[NSString stringWithFormat:@"a11y:\"%@\"", cur.accessibilityLabel]];
            if (tags.count) [out appendFormat:@" [%@]", [tags componentsJoinedByString:@", "]];
            [out appendFormat:@"\n%@  %@\n", indent, NSStringFromCGRect(cur.frame)];
            cur = cur.superview;
            depth++;
        }

        // ---- Target-Action & 手势 ----
        [out appendString:@"\n🎯 Target-Action & 手势:\n"];
        BOOL found = NO;
        NSMutableArray *taInfo = [NSMutableArray array];
        cur = actualView;
        depth = 0;
        while (cur && depth < 8) {
            if ([cur isKindOfClass:[UIControl class]]) {
                UIControl *c = (UIControl *)cur;
                for (id tgt in c.allTargets) {
                    UIControlEvents checkEvents[] = {UIControlEventTouchUpInside, UIControlEventTouchDown, UIControlEventValueChanged, UIControlEventPrimaryActionTriggered};
                    for (int i = 0; i < 4; i++) {
                        NSArray *acts = [c actionsForTarget:tgt forControlEvent:checkEvents[i]];
                        if (acts.count) {
                            found = YES;
                            [out appendFormat:@"  [%@] → %@.%@ (%@)\n", NSStringFromClass([cur class]), NSStringFromClass([tgt class]), acts[0], getControlEventName(checkEvents[i])];
                            [taInfo addObject:@{@"viewClass": NSStringFromClass([cur class]), @"targetClass": NSStringFromClass([tgt class]), @"action": acts[0], @"event": @(checkEvents[i])}];
                        }
                    }
                }
            }
            for (UIGestureRecognizer *gr in cur.gestureRecognizers) {
                found = YES;
                [out appendFormat:@"  [%@] 手势:%@ (en:%d ct:%d)\n", NSStringFromClass([cur class]), NSStringFromClass([gr class]), gr.enabled, gr.cancelsTouchesInView];
                BOOL gotTargetInfo = NO;
                if ([gr respondsToSelector:@selector(_targets)]) {
                    NSArray *tgts = [gr valueForKey:@"_targets"];
                    if (tgts && [tgts isKindOfClass:[NSArray class]]) {
                        for (id t in tgts) {
                            id target = [t valueForKey:@"_target"];
                            id actionObj = [t valueForKey:@"_action"];
                            NSString *actionStr = nil;
                            if ([actionObj isKindOfClass:[NSString class]]) actionStr = actionObj;
                            else if ([actionObj respondsToSelector:@selector(selector)]) actionStr = NSStringFromSelector([actionObj selector]);
                            else if ([actionObj isKindOfClass:[NSValue class]]) actionStr = NSStringFromSelector((SEL)[actionObj pointerValue]);
                            if (target && actionStr) {
                                [out appendFormat:@"    → %@.%@\n", NSStringFromClass([target class]), actionStr];
                                [taInfo addObject:@{@"viewClass": NSStringFromClass([cur class]), @"gestureClass": NSStringFromClass([gr class]), @"targetClass": NSStringFromClass([target class]), @"action": actionStr}];
                                gotTargetInfo = YES;
                            }
                        }
                    }
                }
                if (!gotTargetInfo) [out appendString:@"    (无法提取 target/action，将使用备用规则)\n"];
            }
            cur = cur.superview;
            depth++;
        }
        if (!found) [out appendString:@"  (未检测到绑定)\n"];

        // ---- 诊断信息 ----
        [out appendString:@"\n🔍 诊断信息:\n"];
        [out appendFormat:@"  实际目标: %@\n", NSStringFromClass([actualView class])];
        [out appendFormat:@"  frame: %@\n", NSStringFromCGRect(actualView.frame)];
        [out appendFormat:@"  bounds: %@\n", NSStringFromCGRect(actualView.bounds)];
        [out appendFormat:@"  userInteraction:%d hidden:%d alpha:%.2f\n", actualView.userInteractionEnabled, actualView.hidden, actualView.alpha];
        if (actualView.gestureRecognizers.count) {
            [out appendString:@"  视图手势: "];
            for (UIGestureRecognizer *gr in actualView.gestureRecognizers) [out appendFormat:@"%@ ", NSStringFromClass([gr class])];
            [out appendString:@"\n"];
        }
        [out appendString:@"  响应链: "];
        UIResponder *r = actualView.nextResponder;
        int rc = 0;
        while (r && rc < 6) { [out appendFormat:@"→%@ ", NSStringFromClass([r class])]; r = r.nextResponder; rc++; }
        [out appendString:@"\n══════════════════════════\n"];

        [[AdInspectorWindow shared] showLog:out];
        saveToFile(out);
        highlightView(actualView);

        // ====== 学习规则 ======
        NSString *buttonText = nil;
        if ([actualView isKindOfClass:[UIButton class]]) buttonText = [(UIButton *)actualView titleForState:UIControlStateNormal];
        else if ([actualView isKindOfClass:[UILabel class]]) buttonText = [(UILabel *)actualView text];
        if (!buttonText || buttonText.length == 0) {
            showToast(@"⚠️ 未检测到“跳过”文字，学习失败");
            return;
        }

        NSMutableDictionary *rule = [NSMutableDictionary dictionary];
        rule[@"buttonClass"] = NSStringFromClass([actualView class]);
        rule[@"buttonTextPattern"] = buttonText;
        rule[@"hierarchyChain"] = chainArray;
        rule[@"windowClass"] = windowClass;

        BOOL hasRule = NO;
        for (NSDictionary *info in taInfo) {
            if (info[@"event"] && [info[@"event"] unsignedIntegerValue] == UIControlEventTouchUpInside) {
                rule[@"triggerType"] = @"controlEvent";
                rule[@"controlEvent"] = @(UIControlEventTouchUpInside);
                hasRule = YES; break;
            }
        }
        if (!hasRule) {
            for (NSDictionary *info in taInfo) {
                if (info[@"gestureClass"] && info[@"targetClass"] && info[@"action"]) {
                    rule[@"triggerType"] = @"gesture";
                    rule[@"gestureClass"] = info[@"gestureClass"];
                    rule[@"targetClass"] = info[@"targetClass"];
                    rule[@"actionSelector"] = info[@"action"];
                    rule[@"gestureViewClass"] = info[@"viewClass"];
                    hasRule = YES; break;
                }
            }
        }
        if (!hasRule) {
            // 备用：记录第一个手势
            cur = actualView;
            while (cur) {
                for (UIGestureRecognizer *gr in cur.gestureRecognizers) {
                    rule[@"triggerType"] = @"gesture";
                    rule[@"gestureClass"] = NSStringFromClass([gr class]);
                    rule[@"gestureViewClass"] = NSStringFromClass([cur class]);
                    hasRule = YES; break;
                }
                if (hasRule) break;
                cur = cur.superview;
            }
        }
        if (!hasRule && [actualView isKindOfClass:[UIControl class]]) {
            rule[@"triggerType"] = @"controlEvent";
            rule[@"controlEvent"] = @(UIControlEventTouchUpInside);
            hasRule = YES;
        }

        if (hasRule) saveRule(rule);
        else showToast(@"❌ 无法学习触发方式");
    } @catch (NSException *e) {
        showToast(@"⚠️ 分析异常");
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
    NSLog(@"[AdInspector] 🔗 %@ → %@.%@ [%@]", NSStringFromClass([self class]), NSStringFromClass([target class]), NSStringFromSelector(action), getControlEventName(controlEvents));
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
        // 输出规则存储路径
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
        NSString *prefsPath = [paths.firstObject stringByAppendingPathComponent:@"Preferences"];
        NSLog(@"[AdInspector] 规则存储目录: %@", prefsPath);
    });
}
