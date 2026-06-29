#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ==================== 调试开关（通过绿框按钮切换，无需重新编译） ====================
static BOOL s_debugMode = NO;

// ==================== Ivar 读取辅助函数 ====================
static Ivar ATFindIvar(Class cls, const char *name) {
    for (Class current = cls; current; current = class_getSuperclass(current)) {
        Ivar ivar = class_getInstanceVariable(current, name);
        if (ivar) return ivar;
    }
    return NULL;
}

static id ATGetObjectIvar(id object, const char *name) {
    Ivar ivar = ATFindIvar(object_getClass(object), name);
    if (!ivar) return nil;
    return object_getIvar(object, ivar);
}

static SEL ATGetSelectorIvar(id object, const char *name) {
    Ivar ivar = ATFindIvar(object_getClass(object), name);
    if (!ivar) return NULL;
    ptrdiff_t offset = ivar_getOffset(ivar);
    return *(SEL *)((uint8_t *)(__bridge void *)object + offset);
}

// ==================== Flexing 窗口置顶 ====================
static void raiseFlexingWindow(void) {
    NSArray *flexClassNames = @[
        @"FLEXWindow",
        @"FLEXExplorerWindow",
        @"FLEXManagerWindow",
        @"FLEXOverlayWindow"
    ];
    
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        for (NSString *className in flexClassNames) {
            if ([NSStringFromClass([window class]) isEqualToString:className]) {
                window.windowLevel = CGFLOAT_MAX;
                window.hidden = NO;
                window.alpha = 1.0;
                [window makeKeyAndVisible];
                return;
            }
        }
    }
}

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
static void forceRemoveAdView(UIView *view);

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
    if (hitView == self || (id)hitView == (id)self.panel) return nil;
    UIView *check = hitView;
    while (check && (id)check != (id)self.panel) {
        NSInteger tag = check.tag;
        if (tag >= 1001 && tag <= 1007) return check;
        check = check.superview;
    }
    return nil;
}

- (void)setHidden:(BOOL)hidden {
    if (hidden && !self.isHidden) return;
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
- (void)toggleDebugMode;
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
        self.layer.cornerRadius = 10; self.layer.borderWidth = 1.5;
        self.layer.borderColor = [UIColor cyanColor].CGColor;
        self.userInteractionEnabled = YES; self.clipsToBounds = NO; self.hidden = YES;

        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, 100, 20)];
        title.text = @"🔍 AdInspector"; title.textColor = [UIColor cyanColor];
        title.font = [UIFont boldSystemFontOfSize:14]; title.tag = 1001;
        [self addSubview:title];

        UIButton *debugBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        debugBtn.frame = CGRectMake(self.bounds.size.width - 180, 3, 45, 30);
        [debugBtn setTitle:@"调试" forState:UIControlStateNormal];
        [debugBtn setTitleColor:[UIColor colorWithRed:0.5 green:0.8 blue:1.0 alpha:1.0] forState:UIControlStateNormal];
        debugBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
        debugBtn.tag = 1007;
        [debugBtn addTarget:self action:@selector(toggleDebugMode) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:debugBtn];

        UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        closeBtn.frame = CGRectMake(self.bounds.size.width - 45, 3, 40, 30);
        [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
        [closeBtn setTitleColor:[UIColor redColor] forState:UIControlStateNormal];
        closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:20]; closeBtn.tag = 1002;
        [closeBtn addTarget:self action:@selector(hidePanel) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:closeBtn];

        UIButton *clearBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        clearBtn.frame = CGRectMake(self.bounds.size.width - 135, 3, 45, 30);
        [clearBtn setTitle:@"清空" forState:UIControlStateNormal];
        [clearBtn setTitleColor:[UIColor orangeColor] forState:UIControlStateNormal];
        clearBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold]; clearBtn.tag = 1003;
        [clearBtn addTarget:self action:@selector(clearRulesTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:clearBtn];

        UIButton *viewBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        viewBtn.frame = CGRectMake(self.bounds.size.width - 90, 3, 45, 30);
        [viewBtn setTitle:@"查看" forState:UIControlStateNormal];
        [viewBtn setTitleColor:[UIColor yellowColor] forState:UIControlStateNormal];
        viewBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold]; viewBtn.tag = 1006;
        [viewBtn addTarget:self action:@selector(viewRulesTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:viewBtn];

        UIView *handle = [[UIView alloc] initWithFrame:CGRectMake(self.bounds.size.width/2 - 15, 4, 30, 4)];
        handle.backgroundColor = [UIColor colorWithWhite:0.4 alpha:0.6]; handle.layer.cornerRadius = 2; handle.tag = 1004;
        [self addSubview:handle];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];

        CGFloat tvY = 32;
        self.logTextView = [[UITextView alloc] initWithFrame:CGRectMake(5, tvY, self.bounds.size.width - 10, self.bounds.size.height - tvY - 5)];
        self.logTextView.backgroundColor = [UIColor clearColor]; self.logTextView.textColor = [UIColor greenColor];
        self.logTextView.font = [UIFont fontWithName:@"Courier" size:10] ?: [UIFont systemFontOfSize:10];
        self.logTextView.editable = NO; self.logTextView.selectable = YES; self.logTextView.tag = 1005;
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

- (void)toggleDebugMode {
    s_debugMode = !s_debugMode;
    if (s_debugMode) {
        [self showLog:@"\n🔍 调试模式已开启 - 广告不会自动关闭\n"];
        showToast(@"🔍 调试模式：广告不关闭");
    } else {
        [self showLog:@"\n✅ 调试模式已关闭 - 恢复正常跳过\n"];
        showToast(@"✅ 正常模式：自动跳过广告");
    }
}

- (void)clearRulesTapped { clearAllRules(); [self showLog:@"\n🗑️ 已清空所有学习规则\n"]; showToast(@"🗑️ 规则已清除"); }

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
             (long)i+1, rule[@"buttonClass"], rule[@"buttonTextPattern"],
             rule[@"triggerType"] ?: @"未知", rule[@"containerClass"] ?: @"未知",
             rule[@"targetClass"] ?: @"-", rule[@"actionSelector"] ?: @"-",
             [rule[@"hierarchyChain"] componentsJoinedByString:@" → "]];
        }
        [self showLog:out];
    }
}

- (void)forceShow { /* 与之前相同 */ }
- (void)showLog:(NSString *)log { /* 与之前相同 */ }
@end

// ==================== Toast ====================
static void showToast(NSString *message) { /* 与之前相同 */ }

// ==================== 工具函数 ====================
static NSString *getControlEventName(UIControlEvents e) { /* 与之前相同 */ }
static void saveToFile(NSString *log) { /* 与之前相同 */ }
static void highlightView(UIView *view) { /* 与之前相同 */ }

// ==================== 规则管理 ====================
static void saveRule(NSDictionary *rule) { /* 与之前相同 */ }
static UIView *findMatchingView(UIView *root, NSDictionary *rule) { /* 与之前相同 */ }
static void clearAllRules(void) { /* 与之前相同 */ }

// ==================== 强制移除广告视图 ====================
static void forceRemoveAdView(UIView *view) { /* 与之前相同 */ }

// ==================== 跳过引擎（调试版） ====================
static void triggerSkip(UIView *view, NSDictionary *rule) {
    if ([view isDescendantOfView:[AdInspectorPanel shared]] ||
        [view.window isKindOfClass:[AdInspectorWindow class]]) return;

    // 调试模式：只提示，不操作，同时提升Flexing窗口
    if (s_debugMode) {
        showToast(@"🔍 广告已定位，用Flexing查看");
        raiseFlexingWindow();
        return;
    }

    // 正常跳过逻辑（与之前相同）...
}

// ==================== 自动跳过扫描 ====================
static void applyAllSavedRules(void) { /* 与之前相同 */ }

// ==================== 按钮识别 ====================
static BOOL isSkipText(NSString *text) { /* 与之前相同 */ }
static UIView *findSkipLabelInView(UIView *root) { /* 与之前相同 */ }

// ==================== 核心分析（学习） ====================
static void analyzeTouchView(UIView *view, CGPoint point) { /* 与之前相同，含Ivar提取 */ }

// ==================== Hook ====================
%hook UIApplication
- (void)sendEvent:(UIEvent *)event { /* 与之前相同 */ }
%end

%hook UIControl
- (void)addTarget:(id)target action:(SEL)action forControlEvents:(UIControlEvents)controlEvents { /* 与之前相同 */ }
%end

// ==================== 初始化 ====================
%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindowScene *activeScene = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
                activeScene = (UIWindowScene *)scene; break;
            }
        }
        if (activeScene) {
            s_floatWindow = [[AdInspectorWindow alloc] initWithFrame:activeScene.coordinateSpace.bounds];
            s_floatWindow.windowScene = activeScene;
            AdInspectorPanel *panel = [AdInspectorPanel shared];
            panel.frame = CGRectMake(5, 160, s_floatWindow.bounds.size.width - 10, 280);
            panel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
            [s_floatWindow addSubview:panel];
            s_floatWindow.panel = panel; s_floatWindow.hidden = NO;
        }

        showToast(@"🔍 已激活 | 双指呼出面板 | 点\"调试\"切换模式");
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
            applyAllSavedRules();
            if (s_floatWindow) s_floatWindow.hidden = NO;
            if (s_debugMode) raiseFlexingWindow();
        }];
    });
}
