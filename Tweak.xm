#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ==================== 规则存储 Key ====================
static NSString *const kRulesKey = @"AdInspector_SkipRules";
static NSString *const kCustomRulesKey = @"AdInspector_CustomRules";

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

// ==================== 获取所有窗口（兼容 iOS 15+） ====================
static NSArray<UIWindow *> *getAllWindows(void) {
    NSMutableArray *allWindows = [NSMutableArray array];
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            [allWindows addObjectsFromArray:[(UIWindowScene *)scene windows]];
        }
    }
    if (allWindows.count == 0) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [allWindows addObjectsFromArray:[UIApplication sharedApplication].windows];
        #pragma clang diagnostic pop
    }
    return allWindows;
}

// ==================== Flexing 窗口自动置顶 ====================
static BOOL isFlexingAvailable(void) {
    NSArray *flexClassNames = @[@"FLEXWindow",@"FLEXExplorerWindow",@"FLEXManagerWindow",@"FLEXOverlayWindow"];
    for (UIWindow *window in getAllWindows()) {
        for (NSString *className in flexClassNames) {
            if ([NSStringFromClass([window class]) isEqualToString:className]) return YES;
        }
    }
    return NO;
}

static void raiseFlexingWindow(void) {
    NSArray *flexClassNames = @[@"FLEXWindow",@"FLEXExplorerWindow",@"FLEXManagerWindow",@"FLEXOverlayWindow"];
    for (UIWindow *window in getAllWindows()) {
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
static void clearCustomRules(void);
static void showToast(NSString *message);
static UIWindow *getKeyWindow(void);
static UIView *findSkipLabelInView(UIView *root);
static void forceRemoveAdView(UIView *view);
static void saveCustomRule(NSDictionary *rule);
static void applyCustomRules(void);
static UIView *findViewOfClass(UIView *root, NSString *className);
static id getObjectByKeyPath(id object, NSString *keyPath);

// ==================== 分析防抖 ====================
static NSDate *s_lastAnalysisTime = nil;
static const NSTimeInterval kMinAnalysisInterval = 0.3;

// ==================== 双指长按呼出面板 ====================
static NSDate *s_twoFingerStart = nil;
static const NSTimeInterval kTwoFingerHoldDuration = 0.5;
static NSDate *s_ignoreSingleTouchUntil = nil;

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
    if (hitView == self || (id)hitView == (id)self.panel) return nil;
    UIView *check = hitView;
    while (check && (id)check != (id)self.panel) {
        NSInteger tag = check.tag;
        if (tag >= 1001 && tag <= 1009) return check;
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
- (void)addDefaultRule;
- (void)testCustomRules;
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

        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, 240, 20)];
        title.text = @"🔍 AdInspector | 自定义规则"; title.textColor = [UIColor cyanColor];
        title.font = [UIFont boldSystemFontOfSize:12]; title.tag = 1001;
        [self addSubview:title];

        UIButton *addRuleBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        addRuleBtn.frame = CGRectMake(12, 32, 80, 30);
        [addRuleBtn setTitle:@"+ 添加规则" forState:UIControlStateNormal];
        [addRuleBtn setTitleColor:[UIColor greenColor] forState:UIControlStateNormal];
        addRuleBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
        addRuleBtn.tag = 1008;
        [addRuleBtn addTarget:self action:@selector(addDefaultRule) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:addRuleBtn];

        UIButton *testBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        testBtn.frame = CGRectMake(100, 32, 80, 30);
        [testBtn setTitle:@"▶ 测试规则" forState:UIControlStateNormal];
        [testBtn setTitleColor:[UIColor yellowColor] forState:UIControlStateNormal];
        testBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
        testBtn.tag = 1009;
        [testBtn addTarget:self action:@selector(testCustomRules) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:testBtn];

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

        CGFloat tvY = 68;
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

- (void)addDefaultRule {
    NSDictionary *rule1 = @{@"targetView":@"GDTDLRootView",@"keyPath":@"delegate",@"methodName":@"onDestroy",@"description":@"广点通onDestroy"};
    NSDictionary *rule2 = @{@"targetView":@"CSJSplashView",@"keyPath":@"self",@"methodName":@"p_skipTapped:",@"description":@"穿山甲p_skipTapped"};
    saveCustomRule(rule1);
    saveCustomRule(rule2);
    [self showLog:@"\n✅ 已添加规则:\n  GDTDLRootView → delegate → onDestroy\n  CSJSplashView → self → p_skipTapped:\n"];
    showToast(@"✅ 规则已添加");
}

- (void)testCustomRules {
    applyCustomRules();
    [self showLog:@"\n🔍 已执行自定义规则测试\n"];
}

- (void)clearRulesTapped {
    clearAllRules();
    clearCustomRules();
    [self showLog:@"\n🗑️ 已清空所有规则\n"];
    showToast(@"🗑️ 规则已清除");
}

- (void)viewRulesTapped {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSArray *autoRules = [ud arrayForKey:kRulesKey] ?: @[];
    NSArray *customRules = [ud arrayForKey:kCustomRulesKey] ?: @[];
    
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"\n📋 自动规则 (%lu条):\n", (unsigned long)autoRules.count];
    for (NSInteger i = 0; i < autoRules.count; i++) {
        NSDictionary *rule = autoRules[i];
        [out appendFormat:@"  %ld: %@ \"%@\" 触发:%@\n", (long)i+1, rule[@"buttonClass"], rule[@"buttonTextPattern"], rule[@"triggerType"]];
    }
    
    [out appendFormat:@"\n📋 自定义规则 (%lu条):\n", (unsigned long)customRules.count];
    for (NSInteger i = 0; i < customRules.count; i++) {
        NSDictionary *rule = customRules[i];
        [out appendFormat:@"  %ld: %@ → %@.%@\n", (long)i+1, rule[@"targetView"], rule[@"keyPath"], rule[@"methodName"]];
    }
    [out appendString:@"\n💡 点击\"+ 添加规则\"添加预设规则\n"];
    
    [self showLog:out];
}

- (void)forceShow { /* 同上 */ }
- (void)showLog:(NSString *)log { /* 同上 */ }
@end

// ==================== Toast ====================
static void showToast(NSString *message) { /* 同上 */ }

// ==================== 工具函数 ====================
static NSString *getControlEventName(UIControlEvents e) { /* 同上 */ }
static void saveToFile(NSString *log) { /* 同上 */ }
static void highlightView(UIView *view) { /* 同上 */ }

// ==================== 规则管理 ====================
static void saveRule(NSDictionary *rule) { /* 同上 */ }
static UIView *findMatchingView(UIView *root, NSDictionary *rule) { /* 同上 */ }
static void clearAllRules(void) { /* 同上 */ }

// ==================== 自定义规则管理 ====================
static void saveCustomRule(NSDictionary *rule) { /* 同上 */ }
static void clearCustomRules(void) { /* 同上 */ }
static id getObjectByKeyPath(id object, NSString *keyPath) { /* 同上 */ }
static UIView *findViewOfClass(UIView *root, NSString *className) { /* 同上 */ }
static void applyCustomRules(void) { /* 同上 */ }

// ==================== 强制移除广告视图 ====================
static void forceRemoveAdView(UIView *view) { /* 同上 */ }

// ==================== 跳过引擎 ====================
static void triggerSkip(UIView *view, NSDictionary *rule) { /* 同上 */ }

// ==================== 自动跳过扫描 ====================
static void applyAllSavedRules(void) { /* 同上 */ }

// ==================== 按钮识别 ====================
static BOOL isSkipText(NSString *text) { /* 同上 */ }
static UIView *findSkipLabelInView(UIView *root) {
    // 排除插件自身面板
    if ([root isKindOfClass:[AdInspectorPanel class]] || 
        [root isKindOfClass:NSClassFromString(@"AdInspectorWindow")] ||
        (root.tag >= 1001 && root.tag <= 1009)) return nil;
    
    NSString *currentText = nil;
    if ([root isKindOfClass:[UIButton class]]) currentText = [(UIButton *)root titleForState:UIControlStateNormal];
    else if ([root isKindOfClass:[UILabel class]]) currentText = [(UILabel *)root text] ?: [(UILabel *)root attributedText].string;
    if (!currentText) currentText = root.accessibilityLabel;
    if (isSkipText(currentText)) return root;
    for (UIView *sub in root.subviews) { UIView *found = findSkipLabelInView(sub); if (found) return found; }
    return nil;
}

// ==================== 核心分析 ====================
static void analyzeTouchView(UIView *view, CGPoint point) {
    if (!view) return;
    // 排除插件自身视图
    if ([view isDescendantOfView:[AdInspectorPanel shared]] || 
        [NSStringFromClass([view.window class]) isEqualToString:@"AdInspectorWindow"] ||
        (view.tag >= 1001 && view.tag <= 1009)) return;
    
    NSDate *now = [NSDate date];
    if (s_lastAnalysisTime && [now timeIntervalSinceDate:s_lastAnalysisTime] < kMinAnalysisInterval) return;
    s_lastAnalysisTime = now;
    UIView *actualView = findSkipLabelInView(view);
    if (!actualView) { showToast(@"⚠️ 未检测到跳过按钮，学习失败"); return; }
    // ... 分析逻辑同上
}

// ==================== Hook ====================
%hook UIApplication
- (void)sendEvent:(UIEvent *)event { /* 同上 */ }
%end

%hook UIControl
- (void)addTarget:(id)target action:(SEL)action forControlEvents:(UIControlEvents)controlEvents { /* 同上 */ }
%end

// ==================== 初始化 ====================
%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindowScene *activeScene = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) { if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) { activeScene = (UIWindowScene *)scene; break; } }
        if (activeScene) {
            s_floatWindow = [[AdInspectorWindow alloc] initWithFrame:activeScene.coordinateSpace.bounds];
            s_floatWindow.windowScene = activeScene;
            AdInspectorPanel *panel = [AdInspectorPanel shared];
            panel.frame = CGRectMake(5, 160, s_floatWindow.bounds.size.width - 10, 280);
            panel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
            [s_floatWindow addSubview:panel];
            s_floatWindow.panel = panel; s_floatWindow.hidden = NO;
        }
        showToast(@"🔍 已激活 | 双指呼面板 | 自定义规则");
        if (isFlexingAvailable()) raiseFlexingWindow();
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
            applyAllSavedRules();
            if (s_floatWindow) s_floatWindow.hidden = NO;
            if (isFlexingAvailable()) raiseFlexingWindow();
        }];
    });
}
