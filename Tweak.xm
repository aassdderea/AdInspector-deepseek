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
    if (s_isKeyboardVisible) return;
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
    if (!cls) return;
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
                if (!s_isTracking && !s_isDeepTracking) return;
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
    hookAllMethodsOfClass(NSClassFromString(@"GDTDLBusinessManager"));
    hookAllMethodsOfClass(NSClassFromString(@"GDTDLRootView"));
    hookAllMethodsOfClass(NSClassFromString(@"GDTSplashDLView"));
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
static void showToast(NSString *msg);
static UIWindow *getKeyWindow(void);
static void saveCustomRule(NSDictionary *r);
static void applyCustomRules(void);
static void applyAllSavedRules(void);
static void clearAllRules(void);
static void clearCustomRules(void);
static UIView *findViewOfClass(UIView *root, NSString *cn);
static id getObjectByKeyPath(id obj, NSString *kp);

static NSDate *s_twoFingerStart = nil;
static const NSTimeInterval kTwoFingerHoldDuration = 0.5;
static NSDate *s_ignoreSingleTouchUntil = nil;

static UIWindow *getKeyWindow(void)
{
    for (UIWindow *w in getAllWindows())
    {
        if ([NSStringFromClass([w class]) isEqualToString:@"AdInspectorWindow"]) continue;
        if (w.isKeyWindow) return w;
    }
    for (UIWindow *w in getAllWindows())
    {
        if ([NSStringFromClass([w class]) isEqualToString:@"AdInspectorWindow"]) continue;
        if (!w.hidden && w.alpha > 0) return w;
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
    if (hit == self || (id)hit == (id)self.panel) return nil;
    while (hit && (id)hit != (id)self.panel)
    {
        if (hit.tag >= 1001 && hit.tag <= 1025) return hit;
        hit = hit.superview;
    }
    return nil;
}
- (void)setHidden:(BOOL)hidden
{
    if (!(hidden && !self.isHidden)) [super setHidden:hidden];
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
        t.text = @"🔍 AdInspector"; t.textColor = [UIColor cyanColor]; t.font = [UIFont boldSystemFontOfSize:12]; t.tag = 1001; [self addSubview:t];

        UIButton *copyBtn = [UIButton buttonWithType:UIButtonTypeSystem]; copyBtn.frame = CGRectMake(self.bounds.size.width - 235, 3, 55, 30);
        [copyBtn setTitle:@"📋复制" forState:UIControlStateNormal]; [copyBtn setTitleColor:[UIColor colorWithRed:0.0 green:1.0 blue:0.5 alpha:1.0] forState:UIControlStateNormal];
        copyBtn.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold]; copyBtn.tag = 1021; [copyBtn addTarget:self action:@selector(copyLog) forControlEvents:UIControlEventTouchUpInside]; [self addSubview:copyBtn];

        UILabel *l1 = [[UILabel alloc] initWithFrame:CGRectMake(12, 34, 80, 20)]; l1.text = @"目标类:"; l1.textColor = [UIColor whiteColor]; l1.font = [UIFont systemFontOfSize:11]; [self addSubview:l1];
        _targetViewField = [[UITextField alloc] initWithFrame:CGRectMake(70, 32, self.bounds.size.width - 85, 26)]; _targetViewField.borderStyle = UITextBorderStyleRoundedRect; _targetViewField.backgroundColor = [UIColor darkGrayColor]; _targetViewField.textColor = [UIColor whiteColor]; _targetViewField.font = [UIFont systemFontOfSize:12]; _targetViewField.placeholder = @"GDTDLBusinessManager"; _targetViewField.tag = 1011; _targetViewField.delegate = self; [self addSubview:_targetViewField];

        UILabel *l2 = [[UILabel alloc] initWithFrame:CGRectMake(12, 64, 80, 20)]; l2.text = @"KVC路径:"; l2.textColor = [UIColor whiteColor]; l2.font = [UIFont systemFontOfSize:11]; [self addSubview:l2];
        _keyPathField = [[UITextField alloc] initWithFrame:CGRectMake(70, 62, self.bounds.size.width - 85, 26)]; _keyPathField.borderStyle = UITextBorderStyleRoundedRect; _keyPathField.backgroundColor = [UIColor darkGrayColor]; _keyPathField.textColor = [UIColor whiteColor]; _keyPathField.font = [UIFont systemFontOfSize:12]; _keyPathField.placeholder = @"self"; _keyPathField.tag = 1012; _keyPathField.delegate = self; [self addSubview:_keyPathField];

        UILabel *l3 = [[UILabel alloc] initWithFrame:CGRectMake(12, 94, 80, 20)]; l3.text = @"方法名:"; l3.textColor = [UIColor whiteColor]; l3.font = [UIFont systemFontOfSize:11]; [self addSubview:l3];
        _methodNameField = [[UITextField alloc] initWithFrame:CGRectMake(70, 92, self.bounds.size.width - 85, 26)]; _methodNameField.borderStyle = UITextBorderStyleRoundedRect; _methodNameField.backgroundColor = [UIColor darkGrayColor]; _methodNameField.textColor = [UIColor whiteColor]; _methodNameField.font = [UIFont systemFontOfSize:12]; _methodNameField.placeholder = @"onDestroy"; _methodNameField.tag = 1013; _methodNameField.delegate = self; [self addSubview:_methodNameField];

        UIButton *addBtn = [UIButton buttonWithType:UIButtonTypeSystem]; addBtn.frame = CGRectMake(12, 126, 60, 30); [addBtn setTitle:@"添加" forState:UIControlStateNormal]; [addBtn setTitleColor:[UIColor greenColor] forState:UIControlStateNormal]; addBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12]; addBtn.tag = 1014; [addBtn addTarget:self action:@selector(addCustomRuleFromFields) forControlEvents:UIControlEventTouchUpInside]; [self addSubview:addBtn];
        UIButton *testBtn = [UIButton buttonWithType:UIButtonTypeSystem]; testBtn.frame = CGRectMake(80, 126, 60, 30); [testBtn setTitle:@"测试" forState:UIControlStateNormal]; [testBtn setTitleColor:[UIColor yellowColor] forState:UIControlStateNormal]; testBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12]; testBtn.tag = 1015; [testBtn addTarget:self action:@selector(testCustomRules) forControlEvents:UIControlEventTouchUpInside]; [self addSubview:testBtn];
        UIButton *p1 = [UIButton buttonWithType:UIButtonTypeSystem]; p1.frame = CGRectMake(148, 126, 60, 30); [p1 setTitle:@"预设1" forState:UIControlStateNormal]; [p1 setTitleColor:[UIColor cyanColor] forState:UIControlStateNormal]; p1.titleLabel.font = [UIFont systemFontOfSize:11]; p1.tag = 1016; [p1 addTarget:self action:@selector(fillPreset1) forControlEvents:UIControlEventTouchUpInside]; [self addSubview:p1];
        UIButton *trkBtn = [UIButton buttonWithType:UIButtonTypeSystem]; trkBtn.frame = CGRectMake(12, 160, 90, 30); [trkBtn setTitle:@"▶开始追踪" forState:UIControlStateNormal]; [trkBtn setTitleColor:[UIColor colorWithRed:1.0 green:0.5 blue:0.0 alpha:1.0] forState:UIControlStateNormal]; trkBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11]; trkBtn.tag = 1018; [trkBtn addTarget:self action:@selector(toggleTracking:) forControlEvents:UIControlEventTouchUpInside]; [self addSubview:trkBtn];
        UIButton *deepBtn = [UIButton buttonWithType:UIButtonTypeSystem]; deepBtn.frame = CGRectMake(110, 160, 100, 30); [deepBtn setTitle:@"🔬深度追踪" forState:UIControlStateNormal]; [deepBtn setTitleColor:[UIColor colorWithRed:1.0 green:0.3 blue:0.7 alpha:1.0] forState:UIControlStateNormal]; deepBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11]; deepBtn.tag = 1022; [deepBtn addTarget:self action:@selector(toggleDeepTracking:) forControlEvents:UIControlEventTouchUpInside]; [self addSubview:deepBtn];
        UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem]; closeBtn.frame = CGRectMake(self.bounds.size.width - 45, 3, 40, 30); [closeBtn setTitle:@"✕" forState:UIControlStateNormal]; [closeBtn setTitleColor:[UIColor redColor] forState:UIControlStateNormal]; closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:20]; closeBtn.tag = 1002; [closeBtn addTarget:self action:@selector(hidePanel) forControlEvents:UIControlEventTouchUpInside]; [self addSubview:closeBtn];
        UIButton *clearBtn = [UIButton buttonWithType:UIButtonTypeSystem]; clearBtn.frame = CGRectMake(self.bounds.size.width - 135, 3, 45, 30); [clearBtn setTitle:@"清空" forState:UIControlStateNormal]; [clearBtn setTitleColor:[UIColor orangeColor] forState:UIControlStateNormal]; clearBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold]; clearBtn.tag = 1003; [clearBtn addTarget:self action:@selector(clearRulesTapped) forControlEvents:UIControlEventTouchUpInside]; [self addSubview:clearBtn];
        UIView *handle = [[UIView alloc] initWithFrame:CGRectMake(self.bounds.size.width / 2 - 15, 4, 30, 4)]; handle.backgroundColor = [UIColor colorWithWhite:0.4 alpha:0.6]; handle.layer.cornerRadius = 2; handle.tag = 1004; [self addSubview:handle];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)]; [self addGestureRecognizer:pan];

        CGFloat tvY = 196;
        _logTextView = [[UITextView alloc] initWithFrame:CGRectMake(5, tvY, self.bounds.size.width - 10, self.bounds.size.height - tvY - 5)];
        _logTextView.backgroundColor = [UIColor clearColor]; _logTextView.textColor = [UIColor greenColor]; _logTextView.font = [UIFont fontWithName:@"Courier" size:10] ?: [UIFont systemFontOfSize:10];
        _logTextView.editable = NO; _logTextView.selectable = YES; _logTextView.tag = 1005; _logTextView.textContainerInset = UIEdgeInsetsMake(2, 2, 2, 2); [self addSubview:_logTextView];
        _logBuffer = [NSMutableString string];
    }
    return self;
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)kbShow:(NSNotification *)n { s_isKeyboardVisible = YES; }
- (void)kbHide:(NSNotification *)n { s_isKeyboardVisible = NO; }
- (BOOL)textFieldShouldReturn:(UITextField *)tf { [tf resignFirstResponder]; return YES; }
- (void)handlePan:(UIPanGestureRecognizer *)p { CGPoint t = [p translationInView:self]; self.center = CGPointMake(self.center.x + t.x, self.center.y + t.y); [p setTranslation:CGPointZero inView:self]; }
- (void)hidePanel { self.hidden = YES; }
- (void)fillPreset1 { self.targetViewField.text = @"GDTDLBusinessManager"; self.keyPathField.text = @"self"; self.methodNameField.text = @"onDestroy"; }
- (void)copyLog { NSString *t = self.logBuffer; if (!t.length) { showToast(@"⚠️ 日志为空"); return; } [[UIPasteboard generalPasteboard] setString:t]; showToast(@"✅ 已复制"); }
- (void)addCustomRuleFromFields
{
    NSString *tv = self.targetViewField.text, *kp = self.keyPathField.text, *mn = self.methodNameField.text;
    [self.targetViewField resignFirstResponder]; [self.keyPathField resignFirstResponder]; [self.methodNameField resignFirstResponder];
    if (!tv.length || !kp.length || !mn.length) { showToast(@"⚠️ 请填写完整规则"); return; }
    saveCustomRule(@{@"targetView": tv, @"keyPath": kp, @"methodName": mn});
    [self showLog:[NSString stringWithFormat:@"\n✅ 已添加: %@ → [%@] %@\n", tv, kp, mn]];
    showToast(@"✅ 规则已添加");
}
- (void)testCustomRules { applyCustomRules(); }
- (void)clearRulesTapped { clearAllRules(); clearCustomRules(); [self showLog:@"\n🗑️ 已清空\n"]; showToast(@"🗑️ 规则已清除"); }
- (void)toggleTracking:(UIButton *)sender { if (s_isTracking) { stopTracking(); [sender setTitle:@"▶开始追踪" forState:UIControlStateNormal]; } else { startTracking(); [sender setTitle:@"⏹停止追踪" forState:UIControlStateNormal]; } }
- (void)toggleDeepTracking:(UIButton *)sender { if (s_isDeepTracking) { stopDeepTracking(); [sender setTitle:@"🔬深度追踪" forState:UIControlStateNormal]; } else { startDeepTracking(); [sender setTitle:@"⏹停止深度" forState:UIControlStateNormal]; } }
- (void)forceShow
{
    if (!s_floatWindow) { UIWindowScene *as = nil; for (UIScene *s in [UIApplication sharedApplication].connectedScenes) { if ([s isKindOfClass:[UIWindowScene class]] && s.activationState == UISceneActivationStateForegroundActive) { as = (UIWindowScene *)s; break; } } if (as) { s_floatWindow = [[AdInspectorWindow alloc] initWithFrame:as.coordinateSpace.bounds]; s_floatWindow.windowScene = as; [s_floatWindow addSubview:self]; self.frame = CGRectMake(5, 180, s_floatWindow.bounds.size.width - 10, 360); s_floatWindow.panel = self; } }
    else { if (!self.superview) { [s_floatWindow addSubview:self]; self.frame = CGRectMake(5, 180, s_floatWindow.bounds.size.width - 10, 360); s_floatWindow.panel = self; } s_floatWindow.hidden = NO; s_floatWindow.alpha = 1.0; [s_floatWindow bringSubviewToFront:self]; }
    self.hidden = NO; self.alpha = 1.0; showToast(@"👆 面板已呼出");
}
- (void)showLog:(NSString *)log
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.logBuffer appendString:log];
        if (self.logBuffer.length > 8000) [self.logBuffer deleteCharactersInRange:NSMakeRange(0, self.logBuffer.length - 8000)];
        self.logTextView.text = self.logBuffer;
        if (self.logTextView.text.length > 0) [self.logTextView scrollRangeToVisible:NSMakeRange(self.logTextView.text.length - 1, 1)];
    });
}
@end

// ==================== Toast ====================
static void showToast(NSString *m)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *hw = getKeyWindow();
        if (!hw) return;
        UIView *tv = [[UIView alloc] init];
        tv.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
        tv.layer.cornerRadius = 12;
        UILabel *l = [[UILabel alloc] init];
        l.text = m; l.textColor = [UIColor whiteColor]; l.font = [UIFont boldSystemFontOfSize:14]; l.numberOfLines = 0; l.textAlignment = NSTextAlignmentCenter;
        [tv addSubview:l];
        CGSize ms = CGSizeMake([UIScreen mainScreen].bounds.size.width - 60, CGFLOAT_MAX);
        CGRect tr = [m boundingRectWithSize:ms options:NSStringDrawingUsesLineFragmentOrigin attributes:@{NSFontAttributeName: l.font} context:nil];
        l.frame = CGRectMake(15, 8, tr.size.width, tr.size.height);
        tv.frame = CGRectMake((hw.bounds.size.width - (tr.size.width + 30)) / 2, hw.bounds.size.height - 150, tr.size.width + 30, tr.size.height + 16);
        tv.layer.zPosition = CGFLOAT_MAX;
        [hw addSubview:tv];
        [UIView animateWithDuration:0.3 delay:1.5 options:UIViewAnimationOptionCurveEaseOut animations:^{ tv.alpha = 0; } completion:^(BOOL f) { [tv removeFromSuperview]; }];
    });
}

// ==================== 规则管理 ====================
static void saveCustomRule(NSDictionary *r)
{
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSArray *ex = [ud arrayForKey:kCustomRulesKey];
    if (!ex) ex = @[];
    for (NSDictionary *x in ex) { if ([x[@"targetView"] isEqualToString:r[@"targetView"]] && [x[@"methodName"] isEqualToString:r[@"methodName"]]) return; }
    NSMutableArray *nr = [ex mutableCopy]; [nr addObject:r]; [ud setObject:nr forKey:kCustomRulesKey]; [ud synchronize];
}
static void clearAllRules(void) { [[NSUserDefaults standardUserDefaults] removeObjectForKey:kRulesKey]; }
static void clearCustomRules(void) { [[NSUserDefaults standardUserDefaults] removeObjectForKey:kCustomRulesKey]; }
static id getObjectByKeyPath(id o, NSString *kp) { if ([kp isEqualToString:@"self"]) return o; NSArray *ks = [kp componentsSeparatedByString:@"."]; id c = o; for (NSString *k in ks) { if (!c) return nil; c = [c valueForKey:k]; } return c; }
static UIView *findViewOfClass(UIView *rt, NSString *cn) { if ([NSStringFromClass([rt class]) isEqualToString:cn]) return rt; for (UIView *sb in rt.subviews) { UIView *f = findViewOfClass(sb, cn); if (f) return f; } return nil; }

// ==================== 核心：单方法调用 + 透明视图清理 ====================
static void applyCustomRules(void)
{
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSArray *cr = [ud arrayForKey:kCustomRulesKey];
    if (!cr || !cr.count) return;

    BOOL didExecute = NO;

    for (NSDictionary *r in cr)
    {
        NSString *tvc = r[@"targetView"], *kp = r[@"keyPath"], *mn = r[@"methodName"];
        if (!tvc || !kp || !mn) continue;

        id tg = nil;
        for (UIWindow *w in getAllWindows())
        {
            if ([NSStringFromClass([w class]) isEqualToString:@"AdInspectorWindow"]) continue;
            UIView *tv = findViewOfClass(w, tvc);
            if (tv) { tg = getObjectByKeyPath(tv, kp); if (tg) break; }
        }
        if (!tg)
        {
            Class c = NSClassFromString(tvc);
            if (c)
            {
                SEL ss[] = {@selector(sharedInstance), @selector(sharedManager), @selector(shared), @selector(defaultManager)};
                for (int i = 0; i < 4 && !tg; i++) if ([c respondsToSelector:ss[i]]) tg = ((id(*)(id,SEL))objc_msgSend)(c, ss[i]);
                if (!tg) { id ad = [UIApplication sharedApplication].delegate; @try { tg = [ad valueForKey:tvc]; } @catch(NSException *e){} }
            }
        }
        if ([kp isEqualToString:@"self"]) {} else if (tg) tg = getObjectByKeyPath(tg, kp);
        if (!tg) continue;
        SEL m = NSSelectorFromString(mn);
        if (![tg respondsToSelector:m]) continue;

        NSMethodSignature *sig = [tg methodSignatureForSelector:m]; NSUInteger ac = sig.numberOfArguments;
        if (ac <= 2) ((void(*)(id,SEL))objc_msgSend)(tg, m);
        else if (ac == 3) { const char *t = [sig getArgumentTypeAtIndex:2]; if (strcmp(t,"B")==0) ((void(*)(id,SEL,BOOL))objc_msgSend)(tg,m,YES); else ((void(*)(id,SEL,id))objc_msgSend)(tg,m,nil); }
        else { NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig]; [inv setTarget:tg]; [inv setSelector:m]; id nilArg = nil; for (NSUInteger i=2;i<ac;i++) [inv setArgument:&nilArg atIndex:i]; [inv invoke]; }
        didExecute = YES;
    }

    // 清理透明图层
    if (didExecute)
    {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            for (UIWindow *w in getAllWindows())
            {
                if ([NSStringFromClass([w class]) isEqualToString:@"AdInspectorWindow"]) continue;
                NSMutableArray *views = [NSMutableArray arrayWithArray:w.subviews];
                while (views.count > 0)
                {
                    UIView *v = [views lastObject]; [views removeLastObject];
                    NSString *cn = NSStringFromClass([v class]);
                    if ([cn isEqualToString:@"GDTSplashDLView"] || [cn isEqualToString:@"GDTSplashViewController"])
                    {
                        [v removeFromSuperview];
                        [[AdInspectorPanel shared] showLog:[NSString stringWithFormat:@"\n🧹 已移除 %@\n", cn]];
                    }
                    if ([cn containsString:@"splash_ad"]) { w.hidden = YES; w.windowLevel = -1000; [w resignKeyWindow]; }
                    [views addObjectsFromArray:v.subviews];
                }
            }
            for (UIWindow *w in getAllWindows())
            {
                if ([NSStringFromClass([w class]) isEqualToString:@"AdInspectorWindow"]) continue;
                if (!w.hidden && w.alpha > 0) { [w makeKeyAndVisible]; break; }
            }
        });
    }
}

static void applyAllSavedRules(void)
{
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSArray *cr = [ud arrayForKey:kCustomRulesKey];
    if (cr && cr.count > 0) applyCustomRules();
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
            BOOL as = YES; for (UITouch *t in ts) { if (t.phase == UITouchPhaseEnded || t.phase == UITouchPhaseCancelled) { as = NO; break; } }
            if (as && !s_twoFingerStart) s_twoFingerStart = [NSDate date];
            if (s_twoFingerStart && [[NSDate date] timeIntervalSinceDate:s_twoFingerStart] >= kTwoFingerHoldDuration)
            {
                AdInspectorPanel *p = [AdInspectorPanel shared]; if (p.hidden) [p forceShow];
                s_twoFingerStart = nil; s_ignoreSingleTouchUntil = [NSDate dateWithTimeIntervalSinceNow:0.5];
            }
        }
        else s_twoFingerStart = nil;
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
            if ([s isKindOfClass:[UIWindowScene class]] && s.activationState == UISceneActivationStateForegroundActive) { as = (UIWindowScene *)s; break; }
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
        showToast(@"🔍 AdInspector 已激活 | 双指呼出面板");
        if (isFlexingAvailable()) raiseFlexingWindow();
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
            applyAllSavedRules();
            if (s_floatWindow && !s_isKeyboardVisible) s_floatWindow.hidden = NO;
            if (isFlexingAvailable()) raiseFlexingWindow();
        }];
    });
}
