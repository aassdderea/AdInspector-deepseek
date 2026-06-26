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
        if (tag >= 1001 && tag <= 1005) return check;
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
                // 自动跳过时采用包含匹配，容忍数字变化
                textMatches = ([currentText rangeOfString:textPattern].location != NSNotFound &&
                               currentText.length <= 15);
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

// ==================== 自动跳过 ====================
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

// ==================== 增强的跳过按钮识别 ====================
static BOOL isSkipText(NSString *text) {
    if (!text || text.length == 0) return NO;
    // 常见跳过关键词
    NSArray *keywords = @[@"跳过", @"广告", @"关闭", @"×", @"x", @"X", @"close", @"skip"];
    for (NSString *keyword in keywords) {
        // 包含匹配，但限制总长度避免误判（跳过按钮文本通常不超过15字符）
        if ([text rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound &&
            text.length <= 15) {
            return YES;
        }
    }
    return NO;
}

static UIView *findSkipLabelInView(UIView *root) {
    if ([root isKindOfClass:[AdInspectorPanel class]]) return nil;
    
    // 先检查当前视图文本
    NSString *currentText = nil;
    if ([root isKindOfClass:[UIButton class]]) {
        currentText = [(UIButton *)root titleForState:UIControlStateNormal];
    } else if ([root isKindOfClass:[UILabel class]]) {
        currentText = [(UILabel *)root text] ?: [(UILabel *)root attributedText].string;
    }
    if (!currentText) {
        currentText = root.accessibilityLabel;
    }
    if (isSkipText(currentText)) {
        return root;
    }

    // 递归子视图
    for (UIView *sub in root.subviews) {
        UIView *found = findSkipLabelInView(sub);
        if (found) return found;
    }
    return nil;
}

// ==================== 核心分析 ====================
static void analyzeTouchView(UIView *view, CGPoint point) {
    if (!view) return;
    if ([view isDescendantOfView:[AdInspectorPanel shared]] ||
        [view.window isKindOfClass:[AdInspectorWindow class]]) {
        return;
    }

    NSDate *now = [NSDate date];
    if (s_lastAnalysisTime && [now timeIntervalSinceDate:s_lastAnalysisTime] < kMinAnalysisInterval) return;
    s_lastAnalysisTime = now;

    UIView *actualView = findSkipLabelInView(view);
    if (!actualView) {
        showToast(@"⚠️ 未检测到跳过按钮，学习失败");
        return;
    }

    @try {
        NSMutableString *out = [NSMutableString string];
        [out appendFormat:@"\n══════ %@ ══════\n",
         [NSDateFormatter localizedStringFromDate:now dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle]];

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
                NSString *t = [(UILabel *)cur text] ?: [(UILabel *)cur attributedText].string;
                if (t.length > 20) t = [[t substringToIndex:20] stringByAppendingString:@"..."];
                if (t.length) [tags addObject:[NSString stringWithFormat:@"\"%@\"", t]];
            }
            if (cur.accessibilityLabel.length) [tags addObject:[NSString stringWithFormat:@"a11y:\"%@\"", cur.accessibilityLabel]];
            if (tags.count) [out appendFormat:@" [%@]", [tags componentsJoinedByString:@", "]];
            [out appendFormat:@"\n%@  %@\n", indent, NSStringFromCGRect(cur.frame)];
            cur = cur.superview;
            depth++;
        }

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

        [[AdInspectorPanel shared] showLog:out];
        saveToFile(out);
        highlightView(actualView);

        // 学习规则
        NSString *buttonText = nil;
        if ([actualView isKindOfClass:[UIButton class]]) buttonText = [(UIButton *)actualView titleForState:UIControlStateNormal];
        else if ([actualView isKindOfClass:[UILabel class]]) buttonText = [(UILabel *)actualView text] ?: [(UILabel *)actualView attributedText].string;
        if (buttonText.length == 0) buttonText = actualView.accessibilityLabel;
        if (buttonText.length == 0) {
            showToast(@"⚠️ 按钮无文字，学习失败");
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

        showToast(@"🔍 已激活 | 点击跳过/广告/关闭学习 | 双指长按呼出面板");
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
            applyAllSavedRules();
            if (s_floatWindow) {
                s_floatWindow.hidden = NO;
            }
            AdInspectorPanel *panel = [AdInspectorPanel shared];
            if (!panel.hidden && panel.superview) {
                [panel.superview bringSubviewToFront:panel];
            }
        }];
    });
}
