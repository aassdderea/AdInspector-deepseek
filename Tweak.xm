#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ==================== 规则存储 Key ====================
static NSString *const kRulesKey = @"AdInspector_SkipRules";
static NSString *const kCustomRulesKey = @"AdInspector_CustomRules";

// ==================== 方法追踪存储 ====================
static NSMutableArray *s_trackedMethods = nil;
static BOOL s_isTracking = NO;
static NSDate *s_trackStartTime = nil;

// ==================== Ivar 读取辅助函数 ====================
static Ivar ATFindIvar(Class cls, const char *name) {
    for (Class c = cls; c; c = class_getSuperclass(c)) {
        Ivar ivar = class_getInstanceVariable(c, name);
        if (ivar) return ivar;
    }
    return NULL;
}

static id ATGetObjectIvar(id obj, const char *name) {
    Ivar ivar = ATFindIvar(object_getClass(obj), name);
    return ivar ? object_getIvar(obj, ivar) : nil;
}

static SEL ATGetSelectorIvar(id obj, const char *name) {
    Ivar ivar = ATFindIvar(object_getClass(obj), name);
    if (!ivar) return NULL;
    ptrdiff_t offset = ivar_getOffset(ivar);
    return *(SEL *)((uint8_t *)(__bridge void *)obj + offset);
}

// ==================== 获取所有窗口 ====================
static NSArray<UIWindow *> *getAllWindows(void) {
    NSMutableArray *all = [NSMutableArray array];
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            [all addObjectsFromArray:[(UIWindowScene *)scene windows]];
        }
    }
    if (all.count == 0) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [all addObjectsFromArray:[UIApplication sharedApplication].windows];
#pragma clang diagnostic pop
    }
    return all;
}

// ==================== Flexing ====================
static BOOL isFlexingAvailable(void) {
    NSArray *names = @[@"FLEXWindow",@"FLEXExplorerWindow",@"FLEXManagerWindow",@"FLEXOverlayWindow"];
    for (UIWindow *w in getAllWindows()) {
        for (NSString *n in names) { if ([NSStringFromClass([w class]) isEqualToString:n]) return YES; }
    }
    return NO;
}

static void raiseFlexingWindow(void) {
    NSArray *names = @[@"FLEXWindow",@"FLEXExplorerWindow",@"FLEXManagerWindow",@"FLEXOverlayWindow"];
    for (UIWindow *w in getAllWindows()) {
        for (NSString *n in names) {
            if ([NSStringFromClass([w class]) isEqualToString:n]) {
                w.windowLevel = CGFLOAT_MAX; w.hidden = NO; w.alpha = 1.0;
                [w makeKeyAndVisible]; return;
            }
        }
    }
}

// ==================== 方法追踪 ====================
static void startTracking(void) { s_trackedMethods = [NSMutableArray array]; s_isTracking = YES; s_trackStartTime = [NSDate date]; }
static void stopTracking(void) { s_isTracking = NO; }

static void recordMethodCall(NSString *name) {
    if (!s_isTracking) return;
    if ([name hasPrefix:@"set"] || [name hasPrefix:@"log"] || [name containsString:@"videoPlayer"] ||
        [name isEqualToString:@"adModel"] || [name isEqualToString:@"adConfig"] || [name isEqualToString:@"delegate"] ||
        [name isEqualToString:@"rootView"] || [name isEqualToString:@"gdm"] ||
        [name hasPrefix:@"init"] || [name hasPrefix:@"."] || [name hasPrefix:@"_"]) return;
    NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:s_trackStartTime];
    @synchronized (s_trackedMethods) {
        [s_trackedMethods addObject:@{@"method":name, @"time":@(elapsed)}];
    }
}

// ==================== 前置声明 ====================
static NSString *getControlEventName(UIControlEvents e);
static void saveToFile(NSString *log);
static void analyzeTouchView(UIView *v, CGPoint pt);
static void highlightView(UIView *v);
static void saveRule(NSDictionary *r);
static void applyAllSavedRules(void);
static UIView *findMatchingView(UIView *root, NSDictionary *r);
static void triggerSkip(UIView *v, NSDictionary *r);
static void clearAllRules(void);
static void clearCustomRules(void);
static void showToast(NSString *msg);
static UIWindow *getKeyWindow(void);
static UIView *findSkipLabelInView(UIView *root);
static void saveCustomRule(NSDictionary *r);
static void applyCustomRules(void);
static UIView *findViewOfClass(UIView *root, NSString *cn);
static id getObjectByKeyPath(id obj, NSString *kp);

// ==================== 防抖 ====================
static NSDate *s_lastAnalysisTime = nil;
static const NSTimeInterval kMinAnalysisInterval = 0.3;

// ==================== 双指长按 ====================
static NSDate *s_twoFingerStart = nil;
static const NSTimeInterval kTwoFingerHoldDuration = 0.5;
static NSDate *s_ignoreSingleTouchUntil = nil;

// ==================== keyWindow ====================
static UIWindow *getKeyWindow(void) {
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]] && s.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *w in [(UIWindowScene *)s windows]) { if (w.isKeyWindow) return w; }
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
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self || (id)hit == (id)self.panel) return nil;
    while (hit && hit != self.panel) {
        if (hit.tag >= 1001 && hit.tag <= 1020) return hit;
        hit = hit.superview;
    }
    return nil;
}
- (void)setHidden:(BOOL)hidden { if (hidden && !self.isHidden) return; [super setHidden:hidden]; }
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
@end

@implementation AdInspectorPanel

+ (instancetype)shared {
    static AdInspectorPanel *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[AdInspectorPanel alloc] initWithFrame:CGRectMake(5,180,[UIScreen mainScreen].bounds.size.width-10,360)]; });
    return inst;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.90];
        self.layer.cornerRadius = 10; self.layer.borderWidth = 1.5;
        self.layer.borderColor = [UIColor cyanColor].CGColor;
        self.userInteractionEnabled = YES; self.clipsToBounds = NO; self.hidden = YES;

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(kbShow:) name:UIKeyboardWillShowNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(kbHide:) name:UIKeyboardWillHideNotification object:nil];

        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12,8,260,20)];
        title.text = @"🔍 AdInspector | 编辑+追踪"; title.textColor = [UIColor cyanColor]; title.font = [UIFont boldSystemFontOfSize:12]; title.tag = 1001;
        [self addSubview:title];

        UILabel *l1 = [[UILabel alloc] initWithFrame:CGRectMake(12,34,80,20)];
        l1.text = @"目标视图类:"; l1.textColor = [UIColor whiteColor]; l1.font = [UIFont systemFontOfSize:11]; [self addSubview:l1];
        _targetViewField = [[UITextField alloc] initWithFrame:CGRectMake(95,32,self.bounds.size.width-110,26)];
        _targetViewField.borderStyle = UITextBorderStyleRoundedRect; _targetViewField.backgroundColor = [UIColor darkGrayColor];
        _targetViewField.textColor = [UIColor whiteColor]; _targetViewField.font = [UIFont systemFontOfSize:12];
        _targetViewField.placeholder = @"如 GDTDLRootView"; _targetViewField.tag = 1011; _targetViewField.delegate = self;
        [self addSubview:_targetViewField];

        UILabel *l2 = [[UILabel alloc] initWithFrame:CGRectMake(12,64,80,20)];
        l2.text = @"KVC路径:"; l2.textColor = [UIColor whiteColor]; l2.font = [UIFont systemFontOfSize:11]; [self addSubview:l2];
        _keyPathField = [[UITextField alloc] initWithFrame:CGRectMake(95,62,self.bounds.size.width-110,26)];
        _keyPathField.borderStyle = UITextBorderStyleRoundedRect; _keyPathField.backgroundColor = [UIColor darkGrayColor];
        _keyPathField.textColor = [UIColor whiteColor]; _keyPathField.font = [UIFont systemFontOfSize:12];
        _keyPathField.placeholder = @"如 delegate 或 self"; _keyPathField.tag = 1012; _keyPathField.delegate = self;
        [self addSubview:_keyPathField];

        UILabel *l3 = [[UILabel alloc] initWithFrame:CGRectMake(12,94,80,20)];
        l3.text = @"方法名:"; l3.textColor = [UIColor whiteColor]; l3.font = [UIFont systemFontOfSize:11]; [self addSubview:l3];
        _methodNameField = [[UITextField alloc] initWithFrame:CGRectMake(95,92,self.bounds.size.width-110,26)];
        _methodNameField.borderStyle = UITextBorderStyleRoundedRect; _methodNameField.backgroundColor = [UIColor darkGrayColor];
        _methodNameField.textColor = [UIColor whiteColor]; _methodNameField.font = [UIFont systemFontOfSize:12];
        _methodNameField.placeholder = @"如 onDestroy 或 pauseTimer"; _methodNameField.tag = 1013; _methodNameField.delegate = self;
        [self addSubview:_methodNameField];

        UIButton *addBtn = [UIButton buttonWithType:UIButtonTypeSystem]; addBtn.frame = CGRectMake(12,126,60,30);
        [addBtn setTitle:@"添加" forState:UIControlStateNormal]; [addBtn setTitleColor:[UIColor greenColor] forState:UIControlStateNormal];
        addBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12]; addBtn.tag = 1014;
        [addBtn addTarget:self action:@selector(addCustomRuleFromFields) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:addBtn];

        UIButton *testBtn = [UIButton buttonWithType:UIButtonTypeSystem]; testBtn.frame = CGRectMake(80,126,60,30);
        [testBtn setTitle:@"测试" forState:UIControlStateNormal]; [testBtn setTitleColor:[UIColor yellowColor] forState:UIControlStateNormal];
        testBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12]; testBtn.tag = 1015;
        [testBtn addTarget:self action:@selector(testCustomRules) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:testBtn];

        UIButton *p1 = [UIButton buttonWithType:UIButtonTypeSystem]; p1.frame = CGRectMake(148,126,60,30);
        [p1 setTitle:@"预设1" forState:UIControlStateNormal]; [p1 setTitleColor:[UIColor cyanColor] forState:UIControlStateNormal];
        p1.titleLabel.font = [UIFont systemFontOfSize:11]; p1.tag = 1016;
        [p1 addTarget:self action:@selector(fillPreset1) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:p1];

        UIButton *p2 = [UIButton buttonWithType:UIButtonTypeSystem]; p2.frame = CGRectMake(216,126,60,30);
        [p2 setTitle:@"预设2" forState:UIControlStateNormal]; [p2 setTitleColor:[UIColor cyanColor] forState:UIControlStateNormal];
        p2.titleLabel.font = [UIFont systemFontOfSize:11]; p2.tag = 1017;
        [p2 addTarget:self action:@selector(fillPreset2) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:p2];

        UIButton *trkBtn = [UIButton buttonWithType:UIButtonTypeSystem]; trkBtn.frame = CGRectMake(12,160,90,30);
        [trkBtn setTitle:@"▶开始追踪" forState:UIControlStateNormal]; [trkBtn setTitleColor:[UIColor colorWithRed:1.0 green:0.5 blue:0.0 alpha:1.0] forState:UIControlStateNormal];
        trkBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11]; trkBtn.tag = 1018;
        [trkBtn addTarget:self action:@selector(toggleTracking:) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:trkBtn];

        UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem]; closeBtn.frame = CGRectMake(self.bounds.size.width-45,3,40,30);
        [closeBtn setTitle:@"✕" forState:UIControlStateNormal]; [closeBtn setTitleColor:[UIColor redColor] forState:UIControlStateNormal];
        closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:20]; closeBtn.tag = 1002;
        [closeBtn addTarget:self action:@selector(hidePanel) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:closeBtn];

        UIButton *clearBtn = [UIButton buttonWithType:UIButtonTypeSystem]; clearBtn.frame = CGRectMake(self.bounds.size.width-135,3,45,30);
        [clearBtn setTitle:@"清空" forState:UIControlStateNormal]; [clearBtn setTitleColor:[UIColor orangeColor] forState:UIControlStateNormal];
        clearBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold]; clearBtn.tag = 1003;
        [clearBtn addTarget:self action:@selector(clearRulesTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:clearBtn];

        UIButton *viewBtn = [UIButton buttonWithType:UIButtonTypeSystem]; viewBtn.frame = CGRectMake(self.bounds.size.width-90,3,45,30);
        [viewBtn setTitle:@"查看" forState:UIControlStateNormal]; [viewBtn setTitleColor:[UIColor yellowColor] forState:UIControlStateNormal];
        viewBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold]; viewBtn.tag = 1006;
        [viewBtn addTarget:self action:@selector(viewRulesTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:viewBtn];

        UIView *handle = [[UIView alloc] initWithFrame:CGRectMake(self.bounds.size.width/2-15,4,30,4)];
        handle.backgroundColor = [UIColor colorWithWhite:0.4 alpha:0.6]; handle.layer.cornerRadius = 2; handle.tag = 1004;
        [self addSubview:handle];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];

        CGFloat tvY = 196;
        _logTextView = [[UITextView alloc] initWithFrame:CGRectMake(5,tvY,self.bounds.size.width-10,self.bounds.size.height-tvY-5)];
        _logTextView.backgroundColor = [UIColor clearColor]; _logTextView.textColor = [UIColor greenColor];
        _logTextView.font = [UIFont fontWithName:@"Courier" size:10] ?: [UIFont systemFontOfSize:10];
        _logTextView.editable = NO; _logTextView.selectable = YES; _logTextView.tag = 1005;
        _logTextView.textContainerInset = UIEdgeInsetsMake(2,2,2,2);
        [self addSubview:_logTextView];

        _logBuffer = [NSMutableString string];
    }
    return self;
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

- (void)kbShow:(NSNotification *)note {
    NSDictionary *info = note.userInfo;
    CGRect kbFrame = [info[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGFloat kbHeight = kbFrame.size.height;
    CGFloat panelBottom = CGRectGetMaxY(self.frame);
    CGFloat screenHeight = [UIScreen mainScreen].bounds.size.height;
    CGFloat offset = panelBottom - (screenHeight - kbHeight) + 20;
    if (offset > 0) {
        [UIView animateWithDuration:[info[UIKeyboardAnimationDurationUserInfoKey] doubleValue] animations:^{
            self.center = CGPointMake(self.center.x, self.center.y - offset);
        }];
    }
}

- (void)kbHide:(NSNotification *)note {
    [UIView animateWithDuration:[note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue] animations:^{
        self.center = CGPointMake(self.center.x, 180 + self.bounds.size.height/2);
    }];
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf { [tf resignFirstResponder]; return YES; }
- (void)handlePan:(UIPanGestureRecognizer *)pan { CGPoint t = [pan translationInView:self]; self.center = CGPointMake(self.center.x+t.x, self.center.y+t.y); [pan setTranslation:CGPointZero inView:self]; }
- (void)hidePanel { self.hidden = YES; }
- (void)fillPreset1 { self.targetViewField.text = @"GDTDLRootView"; self.keyPathField.text = @"delegate"; self.methodNameField.text = @"onDestroy"; }
- (void)fillPreset2 { self.targetViewField.text = @"GDTDLRootView"; self.keyPathField.text = @"delegate"; self.methodNameField.text = @"pauseTimer"; }

- (void)addCustomRuleFromFields {
    NSString *tv = self.targetViewField.text, *kp = self.keyPathField.text, *mn = self.methodNameField.text;
    [self.targetViewField resignFirstResponder]; [self.keyPathField resignFirstResponder]; [self.methodNameField resignFirstResponder];
    if (tv.length == 0 || kp.length == 0 || mn.length == 0) { showToast(@"⚠️ 请填写完整规则"); return; }
    NSDictionary *r = @{@"targetView":tv, @"keyPath":kp, @"methodName":mn, @"description":[NSString stringWithFormat:@"%@→%@", tv, mn]};
    saveCustomRule(r);
    [self showLog:[NSString stringWithFormat:@"\n✅ 已添加: %@ → %@.%@\n", tv, kp, mn]];
    showToast(@"✅ 规则已添加");
}

- (void)testCustomRules { applyCustomRules(); [self showLog:@"\n🔍 已执行自定义规则测试\n"]; }

- (void)clearRulesTapped { clearAllRules(); clearCustomRules(); [self showLog:@"\n🗑️ 已清空所有规则\n"]; showToast(@"🗑️ 规则已清除"); }

- (void)toggleTracking:(UIButton *)sender {
    if (s_isTracking) {
        stopTracking();
        [sender setTitle:@"▶开始追踪" forState:UIControlStateNormal];
        [sender setTitleColor:[UIColor colorWithRed:1.0 green:0.5 blue:0.0 alpha:1.0] forState:UIControlStateNormal];
        if (s_trackedMethods.count > 0) {
            NSMutableString *out = [NSMutableString stringWithFormat:@"\n📊 追踪结果 (%lu个):\n", (unsigned long)s_trackedMethods.count];
            for (NSDictionary *e in s_trackedMethods) [out appendFormat:@"  +%.2fs → %@\n", [e[@"time"] doubleValue], e[@"method"]];
            [self showLog:out];
        } else [self showLog:@"\n⚠️ 未捕获到方法调用\n"];
    } else {
        startTracking();
        [sender setTitle:@"⏹停止追踪" forState:UIControlStateNormal];
        [sender setTitleColor:[UIColor redColor] forState:UIControlStateNormal];
        [self showLog:@"\n🔍 开始追踪... 请手动点击跳过按钮\n"];
    }
}

- (void)viewRulesTapped {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSArray *ar = [ud arrayForKey:kRulesKey] ?: @[], *cr = [ud arrayForKey:kCustomRulesKey] ?: @[];
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"\n📋 自动规则 (%lu条):\n", (unsigned long)ar.count];
    for (NSInteger i=0;i<ar.count;i++) { NSDictionary *r=ar[i]; [out appendFormat:@"  %ld: %@ \"%@\" 触发:%@\n", (long)i+1, r[@"buttonClass"], r[@"buttonTextPattern"], r[@"triggerType"]]; }
    [out appendFormat:@"\n📋 自定义规则 (%lu条):\n", (unsigned long)cr.count];
    for (NSInteger i=0;i<cr.count;i++) { NSDictionary *r=cr[i]; [out appendFormat:@"  %ld: %@ → %@.%@\n", (long)i+1, r[@"targetView"], r[@"keyPath"], r[@"methodName"]]; }
    [self showLog:out];
}

- (void)forceShow {
    if (!s_floatWindow) {
        UIWindowScene *as = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) { if ([s isKindOfClass:[UIWindowScene class]] && s.activationState == UISceneActivationStateForegroundActive) { as = (UIWindowScene *)s; break; } }
        if (as) { s_floatWindow = [[AdInspectorWindow alloc] initWithFrame:as.coordinateSpace.bounds]; s_floatWindow.windowScene = as; [s_floatWindow addSubview:self]; self.frame = CGRectMake(5,180,s_floatWindow.bounds.size.width-10,360); self.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleBottomMargin; s_floatWindow.panel = self; s_floatWindow.hidden = NO; }
    } else {
        if (!self.superview) { [s_floatWindow addSubview:self]; self.frame = CGRectMake(5,180,s_floatWindow.bounds.size.width-10,360); self.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleBottomMargin; s_floatWindow.panel = self; }
        s_floatWindow.hidden = NO; s_floatWindow.alpha = 1.0; [s_floatWindow bringSubviewToFront:self];
    }
    self.hidden = NO; self.alpha = 1.0; showToast(@"👆 面板已呼出"); [self viewRulesTapped];
}

- (void)showLog:(NSString *)log { dispatch_async(dispatch_get_main_queue(), ^{ [self.logBuffer appendString:log]; if (self.logBuffer.length > 8000) [self.logBuffer deleteCharactersInRange:NSMakeRange(0, self.logBuffer.length - 8000)]; self.logTextView.text = self.logBuffer; if (self.logTextView.text.length > 0) [self.logTextView scrollRangeToVisible:NSMakeRange(self.logTextView.text.length - 1, 1)]; }); }
@end

// ==================== Toast / 工具函数 / 规则管理（与之前完全相同） ====================
static void showToast(NSString *msg) { dispatch_async(dispatch_get_main_queue(), ^{ UIWindow *hw = getKeyWindow(); if (!hw) return; UIView *toast = [[UIView alloc] init]; toast.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85]; toast.layer.cornerRadius = 12; UILabel *lbl = [[UILabel alloc] init]; lbl.text = msg; lbl.textColor = [UIColor whiteColor]; lbl.font = [UIFont boldSystemFontOfSize:14]; lbl.numberOfLines = 0; lbl.textAlignment = NSTextAlignmentCenter; [toast addSubview:lbl]; CGSize ms = CGSizeMake([UIScreen mainScreen].bounds.size.width-60, CGFLOAT_MAX); CGRect tr = [msg boundingRectWithSize:ms options:NSStringDrawingUsesLineFragmentOrigin attributes:@{NSFontAttributeName:lbl.font} context:nil]; CGFloat w = tr.size.width+30, h = tr.size.height+16; lbl.frame = CGRectMake(15,8,tr.size.width,tr.size.height); CGPoint c = CGPointMake(hw.bounds.size.width/2, hw.bounds.size.height-150); toast.frame = CGRectMake(c.x-w/2, c.y-h/2, w, h); toast.layer.zPosition = CGFLOAT_MAX; [hw addSubview:toast]; [UIView animateWithDuration:0.3 delay:1.5 options:UIViewAnimationOptionCurveEaseOut animations:^{ toast.alpha = 0; } completion:^(BOOL f) { [toast removeFromSuperview]; }]; }); }

static NSString *getControlEventName(UIControlEvents e) { switch(e){case UIControlEventTouchDown:return @"TouchDown";case UIControlEventTouchDownRepeat:return @"TouchDownRepeat";case UIControlEventTouchDragInside:return @"DragInside";case UIControlEventTouchDragOutside:return @"DragOutside";case UIControlEventTouchUpInside:return @"TouchUpInside";case UIControlEventTouchUpOutside:return @"TouchUpOutside";case UIControlEventTouchCancel:return @"TouchCancel";case UIControlEventValueChanged:return @"ValueChanged";case UIControlEventPrimaryActionTriggered:return @"PrimaryAction";case UIControlEventEditingDidBegin:return @"EditingBegin";case UIControlEventEditingDidEnd:return @"EditingEnd";default:return [NSString stringWithFormat:@"Evt%lu",(unsigned long)e];} }

static void saveToFile(NSString *log) { @try{NSArray *p=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES);if(p.count==0)return;NSString *pt=[p[0] stringByAppendingPathComponent:@"AdInspector_Logs.txt"];if(![[NSFileManager defaultManager] fileExistsAtPath:pt])[[NSData data] writeToFile:pt atomically:YES];NSFileHandle *f=[NSFileHandle fileHandleForWritingAtPath:pt];if(f){[f seekToEndOfFile];[f writeData:[log dataUsingEncoding:NSUTF8StringEncoding]];[f closeFile];}}@catch(NSException *e){} }

static void highlightView(UIView *v) { if(!v)return; UIColor *oc=nil; CGColorRef og=v.layer.borderColor; if(og!=NULL)oc=[UIColor colorWithCGColor:og]; CGFloat ow=v.layer.borderWidth; v.layer.borderColor=[UIColor redColor].CGColor; v.layer.borderWidth=3.0; __weak UIView *wv=v; dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.5*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ __strong UIView *sv=wv; if(sv){sv.layer.borderColor=oc?oc.CGColor:NULL;sv.layer.borderWidth=ow;} }); }

static void saveRule(NSDictionary *r) { NSUserDefaults *ud=[NSUserDefaults standardUserDefaults]; NSArray *ex=[ud arrayForKey:kRulesKey]?:@[]; NSInteger ei=-1; for(NSInteger i=0;i<ex.count;i++){ NSDictionary *x=ex[i]; if([x[@"buttonClass"] isEqualToString:r[@"buttonClass"]]&&[x[@"buttonTextPattern"] isEqualToString:r[@"buttonTextPattern"]]&&[x[@"hierarchyChain"] isEqualToArray:r[@"hierarchyChain"]]){ei=i;break;} } NSMutableArray *nr=[ex mutableCopy]; if(ei>=0){[nr replaceObjectAtIndex:ei withObject:r];showToast(@"🔄 规则已更新");}else{[nr addObject:r];showToast([NSString stringWithFormat:@"✅ 已学习：%@",r[@"buttonTextPattern"]]);} [ud setObject:nr forKey:kRulesKey];[ud synchronize]; }

static UIView *findMatchingView(UIView *rt,NSDictionary *r) { if([rt isKindOfClass:[AdInspectorPanel class]]||[NSStringFromClass([rt.window class]) isEqualToString:@"AdInspectorWindow"]||(rt.tag>=1001&&rt.tag<=1020))return nil; NSString *tc=r[@"buttonClass"],*tp=r[@"buttonTextPattern"]; NSArray *ch=r[@"hierarchyChain"]; if([NSStringFromClass([rt class]) isEqualToString:tc]){ NSString *ct=nil; if([rt isKindOfClass:[UIButton class]])ct=[(UIButton*)rt titleForState:UIControlStateNormal]; else if([rt isKindOfClass:[UILabel class]])ct=[(UILabel*)rt text]?:[(UILabel*)rt attributedText].string; else ct=rt.accessibilityLabel; if(ct){ BOOL tm=(tp.length<=2)?[ct isEqualToString:tp]:([ct rangeOfString:tp].location!=NSNotFound&&ct.length<=15); if(tm){ NSMutableArray *cc=[NSMutableArray array]; UIView *cur=rt; while(cur&&![cur isKindOfClass:[UIWindow class]]){[cc addObject:NSStringFromClass([cur class])];cur=cur.superview;} if([cc isEqualToArray:ch])return rt; } } } for(UIView *sb in rt.subviews){UIView *f=findMatchingView(sb,r);if(f)return f;} return nil; }

static void clearAllRules(void){[[NSUserDefaults standardUserDefaults] removeObjectForKey:kRulesKey];[[NSUserDefaults standardUserDefaults] synchronize];}

static void saveCustomRule(NSDictionary *r){NSUserDefaults *ud=[NSUserDefaults standardUserDefaults];NSArray *ex=[ud arrayForKey:kCustomRulesKey]?:@[];for(NSDictionary *x in ex){if([x[@"targetView"] isEqualToString:r[@"targetView"]]&&[x[@"keyPath"] isEqualToString:r[@"keyPath"]]&&[x[@"methodName"] isEqualToString:r[@"methodName"]])return;}NSMutableArray *nr=[ex mutableCopy];[nr addObject:r];[ud setObject:nr forKey:kCustomRulesKey];[ud synchronize];}
static void clearCustomRules(void){[[NSUserDefaults standardUserDefaults] removeObjectForKey:kCustomRulesKey];[[NSUserDefaults standardUserDefaults] synchronize];}
static id getObjectByKeyPath(id o,NSString *kp){if([kp isEqualToString:@"self"])return o;NSArray *ks=[kp componentsSeparatedByString:@"."];id c=o;for(NSString *k in ks){if(!c)return nil;c=[c valueForKey:k];}return c;}
static UIView *findViewOfClass(UIView *rt,NSString *cn){if([NSStringFromClass([rt class]) isEqualToString:cn])return rt;for(UIView *sb in rt.subviews){UIView *f=findViewOfClass(sb,cn);if(f)return f;}return nil;}

static void applyCustomRules(void){NSUserDefaults *ud=[NSUserDefaults standardUserDefaults];NSArray *cr=[ud arrayForKey:kCustomRulesKey];if(!cr.count)return;for(NSDictionary *r in cr){NSString *tvc=r[@"targetView"],*kp=r[@"keyPath"],*mn=r[@"methodName"];if(!tvc||!kp||!mn)continue;for(UIWindow *w in getAllWindows()){if([NSStringFromClass([w class]) isEqualToString:@"AdInspectorWindow"])continue;UIView *tv=findViewOfClass(w,tvc);if(tv){id tg=getObjectByKeyPath(tv,kp);if(tg&&[tg respondsToSelector:NSSelectorFromString(mn)]){SEL m=NSSelectorFromString(mn);NSMethodSignature *sig=[tg methodSignatureForSelector:m];if(sig.numberOfArguments<=2){((void(*)(id,SEL))objc_msgSend)(tg,m);}else{((void(*)(id,SEL,id))objc_msgSend)(tg,m,nil);}}}}}}showToast(@"✅ 自定义规则已执行");}

static void triggerSkip(UIView *v,NSDictionary *r){if([v isDescendantOfView:[AdInspectorPanel shared]]||[NSStringFromClass([v.window class]) isEqualToString:@"AdInspectorWindow"])return;NSString *tt=r[@"triggerType"];if([tt isEqualToString:@"controlEvent"]){if([v isKindOfClass:[UIControl class]]){[(UIControl*)v sendActionsForControlEvents:[r[@"controlEvent"] unsignedIntegerValue]];showToast(@"⏩ 已自动跳过");return;}}}

static void applyAllSavedRules(void){NSUserDefaults *ud=[NSUserDefaults standardUserDefaults];NSArray *cr=[ud arrayForKey:kCustomRulesKey]?:@[],*ar=[ud arrayForKey:kRulesKey]?:@[];if(cr.count>0){applyCustomRules();}if(ar.count>0){for(UIScene *s in [UIApplication sharedApplication].connectedScenes){if(![s isKindOfClass:[UIWindowScene class]])continue;for(UIWindow *w in[(UIWindowScene*)s windows]){if([NSStringFromClass([w class]) isEqualToString:@"AdInspectorWindow"])continue;for(NSDictionary *r in ar){UIView *m=findMatchingView(w,r);if(m&&!m.hidden&&m.alpha>0){triggerSkip(m,r);return;}}}}}}

static BOOL isSkipText(NSString *t){if(!t||t.length==0)return NO;NSArray *kw=@[@"跳过",@"广告",@"关闭",@"×",@"x",@"X",@"close",@"skip"];for(NSString *k in kw){if([t rangeOfString:k options:NSCaseInsensitiveSearch].location!=NSNotFound&&t.length<=15)return YES;}return NO;}

static UIView *findSkipLabelInView(UIView *rt){if([rt isKindOfClass:[AdInspectorPanel class]]||(rt.tag>=1001&&rt.tag<=1020))return nil;NSString *ct=nil;if([rt isKindOfClass:[UIButton class]])ct=[(UIButton*)rt titleForState:UIControlStateNormal];else if([rt isKindOfClass:[UILabel class]])ct=[(UILabel*)rt text]?:[(UILabel*)rt attributedText].string;if(!ct)ct=rt.accessibilityLabel;if(isSkipText(ct))return rt;for(UIView *sb in rt.subviews){UIView *f=findSkipLabelInView(sb);if(f)return f;}return nil;}

static void analyzeTouchView(UIView *v,CGPoint pt){if(!v)return;if([v isDescendantOfView:[AdInspectorPanel shared]]||[NSStringFromClass([v.window class]) isEqualToString:@"AdInspectorWindow"]||(v.tag>=1001&&v.tag<=1020))return;NSDate *n=[NSDate date];if(s_lastAnalysisTime&&[n timeIntervalSinceDate:s_lastAnalysisTime]<kMinAnalysisInterval)return;s_lastAnalysisTime=n;UIView *av=findSkipLabelInView(v);if(!av){showToast(@"⚠️ 未检测到跳过按钮");return;}@try{UIWindow *aw=av.window;NSString *wc=aw?NSStringFromClass([aw class]):@"未知";NSMutableString *o=[NSMutableString string];[o appendFormat:@"\n══════ %@ ══════\n",[NSDateFormatter localizedStringFromDate:n dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle]];NSMutableArray *ca=[NSMutableArray array];UIView *cur=av;while(cur&&![cur isKindOfClass:[UIWindow class]]){[ca addObject:NSStringFromClass([cur class])];cur=cur.superview;}NSString *cc=ca.count>=2?ca[1]:nil;[o appendString:@"📊 视图层级链:\n"];cur=av;int d=0;while(cur&&d<15){NSString *ind=[@"" stringByPaddingToLength:d*2 withString:@" " startingAtIndex:0];[o appendFormat:@"%@▸ %@",ind,NSStringFromClass([cur class])];NSMutableArray *tg=[NSMutableArray array];if(cur.tag!=0)[tg addObject:[NSString stringWithFormat:@"tag:%ld",(long)cur.tag]];if([cur isKindOfClass:[UIButton class]]){NSString *t=[(UIButton*)cur titleForState:UIControlStateNormal];if(t.length)[tg addObject:[NSString stringWithFormat:@"\"%@\"",t]];}if([cur isKindOfClass:[UILabel class]]){NSString *t=[(UILabel*)cur text]?:[(UILabel*)cur attributedText].string;if(t.length>20)t=[[t substringToIndex:20] stringByAppendingString:@"..."];if(t.length)[tg addObject:[NSString stringWithFormat:@"\"%@\"",t]];}if(cur.accessibilityLabel.length)[tg addObject:[NSString stringWithFormat:@"a11y:\"%@\"",cur.accessibilityLabel]];if(tg.count)[o appendFormat:@" [%@]",[tg componentsJoinedByString:@", "]];[o appendFormat:@"\n%@  %@\n",ind,NSStringFromCGRect(cur.frame)];cur=cur.superview;d++;}[o appendString:@"\n🎯 Target-Action & 手势:\n"];BOOL fd=NO;NSMutableArray *ti=[NSMutableArray array];cur=av;d=0;while(cur&&d<8){if([cur isKindOfClass:[UIControl class]]){UIControl *c=(UIControl*)cur;for(id tgt in c.allTargets){UIControlEvents ce[]={UIControlEventTouchUpInside,UIControlEventTouchDown,UIControlEventValueChanged,UIControlEventPrimaryActionTriggered};for(int i=0;i<4;i++){NSArray *ac=[c actionsForTarget:tgt forControlEvent:ce[i]];if(ac.count){fd=YES;[o appendFormat:@"  [%@] → %@.%@ (%@)\n",NSStringFromClass([cur class]),NSStringFromClass([tgt class]),ac[0],getControlEventName(ce[i])];[ti addObject:@{@"viewClass":NSStringFromClass([cur class]),@"targetClass":NSStringFromClass([tgt class]),@"action":ac[0],@"event":@(ce[i])}];}}}}for(UIGestureRecognizer *gr in cur.gestureRecognizers){fd=YES;[o appendFormat:@"  [%@] 手势:%@ (en:%d ct:%d)\n",NSStringFromClass([cur class]),NSStringFromClass([gr class]),gr.enabled,gr.cancelsTouchesInView];BOOL gti=NO;@try{NSArray *tgts=[gr valueForKey:@"_targets"];if(tgts&&[tgts isKindOfClass:[NSArray class]]){for(id t in tgts){id target=[t valueForKey:@"_target"];id ao=[t valueForKey:@"_action"];NSString *as=nil;if([ao isKindOfClass:[NSString class]])as=ao;else if([ao isKindOfClass:[NSValue class]])as=NSStringFromSelector((SEL)[ao pointerValue]);if(target&&as){[o appendFormat:@"    → %@.%@\n",NSStringFromClass([target class]),as];recordMethodCall(as);[ti addObject:@{@"viewClass":NSStringFromClass([cur class]),@"gestureClass":NSStringFromClass([gr class]),@"targetClass":NSStringFromClass([target class]),@"action":as}];gti=YES;}}}}@catch(NSException *e){}if(!gti){id targets=ATGetObjectIvar(gr,"_targets");if(targets&&[targets isKindOfClass:[NSArray class]]){for(id t in targets){id target=ATGetObjectIvar(t,"_target");SEL action=ATGetSelectorIvar(t,"_action");if(target&&action){NSString *as=NSStringFromSelector(action);[o appendFormat:@"    → %@.%@ (Ivar)\n",NSStringFromClass([target class]),as];recordMethodCall(as);[ti addObject:@{@"viewClass":NSStringFromClass([cur class]),@"gestureClass":NSStringFromClass([gr class]),@"targetClass":NSStringFromClass([target class]),@"action":as}];gti=YES;}}}}if(!gti)[o appendString:@"    (无法提取)\n"];}cur=cur.superview;d++;}if(!fd)[o appendString:@"  (未检测到)\n"];[o appendFormat:@"\n🔍 诊断信息:\n  窗口:%@\n  目标:%@\n  frame:%@\n══════\n",wc,NSStringFromClass([av class]),NSStringFromCGRect(av.frame)];[[AdInspectorPanel shared] showLog:o];saveToFile(o);highlightView(av);NSString *bt=nil;if([av isKindOfClass:[UIButton class]])bt=[(UIButton*)av titleForState:UIControlStateNormal];else if([av isKindOfClass:[UILabel class]])bt=[(UILabel*)av text]?:[(UILabel*)av attributedText].string;if(bt.length==0)bt=av.accessibilityLabel;if(bt.length==0){showToast(@"⚠️ 按钮无文字");return;}NSMutableDictionary *r=[NSMutableDictionary dictionary];r[@"buttonClass"]=NSStringFromClass([av class]);r[@"buttonTextPattern"]=bt;r[@"hierarchyChain"]=ca;if(cc)r[@"containerClass"]=cc;if(wc)r[@"windowClass"]=wc;for(NSDictionary *info in ti){if(info[@"event"]&&[info[@"event"] unsignedIntegerValue]==UIControlEventTouchUpInside){r[@"triggerType"]=@"controlEvent";r[@"controlEvent"]=@(UIControlEventTouchUpInside);r[@"targetClass"]=info[@"targetClass"];r[@"actionSelector"]=info[@"action"];break;}}if(!r[@"triggerType"]){for(NSDictionary *info in ti){if(info[@"gestureClass"]&&info[@"targetClass"]&&info[@"action"]){r[@"triggerType"]=@"gesture";r[@"gestureClass"]=info[@"gestureClass"];r[@"targetClass"]=info[@"targetClass"];r[@"actionSelector"]=info[@"action"];r[@"gestureViewClass"]=info[@"viewClass"];break;}}}if(!r[@"triggerType"]){cur=av;while(cur){for(UIGestureRecognizer *gr in cur.gestureRecognizers){r[@"triggerType"]=@"gesture";r[@"gestureClass"]=NSStringFromClass([gr class]);r[@"gestureViewClass"]=NSStringFromClass([cur class]);break;}if(r[@"triggerType"])break;cur=cur.superview;}}if(!r[@"triggerType"]&&[av isKindOfClass:[UIControl class]]){r[@"triggerType"]=@"controlEvent";r[@"controlEvent"]=@(UIControlEventTouchUpInside);}if(r[@"triggerType"])saveRule(r);else showToast(@"❌ 无法学习");}@catch(NSException *e){showToast(@"⚠️ 分析异常");}}

// ==================== Hook ====================
%hook UIApplication
- (void)sendEvent:(UIEvent *)e { %orig; if(e.type==UIEventTypeTouches){ NSSet *ts=[e allTouches]; if(ts.count>=2){ BOOL as=YES; for(UITouch *t in ts){ if(t.phase==UITouchPhaseEnded||t.phase==UITouchPhaseCancelled){as=NO;break;} } if(as&&!s_twoFingerStart)s_twoFingerStart=[NSDate date]; if(s_twoFingerStart&&[[NSDate date] timeIntervalSinceDate:s_twoFingerStart]>=kTwoFingerHoldDuration){ AdInspectorPanel *p=[AdInspectorPanel shared]; if(p.hidden)[p forceShow]; s_twoFingerStart=nil; s_ignoreSingleTouchUntil=[NSDate dateWithTimeIntervalSinceNow:0.5]; } }else{s_twoFingerStart=nil;} if(ts.count==1){ UITouch *t=[ts anyObject]; if(t.phase==UITouchPhaseEnded&&t.view&&!s_twoFingerStart){ if(!s_ignoreSingleTouchUntil||[[NSDate date] compare:s_ignoreSingleTouchUntil]!=NSOrderedAscending){ analyzeTouchView(t.view,[t locationInView:nil]); } } } } }
%end

%hook UIControl
- (void)addTarget:(id)t action:(SEL)a forControlEvents:(UIControlEvents)e { NSLog(@"[AdInspector] 🔗 %@ → %@.%@ [%@]",NSStringFromClass([self class]),NSStringFromClass([t class]),NSStringFromSelector(a),getControlEventName(e)); %orig; }
%end

// ==================== 初始化 ====================
%ctor { dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ UIWindowScene *as=nil; for(UIScene *s in [UIApplication sharedApplication].connectedScenes){ if([s isKindOfClass:[UIWindowScene class]]&&s.activationState==UISceneActivationStateForegroundActive){as=(UIWindowScene*)s;break;} } if(as){ s_floatWindow=[[AdInspectorWindow alloc] initWithFrame:as.coordinateSpace.bounds]; s_floatWindow.windowScene=as; AdInspectorPanel *p=[AdInspectorPanel shared]; p.frame=CGRectMake(5,180,s_floatWindow.bounds.size.width-10,360); p.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleBottomMargin; [s_floatWindow addSubview:p]; s_floatWindow.panel=p; s_floatWindow.hidden=NO; } showToast(@"🔍 已激活 | 双指呼面板 | 追踪+规则"); if(isFlexingAvailable())raiseFlexingWindow(); [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t){ applyAllSavedRules(); if(s_floatWindow)s_floatWindow.hidden=NO; if(isFlexingAvailable())raiseFlexingWindow(); }]; }); }
