#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <execinfo.h>

static NSString *const kRulesKey = @"AdInspector_SkipRules";
static NSString *const kCustomRulesKey = @"AdInspector_CustomRules";
static NSMutableArray *s_trackedMethods = nil;
static BOOL s_isTracking = NO;
static NSDate *s_trackStartTime = nil;
static BOOL s_isDeepTracking = NO;
static NSDate *s_deepTrackStartTime = nil;
static NSMutableArray *s_deepTrackedMethods = nil;
static BOOL s_isKeyboardVisible = NO;

// ==================== 获取所有窗口 ====================
static NSArray<UIWindow *> *getAllWindows(void)
{
    NSMutableArray *all = [NSMutableArray array];
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes)
    {
        if ([scene isKindOfClass:[UIWindowScene class]])
        {
            [all addObjectsFromArray:[(UIWindowScene *)scene windows]];
        }
    }
    if (all.count == 0)
    {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [all addObjectsFromArray:[UIApplication sharedApplication].windows];
#pragma clang diagnostic pop
    }
    return all;
}

// ==================== Flexing ====================
static BOOL isFlexingAvailable(void)
{
    for (UIWindow *w in getAllWindows())
    {
        NSString *cn = NSStringFromClass([w class]);
        if ([cn isEqualToString:@"FLEXWindow"] ||
            [cn isEqualToString:@"FLEXExplorerWindow"] ||
            [cn isEqualToString:@"FLEXManagerWindow"] ||
            [cn isEqualToString:@"FLEXOverlayWindow"])
        {
            return YES;
        }
    }
    return NO;
}

static void raiseFlexingWindow(void)
{
    if (s_isKeyboardVisible)
    {
        return;
    }
    for (UIWindow *w in getAllWindows())
    {
        NSString *cn = NSStringFromClass([w class]);
        if ([cn isEqualToString:@"FLEXWindow"] ||
            [cn isEqualToString:@"FLEXExplorerWindow"] ||
            [cn isEqualToString:@"FLEXManagerWindow"] ||
            [cn isEqualToString:@"FLEXOverlayWindow"])
        {
            w.windowLevel = CGFLOAT_MAX;
            w.hidden = NO;
            w.alpha = 1.0;
            [w makeKeyAndVisible];
            return;
        }
    }
}

// ==================== 方法追踪 ====================
static void startTracking(void)
{
    s_trackedMethods = [NSMutableArray array];
    s_isTracking = YES;
    s_trackStartTime = [NSDate date];
}

static void stopTracking(void)
{
    s_isTracking = NO;
}

static void hookAllMethodsOfClass(Class cls)
{
    if (!cls)
    {
        return;
    }
    NSString *className = NSStringFromClass(cls);
    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(cls, &methodCount);
    for (unsigned int i = 0; i < methodCount; i++)
    {
        SEL sel = method_getName(methods[i]);
        NSString *methodName = NSStringFromSelector(sel);
        if ([methodName hasPrefix:@"."] ||
            [methodName hasPrefix:@"init"] ||
            [methodName isEqualToString:@"dealloc"] ||
            [methodName isEqualToString:@"class"] ||
            [methodName hasPrefix:@"hash"] ||
            [methodName hasPrefix:@"isEqual"] ||
            [methodName hasPrefix:@"performSelector"] ||
            [methodName hasPrefix:@"respondsToSelector"] ||
            [methodName hasPrefix:@"methodSignature"] ||
            [methodName hasPrefix:@"forwardInvocation"] ||
            [methodName hasPrefix:@"doesNotRecognize"])
        {
            continue;
        }
        const char *typeEncoding = method_getTypeEncoding(methods[i]);
        if (typeEncoding && typeEncoding[0] == 'v')
        {
            IMP originalIMP = method_getImplementation(methods[i]);
            NSString *fullMethodName = [NSString stringWithFormat:@"[%@] %@", className, methodName];
            id newBlock = ^(id self) {
                if (originalIMP)
                {
                    ((void (*)(id, SEL))originalIMP)(self, sel);
                }
                if (!s_isTracking && !s_isDeepTracking)
                {
                    return;
                }
                if (s_isTracking)
                {
                    @synchronized(s_trackedMethods)
                    {
                        [s_trackedMethods addObject:@{
                            @"method": fullMethodName,
                            @"time": @([[NSDate date] timeIntervalSinceDate:s_trackStartTime])
                        }];
                    }
                }
                if (s_isDeepTracking)
                {
                    @synchronized(s_deepTrackedMethods)
                    {
                        [s_deepTrackedMethods addObject:@{
                            @"method": fullMethodName,
                            @"time": @([[NSDate date] timeIntervalSinceDate:s_deepTrackStartTime])
                        }];
                    }
                }
            };
            IMP newIMP = imp_implementationWithBlock(newBlock);
            method_setImplementation(methods[i], newIMP);
        }
    }
    free(methods);
}

static void startDeepTracking(void)
{
    s_deepTrackedMethods = [NSMutableArray array];
    s_isDeepTracking = YES;
    s_deepTrackStartTime = [NSDate date];

    unsigned int classCount = 0;
    Class *allClasses = objc_copyClassList(&classCount);
    for (unsigned int i = 0; i < classCount; i++)
    {
        NSString *cn = NSStringFromClass(allClasses[i]);
        if ([cn hasPrefix:@"GDT"] ||
            [cn hasPrefix:@"GDTT"] ||
            [cn hasPrefix:@"GDK"] ||
            [cn containsString:@"Splash"] ||
            [cn containsString:@"Skip"])
        {
            hookAllMethodsOfClass(allClasses[i]);
        }
    }
    free(allClasses);
}

static NSArray *stopDeepTracking(void)
{
    s_isDeepTracking = NO;
    NSArray *result = [s_deepTrackedMethods copy];
    s_deepTrackedMethods = nil;
    s_deepTrackStartTime = nil;
    return result;
}

// ==================== 前置声明 ====================
static void saveToFile(NSString *log);
static void analyzeTouchView(UIView *v, CGPoint pt);
static void saveRule(NSDictionary *r);
static void applyAllSavedRules(void);
static UIView *findMatchingView(UIView *root, NSDictionary *r);
static void clearAllRules(void);
static void clearCustomRules(void);
static void showToast(NSString *msg);
static UIWindow *getKeyWindow(void);
static UIView *findSkipLabelInView(UIView *root);
static void saveCustomRule(NSDictionary *r);
static void applyCustomRules(void);

static NSDate *s_lastAnalysisTime = nil;
static const NSTimeInterval kMinAnalysisInterval = 0.3;
static NSDate *s_twoFingerStart = nil;
static const NSTimeInterval kTwoFingerHoldDuration = 0.5;
static NSDate *s_ignoreSingleTouchUntil = nil;

static UIWindow *getKeyWindow(void)
{
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes)
    {
        if ([s isKindOfClass:[UIWindowScene class]] && s.activationState == UISceneActivationStateForegroundActive)
        {
            for (UIWindow *w in [(UIWindowScene *)s windows])
            {
                if (w.isKeyWindow)
                {
                    return w;
                }
            }
        }
    }
    return nil;
}

// ==================== 悬浮窗 ====================
@class AdInspectorPanel;

@interface AdInspectorWindow : UIWindow
@property (nonatomic, weak) AdInspectorPanel *panel;
@end

static AdInspectorWindow *s_floatWindow = nil;

@implementation AdInspectorWindow

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self)
    {
        self.windowLevel = CGFLOAT_MAX;
        self.backgroundColor = [UIColor clearColor];
        self.hidden = NO;
        self.userInteractionEnabled = YES;
        s_floatWindow = self;
    }
    return self;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self || (id)hit == (id)self.panel)
    {
        return nil;
    }
    while (hit && (id)hit != (id)self.panel)
    {
        if (hit.tag >= 1001 && hit.tag <= 1025)
        {
            return hit;
        }
        hit = hit.superview;
    }
    return nil;
}

- (void)setHidden:(BOOL)hidden
{
    if (hidden && !self.isHidden)
    {
        return;
    }
    [super setHidden:hidden];
}

@end

// ==================== 面板 ====================
@interface AdInspectorPanel : UIView <UITextFieldDelegate>
@property (nonatomic, strong) UITextView *logTextView;
@property (nonatomic, strong) NSMutableString *logBuffer;
@property (nonatomic, strong) UITextField *targetViewField;
@property (nonatomic, strong) UITextField *keyPathField;
@property (nonatomic, strong) UITextField *methodNameField;
+ (instancetype)shared;
- (void)showLog:(NSString *)log;
- (void)forceShow;
- (void)hidePanel;
- (void)addCustomRuleFromFields;
- (void)testCustomRules;
- (void)copyLog;
- (void)toggleDeepTracking:(UIButton *)sender;
@end

@implementation AdInspectorPanel

+ (instancetype)shared
{
    static AdInspectorPanel *i = nil;
    static dispatch_once_t t;
    dispatch_once(&t, ^{
        i = [[AdInspectorPanel alloc] initWithFrame:CGRectMake(5, 180, [UIScreen mainScreen].bounds.size.width - 10, 360)];
    });
    return i;
}

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self)
    {
        self.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.90];
        self.layer.cornerRadius = 10;
        self.layer.borderWidth = 1.5;
        self.layer.borderColor = [UIColor cyanColor].CGColor;
        self.userInteractionEnabled = YES;
        self.clipsToBounds = NO;
        self.hidden = YES;

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(kbShow:) name:UIKeyboardWillShowNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(kbHide:) name:UIKeyboardWillHideNotification object:nil];

        UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, 180, 20)];
        t.text = @"🔍 AdInspector";
        t.textColor = [UIColor cyanColor];
        t.font = [UIFont boldSystemFontOfSize:12];
        t.tag = 1001;
        [self addSubview:t];

        UIButton *copyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        copyBtn.frame = CGRectMake(self.bounds.size.width - 235, 3, 55, 30);
        [copyBtn setTitle:@"📋复制" forState:UIControlStateNormal];
        [copyBtn setTitleColor:[UIColor colorWithRed:0.0 green:1.0 blue:0.5 alpha:1.0] forState:UIControlStateNormal];
        copyBtn.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
        copyBtn.tag = 1021;
        [copyBtn addTarget:self action:@selector(copyLog) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:copyBtn];

        UILabel *l1 = [[UILabel alloc] initWithFrame:CGRectMake(12, 34, 80, 20)];
        l1.text = @"目标视图类:";
        l1.textColor = [UIColor whiteColor];
        l1.font = [UIFont systemFontOfSize:11];
        [self addSubview:l1];

        _targetViewField = [[UITextField alloc] initWithFrame:CGRectMake(95, 32, self.bounds.size.width - 110, 26)];
        _targetViewField.borderStyle = UITextBorderStyleRoundedRect;
        _targetViewField.backgroundColor = [UIColor darkGrayColor];
        _targetViewField.textColor = [UIColor whiteColor];
        _targetViewField.font = [UIFont systemFontOfSize:12];
        _targetViewField.placeholder = @"如 GDTDLRootView";
        _targetViewField.tag = 1011;
        _targetViewField.delegate = self;
        [self addSubview:_targetViewField];

        UILabel *l2 = [[UILabel alloc] initWithFrame:CGRectMake(12, 64, 80, 20)];
        l2.text = @"KVC路径:";
        l2.textColor = [UIColor whiteColor];
        l2.font = [UIFont systemFontOfSize:11];
        [self addSubview:l2];

        _keyPathField = [[UITextField alloc] initWithFrame:CGRectMake(95, 62, self.bounds.size.width - 110, 26)];
        _keyPathField.borderStyle = UITextBorderStyleRoundedRect;
        _keyPathField.backgroundColor = [UIColor darkGrayColor];
        _keyPathField.textColor = [UIColor whiteColor];
        _keyPathField.font = [UIFont systemFontOfSize:12];
        _keyPathField.placeholder = @"self";
        _keyPathField.tag = 1012;
        _keyPathField.delegate = self;
        [self addSubview:_keyPathField];

        UILabel *l3 = [[UILabel alloc] initWithFrame:CGRectMake(12, 94, 80, 20)];
        l3.text = @"方法名:";
        l3.textColor = [UIColor whiteColor];
        l3.font = [UIFont systemFontOfSize:11];
        [self addSubview:l3];

        _methodNameField = [[UITextField alloc] initWithFrame:CGRectMake(95, 92, self.bounds.size.width - 110, 26)];
        _methodNameField.borderStyle = UITextBorderStyleRoundedRect;
        _methodNameField.backgroundColor = [UIColor darkGrayColor];
        _methodNameField.textColor = [UIColor whiteColor];
        _methodNameField.font = [UIFont systemFontOfSize:12];
        _methodNameField.placeholder = @"AdInspector_SkipSequence";
        _methodNameField.tag = 1013;
        _methodNameField.delegate = self;
        [self addSubview:_methodNameField];

        UIButton *addBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        addBtn.frame = CGRectMake(12, 126, 60, 30);
        [addBtn setTitle:@"添加" forState:UIControlStateNormal];
        [addBtn setTitleColor:[UIColor greenColor] forState:UIControlStateNormal];
        addBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
        addBtn.tag = 1014;
        [addBtn addTarget:self action:@selector(addCustomRuleFromFields) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:addBtn];

        UIButton *testBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        testBtn.frame = CGRectMake(80, 126, 60, 30);
        [testBtn setTitle:@"测试" forState:UIControlStateNormal];
        [testBtn setTitleColor:[UIColor yellowColor] forState:UIControlStateNormal];
        testBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
        testBtn.tag = 1015;
        [testBtn addTarget:self action:@selector(testCustomRules) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:testBtn];

        UIButton *p1 = [UIButton buttonWithType:UIButtonTypeSystem];
        p1.frame = CGRectMake(148, 126, 60, 30);
        [p1 setTitle:@"预设1" forState:UIControlStateNormal];
        [p1 setTitleColor:[UIColor cyanColor] forState:UIControlStateNormal];
        p1.titleLabel.font = [UIFont systemFontOfSize:11];
        p1.tag = 1016;
        [p1 addTarget:self action:@selector(fillPreset1) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:p1];

        UIButton *trkBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        trkBtn.frame = CGRectMake(12, 160, 90, 30);
        [trkBtn setTitle:@"▶开始追踪" forState:UIControlStateNormal];
        [trkBtn setTitleColor:[UIColor colorWithRed:1.0 green:0.5 blue:0.0 alpha:1.0] forState:UIControlStateNormal];
        trkBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11];
        trkBtn.tag = 1018;
        [trkBtn addTarget:self action:@selector(toggleTracking:) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:trkBtn];

        UIButton *deepBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        deepBtn.frame = CGRectMake(110, 160, 100, 30);
        [deepBtn setTitle:@"🔬深度追踪" forState:UIControlStateNormal];
        [deepBtn setTitleColor:[UIColor colorWithRed:1.0 green:0.3 blue:0.7 alpha:1.0] forState:UIControlStateNormal];
        deepBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11];
        deepBtn.tag = 1022;
        [deepBtn addTarget:self action:@selector(toggleDeepTracking:) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:deepBtn];

        UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        closeBtn.frame = CGRectMake(self.bounds.size.width - 45, 3, 40, 30);
        [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
        [closeBtn setTitleColor:[UIColor redColor] forState:UIControlStateNormal];
        closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:20];
        closeBtn.tag = 1002;
        [closeBtn addTarget:self action:@selector(hidePanel) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:closeBtn];

        UIButton *clearBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        clearBtn.frame = CGRectMake(self.bounds.size.width - 135, 3, 45, 30);
        [clearBtn setTitle:@"清空" forState:UIControlStateNormal];
        [clearBtn setTitleColor:[UIColor orangeColor] forState:UIControlStateNormal];
        clearBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
        clearBtn.tag = 1003;
        [clearBtn addTarget:self action:@selector(clearRulesTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:clearBtn];

        UIView *handle = [[UIView alloc] initWithFrame:CGRectMake(self.bounds.size.width / 2 - 15, 4, 30, 4)];
        handle.backgroundColor = [UIColor colorWithWhite:0.4 alpha:0.6];
        handle.layer.cornerRadius = 2;
        handle.tag = 1004;
        [self addSubview:handle];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];

        CGFloat tvY = 196;
        _logTextView = [[UITextView alloc] initWithFrame:CGRectMake(5, tvY, self.bounds.size.width - 10, self.bounds.size.height - tvY - 5)];
        _logTextView.backgroundColor = [UIColor clearColor];
        _logTextView.textColor = [UIColor greenColor];
        _logTextView.font = [UIFont fontWithName:@"Courier" size:10] ?: [UIFont systemFontOfSize:10];
        _logTextView.editable = NO;
        _logTextView.selectable = YES;
        _logTextView.tag = 1005;
        _logTextView.textContainerInset = UIEdgeInsetsMake(2, 2, 2, 2);
        [self addSubview:_logTextView];

        _logBuffer = [NSMutableString string];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)kbShow:(NSNotification *)n
{
    s_isKeyboardVisible = YES;
    NSDictionary *i = n.userInfo;
    CGRect k = [i[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGFloat kh = k.size.height;
    CGFloat pb = CGRectGetMaxY(self.frame);
    CGFloat sh = [UIScreen mainScreen].bounds.size.height;
    CGFloat off = pb - (sh - kh) + 20;
    if (off > 0)
    {
        [UIView animateWithDuration:[i[UIKeyboardAnimationDurationUserInfoKey] doubleValue] animations:^{
            self.center = CGPointMake(self.center.x, self.center.y - off);
        }];
    }
}

- (void)kbHide:(NSNotification *)n
{
    s_isKeyboardVisible = NO;
    [UIView animateWithDuration:[n.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue] animations:^{
        self.center = CGPointMake(self.center.x, 180 + self.bounds.size.height / 2);
    }];
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf
{
    [tf resignFirstResponder];
    return YES;
}

- (void)handlePan:(UIPanGestureRecognizer *)p
{
    CGPoint t = [p translationInView:self];
    self.center = CGPointMake(self.center.x + t.x, self.center.y + t.y);
    [p setTranslation:CGPointZero inView:self];
}

- (void)hidePanel
{
    self.hidden = YES;
}

- (void)fillPreset1
{
    self.targetViewField.text = @"GDTDLRootView";
    self.keyPathField.text = @"self";
    self.methodNameField.text = @"AdInspector_SkipSequence";
}

- (void)copyLog
{
    NSString *text = self.logBuffer;
    if (text.length == 0)
    {
        showToast(@"⚠️ 日志为空");
        return;
    }
    [[UIPasteboard generalPasteboard] setString:text];
    showToast(@"✅ 已复制到剪贴板");
}

- (void)addCustomRuleFromFields
{
    NSString *tv = self.targetViewField.text;
    NSString *kp = self.keyPathField.text;
    NSString *mn = self.methodNameField.text;
    [self.targetViewField resignFirstResponder];
    [self.keyPathField resignFirstResponder];
    [self.methodNameField resignFirstResponder];
    if (tv.length == 0 || kp.length == 0 || mn.length == 0)
    {
        showToast(@"⚠️ 请填写完整规则");
        return;
    }
    NSDictionary *r = @{
        @"targetView": tv,
        @"keyPath": kp,
        @"methodName": mn,
        @"description": [NSString stringWithFormat:@"%@→%@", tv, mn]
    };
    saveCustomRule(r);
    [self showLog:[NSString stringWithFormat:@"\n✅ 已添加: %@ → [%@] %@\n", tv, kp, mn]];
    showToast(@"✅ 规则已添加");
}

- (void)testCustomRules
{
    applyCustomRules();
}

- (void)clearRulesTapped
{
    clearAllRules();
    clearCustomRules();
    [self showLog:@"\n🗑️ 已清空所有规则\n"];
    showToast(@"🗑️ 规则已清除");
}

- (void)toggleTracking:(UIButton *)sender
{
    if (s_isTracking)
    {
        stopTracking();
        [sender setTitle:@"▶开始追踪" forState:UIControlStateNormal];
        [sender setTitleColor:[UIColor colorWithRed:1.0 green:0.5 blue:0.0 alpha:1.0] forState:UIControlStateNormal];
        if (s_trackedMethods.count > 0)
        {
            NSMutableString *o = [NSMutableString stringWithFormat:@"\n📊 追踪结果 (%lu个):\n", (unsigned long)s_trackedMethods.count];
            for (NSDictionary *e in s_trackedMethods)
            {
                [o appendFormat:@"  +%.2fs → %@\n", [e[@"time"] doubleValue], e[@"method"]];
            }
            [self showLog:o];
        }
        else
        {
            [self showLog:@"\n⚠️ 未捕获到方法调用\n"];
        }
    }
    else
    {
        startTracking();
        [sender setTitle:@"⏹停止追踪" forState:UIControlStateNormal];
        [sender setTitleColor:[UIColor redColor] forState:UIControlStateNormal];
        [self showLog:@"\n🔍 开始追踪...\n"];
    }
}

- (void)toggleDeepTracking:(UIButton *)sender
{
    if (s_isDeepTracking)
    {
        NSArray *methods = stopDeepTracking();
        [sender setTitle:@"🔬深度追踪" forState:UIControlStateNormal];
        [sender setTitleColor:[UIColor colorWithRed:1.0 green:0.3 blue:0.7 alpha:1.0] forState:UIControlStateNormal];
        if (methods.count > 0)
        {
            NSMutableString *o = [NSMutableString stringWithFormat:@"\n🔬 深度追踪结果 (%lu个方法):\n", (unsigned long)methods.count];
            for (NSDictionary *e in methods)
            {
                [o appendFormat:@"  +%.3fs → %@\n", [e[@"time"] doubleValue], e[@"method"]];
            }
            [self showLog:o];
        }
        else
        {
            [self showLog:@"\n⚠️ 深度追踪未捕获到方法调用\n"];
        }
    }
    else
    {
        startDeepTracking();
        [sender setTitle:@"⏹停止深度" forState:UIControlStateNormal];
        [sender setTitleColor:[UIColor redColor] forState:UIControlStateNormal];
        [self showLog:@"\n🔬 深度追踪已开启\n"];
    }
}

- (void)forceShow
{
    if (!s_floatWindow)
    {
        UIWindowScene *as = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes)
        {
            if ([s isKindOfClass:[UIWindowScene class]] && s.activationState == UISceneActivationStateForegroundActive)
            {
                as = (UIWindowScene *)s;
                break;
            }
        }
        if (as)
        {
            s_floatWindow = [[AdInspectorWindow alloc] initWithFrame:as.coordinateSpace.bounds];
            s_floatWindow.windowScene = as;
            [s_floatWindow addSubview:self];
            self.frame = CGRectMake(5, 180, s_floatWindow.bounds.size.width - 10, 360);
            s_floatWindow.panel = self;
        }
    }
    else
    {
        if (!self.superview)
        {
            [s_floatWindow addSubview:self];
            self.frame = CGRectMake(5, 180, s_floatWindow.bounds.size.width - 10, 360);
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

- (void)showLog:(NSString *)log
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.logBuffer appendString:log];
        if (self.logBuffer.length > 8000)
        {
            [self.logBuffer deleteCharactersInRange:NSMakeRange(0, self.logBuffer.length - 8000)];
        }
        self.logTextView.text = self.logBuffer;
        if (self.logTextView.text.length > 0)
        {
            [self.logTextView scrollRangeToVisible:NSMakeRange(self.logTextView.text.length - 1, 1)];
        }
    });
}

@end

// ==================== Toast / 工具 ====================
static void showToast(NSString *m)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *hw = getKeyWindow();
        if (!hw)
        {
            return;
        }
        UIView *t = [[UIView alloc] init];
        t.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
        t.layer.cornerRadius = 12;
        UILabel *l = [[UILabel alloc] init];
        l.text = m;
        l.textColor = [UIColor whiteColor];
        l.font = [UIFont boldSystemFontOfSize:14];
        l.numberOfLines = 0;
        l.textAlignment = NSTextAlignmentCenter;
        [t addSubview:l];
        CGSize ms = CGSizeMake([UIScreen mainScreen].bounds.size.width - 60, CGFLOAT_MAX);
        CGRect tr = [m boundingRectWithSize:ms options:NSStringDrawingUsesLineFragmentOrigin attributes:@{NSFontAttributeName: l.font} context:nil];
        CGFloat w = tr.size.width + 30;
        CGFloat h = tr.size.height + 16;
        l.frame = CGRectMake(15, 8, tr.size.width, tr.size.height);
        CGPoint c = CGPointMake(hw.bounds.size.width / 2, hw.bounds.size.height - 150);
        t.frame = CGRectMake(c.x - w / 2, c.y - h / 2, w, h);
        t.layer.zPosition = CGFLOAT_MAX;
        [hw addSubview:t];
        [UIView animateWithDuration:0.3 delay:1.5 options:UIViewAnimationOptionCurveEaseOut animations:^{
            t.alpha = 0;
        } completion:^(BOOL f) {
            [t removeFromSuperview];
        }];
    });
}

// ==================== 规则管理 ====================
static void saveRule(NSDictionary *r)
{
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSArray *ex = [ud arrayForKey:kRulesKey] ?: @[];
    NSInteger ei = -1;
    for (NSInteger i = 0; i < ex.count; i++)
    {
        NSDictionary *x = ex[i];
        if ([x[@"buttonClass"] isEqualToString:r[@"buttonClass"]] &&
            [x[@"buttonTextPattern"] isEqualToString:r[@"buttonTextPattern"]] &&
            [x[@"hierarchyChain"] isEqualToArray:r[@"hierarchyChain"]])
        {
            ei = i;
            break;
        }
    }
    NSMutableArray *nr = [ex mutableCopy];
    if (ei >= 0)
    {
        [nr replaceObjectAtIndex:ei withObject:r];
    }
    else
    {
        [nr addObject:r];
    }
    [ud setObject:nr forKey:kRulesKey];
    [ud synchronize];
}


static void clearAllRules(void)
{
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kRulesKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

static void saveCustomRule(NSDictionary *r)
{
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSArray *ex = [ud arrayForKey:kCustomRulesKey] ?: @[];
    for (NSDictionary *x in ex)
    {
        if ([x[@"targetView"] isEqualToString:r[@"targetView"]] &&
            [x[@"keyPath"] isEqualToString:r[@"keyPath"]] &&
            [x[@"methodName"] isEqualToString:r[@"methodName"]])
        {
            return;
        }
    }
    NSMutableArray *nr = [ex mutableCopy];
    [nr addObject:r];
    [ud setObject:nr forKey:kCustomRulesKey];
    [ud synchronize];
}

static void clearCustomRules(void)
{
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kCustomRulesKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

// ==================== 降维打击 ====================
static void applyCustomRules(void)
{
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSArray *cr = [ud arrayForKey:kCustomRulesKey];
    if (!cr.count)
    {
        return;
    }

    for (NSDictionary *r in cr)
    {
        NSString *mn = r[@"methodName"];
        if (!mn)
        {
            continue;
        }

        if ([mn isEqualToString:@"AdInspector_SkipSequence"])
        {
            [[AdInspectorPanel shared] showLog:@"\n🚀 降维打击：移除广告视图...\n"];

            BOOL removed = NO;

            for (UIWindow *w in getAllWindows())
            {
                if ([NSStringFromClass([w class]) isEqualToString:@"AdInspectorWindow"])
                {
                    continue;
                }

                UIView *skipView = findSkipLabelInView(w);
                if (skipView)
                {
                    NSString *cn = NSStringFromClass([w class]);

                    // 非标准 window → 直接隐藏
                    if (![cn isEqualToString:@"UIWindow"] &&
                        ![cn hasPrefix:@"_UI"] &&
                        ![cn hasPrefix:@"UIK"])
                    {
                        [[AdInspectorPanel shared] showLog:[NSString stringWithFormat:@"  🔍 发现广告窗口: %@\n", cn]];
                        w.hidden = YES;
                        w.windowLevel = -1000;
                        [w resignKeyWindow];
                        removed = YES;
                        [[AdInspectorPanel shared] showLog:@"  ✅ 已隐藏广告窗口\n"];
                    }
                    else
                    {
                        // 标准窗口上的广告视图
                        UIView *adRoot = skipView;
                        while (adRoot.superview && ![adRoot.superview isKindOfClass:[UIWindow class]])
                        {
                            adRoot = adRoot.superview;
                        }

                        NSString *rootCN = NSStringFromClass([adRoot class]);
                        if ([rootCN containsString:@"Splash"] ||
                            [rootCN containsString:@"GDT"] ||
                            [rootCN containsString:@"Ad"])
                        {
                            [adRoot removeFromSuperview];
                            removed = YES;
                            [[AdInspectorPanel shared] showLog:[NSString stringWithFormat:@"  ✅ 已移除广告视图: %@\n", rootCN]];
                        }
                        else
                        {
                            // 向上查找广告容器
                            UIView *adSubtree = skipView;
                            while (adSubtree.superview && ![adSubtree.superview isKindOfClass:[UIWindow class]])
                            {
                                NSString *parentCN = NSStringFromClass([adSubtree.superview class]);
                                if ([parentCN containsString:@"Splash"] ||
                                    [parentCN containsString:@"GDT"] ||
                                    [parentCN containsString:@"Ad"])
                                {
                                    [adSubtree.superview removeFromSuperview];
                                    removed = YES;
                                    [[AdInspectorPanel shared] showLog:[NSString stringWithFormat:@"  ✅ 已移除广告容器: %@\n", parentCN]];
                                    break;
                                }
                                adSubtree = adSubtree.superview;
                            }
                        }
                    }

                    if (removed)
                    {
                        break;
                    }
                }
            }

            // 恢复主窗口
            for (UIWindow *w in getAllWindows())
            {
                if ([NSStringFromClass([w class]) isEqualToString:@"AdInspectorWindow"])
                {
                    continue;
                }
                if (!w.hidden && w.alpha > 0)
                {
                    [w makeKeyAndVisible];
                    [[AdInspectorPanel shared] showLog:[NSString stringWithFormat:@"  ✅ %@ 已成为 key window\n", NSStringFromClass([w class])]];
                    break;
                }
            }

            if (!removed)
            {
                [[AdInspectorPanel shared] showLog:@"  ⚠️ 未找到广告视图，可能已关闭\n"];
            }

            [[AdInspectorPanel shared] showLog:@"🎉 降维打击完毕\n"];
            return;
        }
    }
}

static void applyAllSavedRules(void)
{
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSArray *cr = [ud arrayForKey:kCustomRulesKey] ?: @[];
    if (cr.count > 0)
    {
        applyCustomRules();
    }
}

static BOOL isSkipText(NSString *t)
{
    if (!t || t.length == 0)
    {
        return NO;
    }
    for (NSString *k in @[@"跳过", @"广告", @"关闭", @"×", @"x", @"X", @"close", @"skip", @"Skip", @"Close", @"SKIP", @"CLOSE"])
    {
        if ([t rangeOfString:k options:NSCaseInsensitiveSearch].location != NSNotFound && t.length <= 15)
        {
            return YES;
        }
    }
    return NO;
}

static UIView *findSkipLabelInView(UIView *rt)
{
    if ([rt isKindOfClass:[AdInspectorPanel class]] || (rt.tag >= 1001 && rt.tag <= 1025))
    {
        return nil;
    }
    NSString *ct = nil;
    if ([rt isKindOfClass:[UIButton class]])
    {
        ct = [(UIButton *)rt titleForState:UIControlStateNormal];
    }
    else if ([rt isKindOfClass:[UILabel class]])
    {
        ct = [(UILabel *)rt text] ?: [(UILabel *)rt attributedText].string;
    }
    if (!ct)
    {
        ct = rt.accessibilityLabel;
    }
    if (isSkipText(ct))
    {
        return rt;
    }
    for (UIView *sb in rt.subviews)
    {
        UIView *f = findSkipLabelInView(sb);
        if (f)
        {
            return f;
        }
    }
    return nil;
}

static void analyzeTouchView(UIView *v, CGPoint pt)
{
    if (!v)
    {
        return;
    }
    if ([v isDescendantOfView:[AdInspectorPanel shared]] ||
        [NSStringFromClass([v.window class]) isEqualToString:@"AdInspectorWindow"] ||
        (v.tag >= 1001 && v.tag <= 1025))
    {
        return;
    }
    NSDate *n = [NSDate date];
    if (s_lastAnalysisTime && [n timeIntervalSinceDate:s_lastAnalysisTime] < kMinAnalysisInterval)
    {
        return;
    }
    s_lastAnalysisTime = n;

    UIView *av = findSkipLabelInView(v);
    if (!av)
    {
        return;
    }

    @try
    {
        NSMutableArray *ca = [NSMutableArray array];
        UIView *cur = av;
        while (cur && ![cur isKindOfClass:[UIWindow class]])
        {
            [ca addObject:NSStringFromClass([cur class])];
            cur = cur.superview;
        }

        NSString *bt = nil;
        if ([av isKindOfClass:[UIButton class]])
        {
            bt = [(UIButton *)av titleForState:UIControlStateNormal];
        }
        else if ([av isKindOfClass:[UILabel class]])
        {
            bt = [(UILabel *)av text] ?: [(UILabel *)av attributedText].string;
        }
        if (bt.length == 0)
        {
            bt = av.accessibilityLabel;
        }
        if (bt.length > 0)
        {
            NSMutableDictionary *rule = [NSMutableDictionary dictionary];
            rule[@"buttonClass"] = NSStringFromClass([av class]);
            rule[@"buttonTextPattern"] = bt;
            rule[@"hierarchyChain"] = ca;
            rule[@"triggerType"] = @"gesture";
            saveRule(rule);
        }
    }
    @catch (NSException *e)
    {
    }
}

// ==================== Hook ====================
%hook UIApplication
- (void)sendEvent:(UIEvent *)e
{
    %orig;
    if (e.type == UIEventTypeTouches)
    {
        NSSet *ts = [e allTouches];
        if (ts.count >= 2)
        {
            BOOL as = YES;
            for (UITouch *t in ts)
            {
                if (t.phase == UITouchPhaseEnded || t.phase == UITouchPhaseCancelled)
                {
                    as = NO;
                    break;
                }
            }
            if (as && !s_twoFingerStart)
            {
                s_twoFingerStart = [NSDate date];
            }
            if (s_twoFingerStart && [[NSDate date] timeIntervalSinceDate:s_twoFingerStart] >= kTwoFingerHoldDuration)
            {
                AdInspectorPanel *p = [AdInspectorPanel shared];
                if (p.hidden)
                {
                    [p forceShow];
                }
                s_twoFingerStart = nil;
                s_ignoreSingleTouchUntil = [NSDate dateWithTimeIntervalSinceNow:0.5];
            }
        }
        else
        {
            s_twoFingerStart = nil;
        }
        if (ts.count == 1)
        {
            UITouch *t = [ts anyObject];
            if (t.phase == UITouchPhaseEnded && t.view && !s_twoFingerStart)
            {
                if (!s_ignoreSingleTouchUntil || [[NSDate date] compare:s_ignoreSingleTouchUntil] != NSOrderedAscending)
                {
                    analyzeTouchView(t.view, [t locationInView:nil]);
                }
            }
        }
    }
}
%end

// ==================== 初始化 ====================
%ctor
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindowScene *as = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes)
        {
            if ([s isKindOfClass:[UIWindowScene class]] && s.activationState == UISceneActivationStateForegroundActive)
            {
                as = (UIWindowScene *)s;
                break;
            }
        }
        if (as)
        {
            s_floatWindow = [[AdInspectorWindow alloc] initWithFrame:as.coordinateSpace.bounds];
            s_floatWindow.windowScene = as;
            AdInspectorPanel *p = [AdInspectorPanel shared];
            p.frame = CGRectMake(5, 180, s_floatWindow.bounds.size.width - 10, 360);
            [s_floatWindow addSubview:p];
            s_floatWindow.panel = p;
        }

        showToast(@"🔍 已激活 | 双指呼面板 | 降维打击");
        if (isFlexingAvailable())
        {
            raiseFlexingWindow();
        }
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
            applyAllSavedRules();
            if (s_floatWindow && !s_isKeyboardVisible)
            {
                s_floatWindow.hidden = NO;
            }
            if (isFlexingAvailable())
            {
                raiseFlexingWindow();
            }
        }];
    });
}
