#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <execinfo.h>
#import <Foundation/Foundation.h>
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-function"

// ==================== 常量定义 ====================
static NSString *const kRulesKey = @"AdInspector_SkipRules";
static NSString *const kCustomRulesKey = @"AdInspector_CustomRules";
static NSString *const kCapturedParamKey = @"AdInspector_CapturedSkipParam";
static NSString *const kCapturedMethodKey = @"AdInspector_CapturedSkipMethod";

// ==================== 全局变量 ====================
static NSMutableArray *s_trackedMethods = nil;
static BOOL s_isTracking = NO;
static NSDate *s_trackStartTime = nil;
static BOOL s_isDeepTracking = NO;
static NSDate *s_deepTrackStartTime = nil;
static NSMutableArray *s_deepTrackedMethods = nil;
static BOOL s_isKeyboardVisible = NO;
// 参数捕获相关
static NSInteger s_capturedSkipParam = NSIntegerMin;
static BOOL s_isCapturingParams = NO;
static BOOL s_autoApplyRulesEnabled = NO;
static NSTimer *s_autoApplyTimer = nil;
static NSTimeInterval s_autoApplyInterval = 0.5;
static NSDate *s_lastAutoApplyTime = nil;
static NSTimeInterval s_autoApplyCooldown = 3.0;

static NSDate *s_lastAnalysisTime = nil;
static const NSTimeInterval kMinAnalysisInterval = 0.3;
static NSDate *s_twoFingerStart = nil;
static const NSTimeInterval kTwoFingerHoldDuration = 0.5;
static NSDate *s_ignoreSingleTouchUntil = nil;

// ==================== 前向声明 ====================
@class AdInspectorPanel;
@class AdInspectorWindow;

// ==================== AdInspectorPanel 接口定义 ====================
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
// 新增方法
- (void)showCapturedParams;
- (void)testCapturedParam;
- (void)clearCapturedParams;
- (void)performAutoSkipWithCapturedParam;
- (void)autoApplyRulesIfNeeded;
- (void)toggleAutoApply:(UIButton *)sender;
- (void)performCompleteSkipFlow;
@end

// ==================== AdInspectorWindow 接口定义 ====================
@interface AdInspectorWindow : UIWindow
@property (nonatomic, weak) AdInspectorPanel *panel;
@end
static AdInspectorWindow *s_floatWindow = nil;
// ==================== 函数前向声明 ====================
static NSString *getCallStackSymbols(void);
static Ivar ATFindIvar(Class cls, const char *name);
static SEL ATGetSelectorIvar(id obj, const char *name);
static id ATGetObjectIvarDirect(id obj, const char *name);
static NSArray<UIWindow *> *getAllWindows(void);
static BOOL isFlexingAvailable(void);
static void raiseFlexingWindow(void);
static void startTracking(void);
static void stopTracking(void);
static void hookAllMethodsOfClass(Class cls);
static void startDeepTracking(void);
static NSArray *stopDeepTracking(void);
static void analyzeGestureRecognizer(UIGestureRecognizer *gr, UIView *cur, NSMutableString *o, NSMutableArray *ti);
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
static BOOL isSkipText(NSString *t);

// ==================== 工具函数实现 ====================
static NSString *getCallStackSymbols(void)
{
    void *callstack[128];
    int frames = backtrace(callstack, 128);
    char **strs = backtrace_symbols(callstack, frames);
    NSMutableString *result = [NSMutableString string];
    for (int i = 0; i < frames; i++)
    {
        [result appendFormat:@"%s\n", strs[i]];
    }
    free(strs);
    return result;
}

static Ivar ATFindIvar(Class cls, const char *name)
{
    for (Class c = cls; c; c = class_getSuperclass(c))
    {
        Ivar ivar = class_getInstanceVariable(c, name);
        if (ivar) return ivar;
    }
    return NULL;
}

static SEL ATGetSelectorIvar(id obj, const char *name)
{
    Ivar ivar = ATFindIvar(object_getClass(obj), name);
    if (!ivar) return NULL;
    ptrdiff_t offset = ivar_getOffset(ivar);
    return *(SEL *)((uint8_t *)(__bridge void *)obj + offset);
}

static id ATGetObjectIvarDirect(id obj, const char *name)
{
    Ivar ivar = ATFindIvar(object_getClass(obj), name);
    if (!ivar) return nil;
    return object_getIvar(obj, ivar);
}

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
            [methodName isEqualToString:@"hash"] ||
            [methodName isEqualToString:@"isEqual:"] ||
            [methodName isEqualToString:@"self"] ||
            [methodName isEqualToString:@"performSelector:"] ||
            [methodName isEqualToString:@"respondsToSelector:"] ||
            [methodName isEqualToString:@"methodSignatureForSelector:"] ||
            [methodName isEqualToString:@"forwardInvocation:"] ||
            [methodName isEqualToString:@"doesNotRecognizeSelector:"])
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
                if ([methodName hasPrefix:@"set"] ||
                    [methodName hasPrefix:@"log"] ||
                    [methodName containsString:@"videoPlayer"] ||
                    [methodName isEqualToString:@"adModel"] ||
                    [methodName isEqualToString:@"adConfig"] ||
                    [methodName isEqualToString:@"delegate"] ||
                    [methodName isEqualToString:@"rootView"] ||
                    [methodName isEqualToString:@"gdm"] ||
                    [methodName hasPrefix:@"init"] ||
                    [methodName hasPrefix:@"."] ||
                    [methodName hasPrefix:@"_"] ||
                    [methodName hasPrefix:@"cxx"] ||
                    [methodName isEqualToString:@".cxx_destruct"])
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

static void analyzeGestureRecognizer(UIGestureRecognizer *gr, UIView *cur, NSMutableString *o, NSMutableArray *ti)
{
    @try
    {
        NSArray *tgts = [gr valueForKey:@"_targets"];
        if (tgts && [tgts isKindOfClass:[NSArray class]] && tgts.count > 0)
        {
            for (id t in tgts)
            {
                id target = [t valueForKey:@"_target"];
                id ao = [t valueForKey:@"_action"];
                NSString *as = nil;
                if ([ao isKindOfClass:[NSString class]]) as = ao;
                else if ([ao isKindOfClass:[NSValue class]]) as = NSStringFromSelector((SEL)[ao pointerValue]);
                if (target && as)
                {
                    [o appendFormat:@"    → %@.%@ (KVC)\n", NSStringFromClass([target class]), as];
                    [ti addObject:@{@"viewClass": NSStringFromClass([cur class]), @"gestureClass": NSStringFromClass([gr class]), @"targetClass": NSStringFromClass([target class]), @"action": as}];
                    return;
                }
            }
        }
    }
    @catch (NSException *e) {}

    id targets = ATGetObjectIvarDirect(gr, "_targets");
    if (targets && [targets isKindOfClass:[NSArray class]] && [(NSArray *)targets count] > 0)
    {
        for (id t in (NSArray *)targets)
        {
            id target = ATGetObjectIvarDirect(t, "_target");
            SEL action = ATGetSelectorIvar(t, "_action");
            if (target && action)
            {
                NSString *as = NSStringFromSelector(action);
                [o appendFormat:@"    → %@.%@ (Ivar)\n", NSStringFromClass([target class]), as];
                [ti addObject:@{@"viewClass": NSStringFromClass([cur class]), @"gestureClass": NSStringFromClass([gr class]), @"targetClass": NSStringFromClass([target class]), @"action": as}];
                return;
            }
        }
    }

    if ([gr respondsToSelector:@selector(delegate)] && gr.delegate)
    {
        id delegate = gr.delegate;
        [o appendFormat:@"    delegate: %@\n", NSStringFromClass([delegate class])];
        NSArray *possibleActions = @[@"handleGesture:", @"handleTap:", @"handleSwipe:", @"onTap:", @"onGesture:", @"skipAction", @"closeAction", @"dismissAction", @"adSkipAction", @"onSkip", @"skipAd", @"closeAd", @"dismissAd"];
        for (NSString *actionName in possibleActions)
        {
            SEL sel = NSSelectorFromString(actionName);
            if ([delegate respondsToSelector:sel])
            {
                [o appendFormat:@"    → %@.%@ (delegate可能)\n", NSStringFromClass([delegate class]), actionName];
                [ti addObject:@{@"viewClass": NSStringFromClass([cur class]), @"gestureClass": NSStringFromClass([gr class]), @"targetClass": NSStringFromClass([delegate class]), @"action": actionName}];
                return;
            }
        }
    }
    [o appendString:@"    (无法提取)\n"];
}

static NSString *getControlEventName(UIControlEvents e)
{
    switch (e)
    {
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

static void saveToFile(NSString *log)
{
    @try
    {
        NSArray *p = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        if (p.count == 0) return;
        NSString *pt = [p[0] stringByAppendingPathComponent:@"AdInspector_Logs.txt"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:pt])
        {
            [[NSData data] writeToFile:pt atomically:YES];
        }
        NSFileHandle *f = [NSFileHandle fileHandleForWritingAtPath:pt];
        if (f)
        {
            [f seekToEndOfFile];
            [f writeData:[log dataUsingEncoding:NSUTF8StringEncoding]];
            [f closeFile];
        }
    }
    @catch (NSException *e) {}
}

static void highlightView(UIView *v)
{
    if (!v) return;
    UIColor *oc = nil;
    CGColorRef og = v.layer.borderColor;
    if (og != NULL) oc = [UIColor colorWithCGColor:og];
    CGFloat ow = v.layer.borderWidth;
    v.layer.borderColor = [UIColor redColor].CGColor;
    v.layer.borderWidth = 3.0;
    __weak UIView *wv = v;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong UIView *sv = wv;
        if (sv)
        {
            sv.layer.borderColor = oc ? oc.CGColor : NULL;
            sv.layer.borderWidth = ow;
        }
    });
}

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
        { ei = i; break; }
    }
    NSMutableArray *nr = [ex mutableCopy];
    if (ei >= 0)
    {
        [nr replaceObjectAtIndex:ei withObject:r];
        showToast(@"🔄 规则已更新");
    }
    else
    {
        [nr addObject:r];
        showToast([NSString stringWithFormat:@"✅ 已学习：%@", r[@"buttonTextPattern"]]);
    }
    [ud setObject:nr forKey:kRulesKey];
    [ud synchronize];
}

static UIView *findMatchingView(UIView *rt, NSDictionary *r)
{
    if ([rt isKindOfClass:[AdInspectorPanel class]] ||
        [NSStringFromClass([rt.window class]) isEqualToString:@"AdInspectorWindow"] ||
        (rt.tag >= 1001 && rt.tag <= 1030)) return nil;
    
    NSString *tc = r[@"buttonClass"];
    NSString *tp = r[@"buttonTextPattern"];
    NSArray *ch = r[@"hierarchyChain"];
    
    if ([NSStringFromClass([rt class]) isEqualToString:tc])
    {
        NSString *ct = nil;
        if ([rt isKindOfClass:[UIButton class]])
            ct = [(UIButton *)rt titleForState:UIControlStateNormal];
        else if ([rt isKindOfClass:[UILabel class]])
            ct = [(UILabel *)rt text] ?: [(UILabel *)rt attributedText].string;
        else
            ct = rt.accessibilityLabel;
        if (ct)
        {
            BOOL tm = (tp.length <= 2) ? [ct isEqualToString:tp] : ([ct rangeOfString:tp].location != NSNotFound && ct.length <= 15);
            if (tm)
            {
                NSMutableArray *cc = [NSMutableArray array];
                UIView *cur = rt;
                while (cur && ![cur isKindOfClass:[UIWindow class]])
                {
                    [cc addObject:NSStringFromClass([cur class])];
                    cur = cur.superview;
                }
                if ([cc isEqualToArray:ch]) return rt;
            }
        }
    }
    for (UIView *sb in rt.subviews)
    {
        UIView *f = findMatchingView(sb, r);
        if (f) return f;
    }
    return nil;
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
            [x[@"methodName"] isEqualToString:r[@"methodName"]]) return;
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

static id getObjectByKeyPath(id o, NSString *kp)
{
    if ([kp isEqualToString:@"self"]) return o;
    NSArray *ks = [kp componentsSeparatedByString:@"."];
    id c = o;
    for (NSString *k in ks)
    {
        if (!c) return nil;
        c = [c valueForKey:k];
    }
    return c;
}

static UIView *findViewOfClass(UIView *rt, NSString *cn)
{
    if ([NSStringFromClass([rt class]) isEqualToString:cn]) return rt;
    for (UIView *sb in rt.subviews)
    {
        UIView *f = findViewOfClass(sb, cn);
        if (f) return f;
    }
    return nil;
}

static BOOL isSkipText(NSString *t)
{
    if (!t || t.length == 0) return NO;
    for (NSString *k in @[@"跳过", @"广告", @"关闭", @"×", @"x", @"X", @"close", @"skip", @"Skip", @"Close", @"SKIP", @"CLOSE"])
    {
        if ([t rangeOfString:k options:NSCaseInsensitiveSearch].location != NSNotFound && t.length <= 15) return YES;
    }
    return NO;
}

static UIView *findSkipLabelInView(UIView *rt)
{
    if ([rt isKindOfClass:[AdInspectorPanel class]] || (rt.tag >= 1001 && rt.tag <= 1030)) return nil;
    NSString *ct = nil;
    if ([rt isKindOfClass:[UIButton class]])
        ct = [(UIButton *)rt titleForState:UIControlStateNormal];
    else if ([rt isKindOfClass:[UILabel class]])
        ct = [(UILabel *)rt text] ?: [(UILabel *)rt attributedText].string;
    if (!ct) ct = rt.accessibilityLabel;
    if (isSkipText(ct)) return rt;
    for (UIView *sb in rt.subviews)
    {
        UIView *f = findSkipLabelInView(sb);
        if (f) return f;
    }
    return nil;
}

static void showToast(NSString *m)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *hw = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes)
        {
            if ([s isKindOfClass:[UIWindowScene class]] && s.activationState == UISceneActivationStateForegroundActive)
            {
                for (UIWindow *w in [(UIWindowScene *)s windows])
                {
                    if (w.isKeyWindow) { hw = w; break; }
                }
            }
        }
        if (!hw) return;
        
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

static UIWindow *getKeyWindow(void)
{
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes)
    {
        if ([s isKindOfClass:[UIWindowScene class]] && s.activationState == UISceneActivationStateForegroundActive)
        {
            for (UIWindow *w in [(UIWindowScene *)s windows])
            {
                if (w.isKeyWindow) return w;
            }
        }
    }
    return nil;
}

static void triggerSkip(UIView *v, NSDictionary *r)
{
    if ([v isDescendantOfView:[AdInspectorPanel shared]] ||
        [NSStringFromClass([v.window class]) isEqualToString:@"AdInspectorWindow"]) return;
    NSString *tt = r[@"triggerType"];
    if ([tt isEqualToString:@"controlEvent"])
    {
        if ([v isKindOfClass:[UIControl class]])
        {
            [(UIControl *)v sendActionsForControlEvents:[r[@"controlEvent"] unsignedIntegerValue]];
            showToast(@"⏩ 已自动跳过");
        }
    }
}

static void applyCustomRules(void)
{
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSArray *cr = [ud arrayForKey:kCustomRulesKey];
    if (!cr.count) return;
    
    for (NSDictionary *r in cr)
    {
        NSString *tvc = r[@"targetView"];
        NSString *kp = r[@"keyPath"];
        NSString *mn = r[@"methodName"];
        if (!tvc || !kp || !mn) continue;

        BOOL found = NO;
        id tg = nil;

        for (UIWindow *w in getAllWindows())
        {
            if ([NSStringFromClass([w class]) isEqualToString:@"AdInspectorWindow"]) continue;
            UIView *tv = findViewOfClass(w, tvc);
            if (tv)
            {
                tg = getObjectByKeyPath(tv, kp);
                if (tg) { found = YES; break; }
            }
        }

        if (!found)
        {
            Class targetClass = NSClassFromString(tvc);
            if (targetClass)
            {
                SEL sharedSelectors[] = { @selector(sharedInstance), @selector(sharedManager), @selector(shared), @selector(defaultManager), @selector(instance) };
                for (int i = 0; i < 5 && !tg; i++)
                {
                    if ([targetClass respondsToSelector:sharedSelectors[i]])
                        tg = ((id (*)(id, SEL))objc_msgSend)(targetClass, sharedSelectors[i]);
                }
                if (!tg)
                {
                    for (UIWindow *w in getAllWindows())
                    {
                        if ([NSStringFromClass([w class]) isEqualToString:@"AdInspectorWindow"]) continue;
                        NSMutableArray *views = [NSMutableArray arrayWithArray:w.subviews];
                        while (views.count > 0)
                        {
                            UIView *v = [views lastObject];
                            [views removeLastObject];
                            if ([v respondsToSelector:@selector(delegate)])
                            {
                                id delegate = ((id (*)(id, SEL))objc_msgSend)(v, @selector(delegate));
                                if ([delegate isKindOfClass:targetClass]) { tg = delegate; break; }
                            }
                            id responder = v.nextResponder;
                            while (responder)
                            {
                                if ([responder isKindOfClass:targetClass]) { tg = responder; break; }
                                responder = [responder nextResponder];
                            }
                            if (tg) break;
                            [views addObjectsFromArray:v.subviews];
                        }
                        if (tg) break;
                    }
                }
                if (!tg)
                {
                    id appDelegate = [UIApplication sharedApplication].delegate;
                    @try { tg = [appDelegate valueForKey:tvc]; } @catch (NSException *e) {}
                }
            }
        }

        if ([kp isEqualToString:@"self"] && !tg)
        {
            Class targetClass = NSClassFromString(tvc);
            if (targetClass)
            {
                id appDelegate = [UIApplication sharedApplication].delegate;
                @try { tg = [appDelegate valueForKey:tvc]; } @catch (NSException *e) {}
            }
        }
        else if (tg)
        {
            tg = getObjectByKeyPath(tg, kp);
        }

        if (!tg)
        {
            [[AdInspectorPanel shared] showLog:[NSString stringWithFormat:@"\n⚠️ 未找到 %@ 实例\n", tvc]];
            continue;
        }

        SEL m = NSSelectorFromString(mn);
        if (![tg respondsToSelector:m])
        {
            [[AdInspectorPanel shared] showLog:[NSString stringWithFormat:@"\n⚠️ %@ 不响应 %@\n", NSStringFromClass([tg class]), mn]];
            continue;
        }

        NSMethodSignature *sig = [tg methodSignatureForSelector:m];
        NSUInteger argCount = sig.numberOfArguments;

        if (argCount <= 2)
        {
            ((void (*)(id, SEL))objc_msgSend)(tg, m);
        }
        else
        {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:tg];
            [inv setSelector:m];
            id nilArg = nil;
            for (NSUInteger i = 2; i < argCount; i++)
            {
                [inv setArgument:&nilArg atIndex:i];
            }
            [inv invoke];
        }
        [[AdInspectorPanel shared] showLog:[NSString stringWithFormat:@"✅ 已执行: %@.%@", NSStringFromClass([tg class]), mn]];
    }
    showToast(@"✅ 自定义规则已执行");
}

static void applyAllSavedRules(void)
{
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSArray *cr = [ud arrayForKey:kCustomRulesKey] ?: @[];
    NSArray *ar = [ud arrayForKey:kRulesKey] ?: @[];
    if (cr.count > 0) applyCustomRules();
    if (ar.count > 0)
    {
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes)
        {
            if (![s isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in [(UIWindowScene *)s windows])
            {
                if ([NSStringFromClass([w class]) isEqualToString:@"AdInspectorWindow"]) continue;
                for (NSDictionary *r in ar)
                {
                    UIView *m = findMatchingView(w, r);
                    if (m && !m.hidden && m.alpha > 0)
                    {
                        triggerSkip(m, r);
                        return;
                    }
                }
            }
        }
    }
}

static void analyzeTouchView(UIView *v, CGPoint pt)
{
    if (!v) return;
    if ([v isDescendantOfView:[AdInspectorPanel shared]] ||
        [NSStringFromClass([v.window class]) isEqualToString:@"AdInspectorWindow"] ||
        (v.tag >= 1001 && v.tag <= 1030)) return;
    
    NSDate *n = [NSDate date];
    if (s_lastAnalysisTime && [n timeIntervalSinceDate:s_lastAnalysisTime] < kMinAnalysisInterval) return;
    s_lastAnalysisTime = n;

    UIView *av = findSkipLabelInView(v);
    if (!av) { showToast(@"⚠️ 未检测到跳过按钮"); return; }
    
    @try
    {
        UIWindow *aw = av.window;
        NSString *wc = aw ? NSStringFromClass([aw class]) : @"未知";
        NSMutableString *o = [NSMutableString string];
        [o appendFormat:@"\n══════ %@ ══════\n", [NSDateFormatter localizedStringFromDate:n dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle]];
        
        NSMutableArray *ca = [NSMutableArray array];
        UIView *cur = av;
        while (cur && ![cur isKindOfClass:[UIWindow class]])
        {
            [ca addObject:NSStringFromClass([cur class])];
            cur = cur.superview;
        }
        
        [o appendString:@"📊 视图层级链:\n"];
        cur = av;
        int d = 0;
        while (cur && d < 15)
        {
            NSString *ind = [@"" stringByPaddingToLength:d * 2 withString:@" " startingAtIndex:0];
            [o appendFormat:@"%@▸ %@", ind, NSStringFromClass([cur class])];
            NSMutableArray *tg = [NSMutableArray array];
            if (cur.tag != 0) [tg addObject:[NSString stringWithFormat:@"tag:%ld", (long)cur.tag]];
            if ([cur isKindOfClass:[UIButton class]])
            {
                NSString *t = [(UIButton *)cur titleForState:UIControlStateNormal];
                if (t.length) [tg addObject:[NSString stringWithFormat:@"\"%@\"", t]];
            }
            if ([cur isKindOfClass:[UILabel class]])
            {
                NSString *t = [(UILabel *)cur text] ?: [(UILabel *)cur attributedText].string;
                if (t.length > 20) t = [[t substringToIndex:20] stringByAppendingString:@"..."];
                if (t.length) [tg addObject:[NSString stringWithFormat:@"\"%@\"", t]];
            }
            if (cur.accessibilityLabel.length) [tg addObject:[NSString stringWithFormat:@"a11y:\"%@\"", cur.accessibilityLabel]];
            if (tg.count) [o appendFormat:@" [%@]", [tg componentsJoinedByString:@", "]];
            [o appendFormat:@"\n%@  %@\n", ind, NSStringFromCGRect(cur.frame)];
            cur = cur.superview;
            d++;
        }
        
        [o appendFormat:@"\n🔍 诊断信息:\n  窗口:%@\n  目标:%@\n  frame:%@\n══════\n", wc, NSStringFromClass([av class]), NSStringFromCGRect(av.frame)];
        [[AdInspectorPanel shared] showLog:o];
        saveToFile(o);
        highlightView(av);

        NSString *bt = nil;
        if ([av isKindOfClass:[UIButton class]])
            bt = [(UIButton *)av titleForState:UIControlStateNormal];
        else if ([av isKindOfClass:[UILabel class]])
            bt = [(UILabel *)av text] ?: [(UILabel *)av attributedText].string;
        if (bt.length == 0) bt = av.accessibilityLabel;
        if (bt.length == 0) { showToast(@"⚠️ 按钮无文字"); return; }
        
        NSMutableDictionary *r = [NSMutableDictionary dictionary];
        r[@"buttonClass"] = NSStringFromClass([av class]);
        r[@"buttonTextPattern"] = bt;
        r[@"hierarchyChain"] = ca;
        if (wc) r[@"windowClass"] = wc;
        saveRule(r);
    }
    @catch (NSException *e) { showToast(@"⚠️ 分析异常"); }
}

// ==================== AdInspectorWindow 实现 ====================
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
        if (hit.tag >= 1001 && hit.tag <= 1030) return hit;
        hit = hit.superview;
    }
    return nil;
}

- (void)setHidden:(BOOL)hidden
{
    if (hidden && !self.isHidden) return;
    [super setHidden:hidden];
}

@end

// ==================== AdInspectorPanel 实现 ====================
@implementation AdInspectorPanel

+ (instancetype)shared
{
    static AdInspectorPanel *i = nil;
    static dispatch_once_t t;
    dispatch_once(&t, ^{
        i = [[AdInspectorPanel alloc] initWithFrame:CGRectMake(5, 180, [UIScreen mainScreen].bounds.size.width - 10, 400)];
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
        t.text = @"🔍 AdInspector | 参数捕获";
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
        _targetViewField.placeholder = @"如 GDTDLBusinessManager";
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
        _keyPathField.placeholder = @"如 self 或 delegate";
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
        _methodNameField.placeholder = @"如 onDestroy 或 pauseTimer";
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

        UIButton *p2 = [UIButton buttonWithType:UIButtonTypeSystem];
        p2.frame = CGRectMake(216, 126, 60, 30);
        [p2 setTitle:@"预设2" forState:UIControlStateNormal];
        [p2 setTitleColor:[UIColor cyanColor] forState:UIControlStateNormal];
        p2.titleLabel.font = [UIFont systemFontOfSize:11];
        p2.tag = 1017;
        [p2 addTarget:self action:@selector(fillPreset2) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:p2];

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

        UIButton *viewBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        viewBtn.frame = CGRectMake(self.bounds.size.width - 90, 3, 45, 30);
        [viewBtn setTitle:@"查看" forState:UIControlStateNormal];
        [viewBtn setTitleColor:[UIColor yellowColor] forState:UIControlStateNormal];
        viewBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
        viewBtn.tag = 1006;
        [viewBtn addTarget:self action:@selector(viewRulesTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:viewBtn];

        UIView *handle = [[UIView alloc] initWithFrame:CGRectMake(self.bounds.size.width / 2 - 15, 4, 30, 4)];
        handle.backgroundColor = [UIColor colorWithWhite:0.4 alpha:0.6];
        handle.layer.cornerRadius = 2;
        handle.tag = 1004;
        [self addSubview:handle];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];

        // ==================== 新增按钮 ====================
        
        // 📊参数按钮
        UIButton *showParamBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        showParamBtn.frame = CGRectMake(12, 194, 60, 30);
        [showParamBtn setTitle:@"📊参数" forState:UIControlStateNormal];
        [showParamBtn setTitleColor:[UIColor cyanColor] forState:UIControlStateNormal];
        showParamBtn.titleLabel.font = [UIFont boldSystemFontOfSize:10];
        showParamBtn.tag = 1028;
        [showParamBtn addTarget:self action:@selector(showCapturedParams) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:showParamBtn];

        // 🧪测试按钮
        UIButton *testParamBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        testParamBtn.frame = CGRectMake(80, 194, 60, 30);
        [testParamBtn setTitle:@"🧪测试" forState:UIControlStateNormal];
        [testParamBtn setTitleColor:[UIColor yellowColor] forState:UIControlStateNormal];
        testParamBtn.titleLabel.font = [UIFont boldSystemFontOfSize:10];
        testParamBtn.tag = 1029;
        [testParamBtn addTarget:self action:@selector(testCapturedParam) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:testParamBtn];

        // 🗑️清除按钮
        UIButton *clearParamBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        clearParamBtn.frame = CGRectMake(148, 194, 60, 30);
        [clearParamBtn setTitle:@"🗑️清除" forState:UIControlStateNormal];
        [clearParamBtn setTitleColor:[UIColor redColor] forState:UIControlStateNormal];
        clearParamBtn.titleLabel.font = [UIFont boldSystemFontOfSize:10];
        clearParamBtn.tag = 1030;
        [clearParamBtn addTarget:self action:@selector(clearCapturedParams) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:clearParamBtn];

        // 💪强制跳过按钮
        UIButton *forceSkipBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        forceSkipBtn.frame = CGRectMake(12, 228, 100, 30);
        [forceSkipBtn setTitle:@"💪强制跳过" forState:UIControlStateNormal];
        [forceSkipBtn setTitleColor:[UIColor redColor] forState:UIControlStateNormal];
        forceSkipBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11];
        forceSkipBtn.tag = 1027;
        [forceSkipBtn addTarget:self action:@selector(performCompleteSkipFlow) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:forceSkipBtn];

        // 🤖自动跳过按钮
        UIButton *autoBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        autoBtn.frame = CGRectMake(120, 228, 100, 30);
        [autoBtn setTitle:@"🤖自动跳过" forState:UIControlStateNormal];
        [autoBtn setTitleColor:[UIColor greenColor] forState:UIControlStateNormal];
        autoBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11];
        autoBtn.tag = 1025;
        [autoBtn addTarget:self action:@selector(toggleAutoApply:) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:autoBtn];

        // 日志视图
        CGFloat tvY = 266;
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

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

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

- (BOOL)textFieldShouldReturn:(UITextField *)tf { [tf resignFirstResponder]; return YES; }

- (void)handlePan:(UIPanGestureRecognizer *)p
{
    CGPoint t = [p translationInView:self];
    self.center = CGPointMake(self.center.x + t.x, self.center.y + t.y);
    [p setTranslation:CGPointZero inView:self];
}

- (void)hidePanel { self.hidden = YES; }

- (void)fillPreset1
{
    self.targetViewField.text = @"GDTDLRootView";
    self.keyPathField.text = @"self";
    self.methodNameField.text = @"GDTfunctionu0H2Y8:";
}

- (void)fillPreset2
{
    self.targetViewField.text = @"GDTDLBusinessManager";
    self.keyPathField.text = @"self";
    self.methodNameField.text = @"onDestroy";
}

- (void)copyLog
{
    NSString *text = self.logBuffer;
    if (text.length == 0) { showToast(@"⚠️ 日志为空"); return; }
    [[UIPasteboard generalPasteboard] setString:text];
    showToast(@"✅ 日志已复制到剪贴板");
}

- (void)addCustomRuleFromFields
{
    NSString *tv = self.targetViewField.text;
    NSString *kp = self.keyPathField.text;
    NSString *mn = self.methodNameField.text;
    [self.targetViewField resignFirstResponder];
    [self.keyPathField resignFirstResponder];
    [self.methodNameField resignFirstResponder];
    if (tv.length == 0 || kp.length == 0 || mn.length == 0) { showToast(@"⚠️ 请填写完整规则"); return; }
    NSDictionary *r = @{@"targetView": tv, @"keyPath": kp, @"methodName": mn, @"description": [NSString stringWithFormat:@"%@→%@", tv, mn]};
    saveCustomRule(r);
    [self showLog:[NSString stringWithFormat:@"\n✅ 已添加: %@ → [%@] %@\n", tv, kp, mn]];
    showToast(@"✅ 规则已添加");
}

- (void)testCustomRules { applyCustomRules(); }

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
                [o appendFormat:@"  +%.2fs → %@\n", [e[@"time"] doubleValue], e[@"method"]];
            [self showLog:o];
        }
        else { [self showLog:@"\n⚠️ 未捕获到方法调用\n"]; }
    }
    else
    {
        startTracking();
        [sender setTitle:@"⏹停止追踪" forState:UIControlStateNormal];
        [sender setTitleColor:[UIColor redColor] forState:UIControlStateNormal];
        [self showLog:@"\n🔍 开始追踪... 请手动点击跳过按钮\n"];
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
                [o appendFormat:@"  +%.3fs → %@\n", [e[@"time"] doubleValue], e[@"method"]];
            NSCountedSet *counter = [NSCountedSet set];
            for (NSDictionary *e in methods) [counter addObject:e[@"method"]];
            [o appendString:@"\n📊 方法调用频率:\n"];
            for (NSString *name in counter)
                [o appendFormat:@"  %@ x%lu\n", name, (unsigned long)[counter countForObject:name]];
            [self showLog:o];
        }
        else { [self showLog:@"\n⚠️ 深度追踪未捕获到方法调用\n"]; }
    }
    else
    {
        startDeepTracking();
        [sender setTitle:@"⏹停止深度" forState:UIControlStateNormal];
        [sender setTitleColor:[UIColor redColor] forState:UIControlStateNormal];
        [self showLog:@"\n🔬 深度追踪已开启，点击跳过按钮后回来点停止\n"];
    }
}

- (void)viewRulesTapped
{
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSArray *ar = [ud arrayForKey:kRulesKey] ?: @[];
    NSArray *cr = [ud arrayForKey:kCustomRulesKey] ?: @[];
    NSMutableString *o = [NSMutableString string];
    [o appendFormat:@"\n📋 自动规则 (%lu条):\n", (unsigned long)ar.count];
    for (NSInteger i = 0; i < ar.count; i++)
    {
        NSDictionary *r = ar[i];
        [o appendFormat:@"  %ld: %@ \"%@\" 触发:%@\n", (long)i + 1, r[@"buttonClass"], r[@"buttonTextPattern"], r[@"triggerType"]];
    }
    [o appendFormat:@"\n📋 自定义规则 (%lu条):\n", (unsigned long)cr.count];
    for (NSInteger i = 0; i < cr.count; i++)
    {
        NSDictionary *r = cr[i];
        [o appendFormat:@"  %ld: %@ → [%@] %@\n", (long)i + 1, r[@"targetView"], r[@"keyPath"], r[@"methodName"]];
    }
    [self showLog:o];
}

- (void)forceShow
{
    if (!s_floatWindow)
    {
        UIWindowScene *as = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes)
        {
            if ([s isKindOfClass:[UIWindowScene class]] && s.activationState == UISceneActivationStateForegroundActive)
            { as = (UIWindowScene *)s; break; }
        }
        if (as)
        {
            s_floatWindow = [[AdInspectorWindow alloc] initWithFrame:as.coordinateSpace.bounds];
            s_floatWindow.windowScene = as;
            [s_floatWindow addSubview:self];
            self.frame = CGRectMake(5, 180, s_floatWindow.bounds.size.width - 10, 400);
            self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
            s_floatWindow.panel = self;
            s_floatWindow.hidden = NO;
        }
    }
    else
    {
        if (!self.superview)
        {
            [s_floatWindow addSubview:self];
            self.frame = CGRectMake(5, 180, s_floatWindow.bounds.size.width - 10, 400);
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

- (void)showLog:(NSString *)log
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.logBuffer appendString:log];
        if (self.logBuffer.length > 8000)
            [self.logBuffer deleteCharactersInRange:NSMakeRange(0, self.logBuffer.length - 8000)];
        self.logTextView.text = self.logBuffer;
        if (self.logTextView.text.length > 0)
            [self.logTextView scrollRangeToVisible:NSMakeRange(self.logTextView.text.length - 1, 1)];
    });
}

// ==================== 新增方法实现 ====================

- (void)showCapturedParams {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSInteger savedParam = [ud integerForKey:kCapturedParamKey];
    NSString *savedMethod = [ud stringForKey:kCapturedMethodKey];
    
    NSMutableString *log = [NSMutableString stringWithString:@"\n📊 已捕获的参数:\n"];
    if (savedParam == NSIntegerMin || !savedMethod) {
        [log appendString:@"  ⚠️ 尚未捕获到参数\n  💡 请手动点击一次广告的跳过按钮\n"];
    } else {
        [log appendFormat:@"  方法: %@\n  参数值: %ld\n  状态: ✅ 可用于自动跳过\n", savedMethod, (long)savedParam];
    }
    [self showLog:log];
}

- (void)testCapturedParam {
    NSInteger savedParam = [[NSUserDefaults standardUserDefaults] integerForKey:kCapturedParamKey];
    if (savedParam == NSIntegerMin) {
        [self showLog:@"⚠️ 没有已保存的参数，请先手动跳过广告一次"];
        showToast(@"⚠️ 请先手动跳过广告");
        return;
    }
    
    UIView *rootView = nil;
    for (UIWindow *window in getAllWindows()) {
        if ([NSStringFromClass([window class]) isEqualToString:@"AdInspectorWindow"]) continue;
        rootView = findViewOfClass(window, @"GDTDLRootView");
        if (rootView && !rootView.hidden) break;
    }
    
    if (!rootView) {
        [self showLog:@"⚠️ 未找到 GDTDLRootView"];
        showToast(@"⚠️ 未检测到广告");
        return;
    }
    
    SEL selector = NSSelectorFromString(@"GDTfunctionu0H2Y8:");
    if ([rootView respondsToSelector:selector]) {
        [self showLog:[NSString stringWithFormat:@"🧪 测试跳过: 使用参数 %ld", (long)savedParam]];
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(rootView, selector, savedParam);
        showToast(@"🧪 参数已测试");
    } else {
        [self showLog:@"❌ 不响应 GDTfunctionu0H2Y8:"];
    }
}

- (void)clearCapturedParams {
    s_capturedSkipParam = NSIntegerMin;
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kCapturedParamKey];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kCapturedMethodKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self showLog:@"🗑️ 已清除捕获的参数"];
    showToast(@"🗑️ 参数已清除");
}

- (void)performAutoSkipWithCapturedParam {
    NSInteger savedParam = [[NSUserDefaults standardUserDefaults] integerForKey:kCapturedParamKey];
    if (savedParam == NSIntegerMin) return;
    
    UIView *rootView = nil;
    BOOL hasSkipButton = NO;
    
    for (UIWindow *window in getAllWindows()) {
        if ([NSStringFromClass([window class]) isEqualToString:@"AdInspectorWindow"]) continue;
        UIView *splashView = findViewOfClass(window, @"GDTSplashDLView");
        if (splashView && !splashView.hidden && splashView.alpha > 0.1) {
            rootView = findViewOfClass(window, @"GDTDLRootView");
            if (rootView && !rootView.hidden) {
                UIView *skipLabel = findSkipLabelInView(rootView);
                if (skipLabel && !skipLabel.hidden && skipLabel.alpha > 0.1) {
                    hasSkipButton = YES;
                    break;
                }
            }
        }
    }
    
    if (rootView && hasSkipButton) {
        SEL selector = NSSelectorFromString(@"GDTfunctionu0H2Y8:");
        if ([rootView respondsToSelector:selector]) {
            [self showLog:[NSString stringWithFormat:@"🤖 自动跳过: 使用参数 %ld", (long)savedParam]];
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(rootView, selector, savedParam);
            s_lastAutoApplyTime = [NSDate date];
        }
    }
}

- (void)autoApplyRulesIfNeeded {
    if (s_lastAutoApplyTime && [[NSDate date] timeIntervalSinceDate:s_lastAutoApplyTime] < s_autoApplyCooldown) return;
    NSInteger savedParam = [[NSUserDefaults standardUserDefaults] integerForKey:kCapturedParamKey];
    if (savedParam != NSIntegerMin) {
        [self performAutoSkipWithCapturedParam];
    }
}

- (void)toggleAutoApply:(UIButton *)sender {
    s_autoApplyRulesEnabled = !s_autoApplyRulesEnabled;
    if (s_autoApplyRulesEnabled) {
        NSInteger savedParam = [[NSUserDefaults standardUserDefaults] integerForKey:kCapturedParamKey];
        [sender setTitle:@"🤖自动跳过" forState:UIControlStateNormal];
        [sender setTitleColor:[UIColor greenColor] forState:UIControlStateNormal];
        if (!s_autoApplyTimer) {
            __weak typeof(self) weakSelf = self;
            s_autoApplyTimer = [NSTimer scheduledTimerWithTimeInterval:s_autoApplyInterval repeats:YES block:^(NSTimer *timer) {
                [weakSelf autoApplyRulesIfNeeded];
            }];
        }
        [self showLog:savedParam != NSIntegerMin ? [NSString stringWithFormat:@"✅ 自动跳过已开启 (参数:%ld)", (long)savedParam] : @"⚠️ 还没有捕获参数\n💡 请手动点击一次跳过按钮"];
        showToast(@"🤖 自动跳过已开启");
    } else {
        [sender setTitle:@"🔴停止跳过" forState:UIControlStateNormal];
        [sender setTitleColor:[UIColor redColor] forState:UIControlStateNormal];
        [s_autoApplyTimer invalidate];
        s_autoApplyTimer = nil;
        [self showLog:@"⏸️ 自动跳过已停止"];
        showToast(@"⏸️ 自动跳过已停止");
    }
}

- (void)performCompleteSkipFlow {
    UIView *rootView = nil;
    for (UIWindow *window in getAllWindows()) {
        if ([NSStringFromClass([window class]) isEqualToString:@"AdInspectorWindow"]) continue;
        rootView = findViewOfClass(window, @"GDTDLRootView");
        if (rootView && !rootView.hidden) {
            UIView *skipLabel = findSkipLabelInView(rootView);
            if (skipLabel && !skipLabel.hidden) break;
            rootView = nil;
        }
    }
    if (!rootView) { [self showLog:@"⚠️ 未检测到广告"]; showToast(@"⚠️ 未检测到广告"); return; }
    
    NSInteger skipParam = [[NSUserDefaults standardUserDefaults] integerForKey:kCapturedParamKey];
    if (skipParam == NSIntegerMin) skipParam = 1;
    
    if ([rootView respondsToSelector:NSSelectorFromString(@"GDTfunctionu0H2Y8:")]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(rootView, NSSelectorFromString(@"GDTfunctionu0H2Y8:"), skipParam);
    }
    [self showLog:@"✅ 强制跳过已执行"];
    showToast(@"✅ 强制跳过");
}

@end

// ==================== Hook 部分 ====================

%hook GDTDLRootView

- (void)GDTfunctionm80Ge8:(id)arg1 beganWithTouches:(id)arg2 andEvent:(id)arg3 {
    s_isCapturingParams = YES;
    [[AdInspectorPanel shared] showLog:@"🔍 开始捕获跳过参数..."];
    %orig;
}

- (void)GDTfunctionm80Ge8:(id)arg1 endedWithTouches:(id)arg2 andEvent:(id)arg3 {
    [[AdInspectorPanel shared] showLog:@"👆 触摸事件结束"];
    %orig;
}

- (void)GDTfunctiont2vpjZ:(id)arg1 event:(id)arg2 {
    [[AdInspectorPanel shared] showLog:[NSString stringWithFormat:@"🖐 手势触发: %@", NSStringFromSelector(_cmd)]];
    %orig;
}

- (void)GDTfunctionu0H2Y8:(NSInteger)arg1 {
    NSMutableString *log = [NSMutableString string];
    [log appendFormat:@"\n🎯🎯🎯 捕获到跳过方法调用! 🎯🎯🎯\n"];
    [log appendFormat:@"方法: GDTfunctionu0H2Y8:\n"];
    [log appendFormat:@"参数值: %ld\n", (long)arg1];
    [log appendFormat:@"参数类型: NSInteger\n"];
    
    s_capturedSkipParam = arg1;
    [[NSUserDefaults standardUserDefaults] setInteger:arg1 forKey:kCapturedParamKey];
    [[NSUserDefaults standardUserDefaults] setObject:@"GDTfunctionu0H2Y8:" forKey:kCapturedMethodKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    [log appendString:@"\n✅ 参数已保存，可用于自动跳过\n"];
    [[AdInspectorPanel shared] showLog:log];
    saveToFile(log);
    
    s_isCapturingParams = NO;
    %orig;
}

%end

%hook GDTDLBusinessManager

- (void)onDestroy {
    if (s_isCapturingParams) {
        [[AdInspectorPanel shared] showLog:@"💀 广告被销毁: onDestroy"];
    }
    %orig;
}

%end

%hook UIGestureRecognizer
- (void)setState:(UIGestureRecognizerState)state
{
    %orig;
    if (state == UIGestureRecognizerStateEnded)
    {
        UIView *view = self.view;
        if (!view) return;
        
        UIView *skipView = findSkipLabelInView(view);
        if (skipView)
        {
            NSString *callStack = getCallStackSymbols();
            NSMutableString *log = [NSMutableString string];
            [log appendFormat:@"\n🔔 手势触发! 手势:%@ View:%@\n", NSStringFromClass([self class]), NSStringFromClass([view class])];
            [log appendFormat:@"📚 调用栈:\n%@\n", callStack];
            
            @try {
                id delegate = self.delegate;
                if (delegate) [log appendFormat:@"🎯 delegate: %@\n", NSStringFromClass([delegate class])];
            } @catch (NSException *e) {}
            
            [log appendString:@"══════\n"];
            [[AdInspectorPanel shared] showLog:log];
            saveToFile(log);
        }
    }
}
%end

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
                { as = NO; break; }
            }
            if (as && !s_twoFingerStart) s_twoFingerStart = [NSDate date];
            if (s_twoFingerStart && [[NSDate date] timeIntervalSinceDate:s_twoFingerStart] >= kTwoFingerHoldDuration)
            {
                AdInspectorPanel *p = [AdInspectorPanel shared];
                if (p.hidden) [p forceShow];
                s_twoFingerStart = nil;
                s_ignoreSingleTouchUntil = [NSDate dateWithTimeIntervalSinceNow:0.5];
            }
        }
        else { s_twoFingerStart = nil; }
        
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

%hook UIControl
- (void)addTarget:(id)t action:(SEL)a forControlEvents:(UIControlEvents)e
{
    NSLog(@"[AdInspector] 🔗 %@ → %@.%@ [%@]", NSStringFromClass([self class]), NSStringFromClass([t class]), NSStringFromSelector(a), getControlEventName(e));
    %orig;
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
            { as = (UIWindowScene *)s; break; }
        }
        if (as)
        {
            s_floatWindow = [[AdInspectorWindow alloc] initWithFrame:as.coordinateSpace.bounds];
            s_floatWindow.windowScene = as;
            AdInspectorPanel *p = [AdInspectorPanel shared];
            p.frame = CGRectMake(5, 180, s_floatWindow.bounds.size.width - 10, 400);
            p.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
            [s_floatWindow addSubview:p];
            s_floatWindow.panel = p;
            s_floatWindow.hidden = NO;
        }

        hookAllMethodsOfClass(NSClassFromString(@"GDTDLBusinessManager"));

        showToast(@"🔍 已激活 | 双指呼面板 | 参数捕获");
        if (isFlexingAvailable()) raiseFlexingWindow();
        
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
            applyAllSavedRules();
            if (s_floatWindow && !s_isKeyboardVisible) s_floatWindow.hidden = NO;
            if (isFlexingAvailable()) raiseFlexingWindow();
        }];
    });
}
#pragma clang diagnostic pop
