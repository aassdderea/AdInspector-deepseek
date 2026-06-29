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

// ==================== 全局变量 ====================
static NSMutableArray *s_trackedMethods = nil;
static BOOL s_isTracking = NO;
static NSDate *s_trackStartTime = nil;
static BOOL s_isDeepTracking = NO;
static NSDate *s_deepTrackStartTime = nil;
static NSMutableArray *s_deepTrackedMethods = nil;
static BOOL s_isKeyboardVisible = NO;

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
@end

// ==================== AdInspectorWindow 接口定义 ====================
@interface AdInspectorWindow : UIWindow
@property (nonatomic, weak) AdInspectorPanel *panel;
@end
static AdInspectorWindow *s_floatWindow = nil;

// ==================== 函数前向声明 ====================
static NSString *getCallStackSymbols(void);
static NSArray<UIWindow *> *getAllWindows(void);
static BOOL isFlexingAvailable(void);
static void raiseFlexingWindow(void);
static void startTracking(void);
static void stopTracking(void);
static void hookAllMethodsOfClass(Class cls);
static void startDeepTracking(void);
static NSArray *stopDeepTracking(void);
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
    for (int i = 0; i < frames; i++) { [result appendFormat:@"%s\n", strs[i]]; }
    free(strs);
    return result;
}

static NSArray<UIWindow *> *getAllWindows(void)
{
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

static BOOL isFlexingAvailable(void)
{
    for (UIWindow *w in getAllWindows()) {
        NSString *cn = NSStringFromClass([w class]);
        if ([cn isEqualToString:@"FLEXWindow"] || [cn isEqualToString:@"FLEXExplorerWindow"] ||
            [cn isEqualToString:@"FLEXManagerWindow"] || [cn isEqualToString:@"FLEXOverlayWindow"]) return YES;
    }
    return NO;
}

static void raiseFlexingWindow(void)
{
    if (s_isKeyboardVisible) return;
    for (UIWindow *w in getAllWindows()) {
        NSString *cn = NSStringFromClass([w class]);
        if ([cn isEqualToString:@"FLEXWindow"] || [cn isEqualToString:@"FLEXExplorerWindow"] ||
            [cn isEqualToString:@"FLEXManagerWindow"] || [cn isEqualToString:@"FLEXOverlayWindow"]) {
            w.windowLevel = CGFLOAT_MAX; w.hidden = NO; w.alpha = 1.0; [w makeKeyAndVisible]; return;
        }
    }
}

static void startTracking(void) { s_trackedMethods = [NSMutableArray array]; s_isTracking = YES; s_trackStartTime = [NSDate date]; }
static void stopTracking(void) { s_isTracking = NO; }

static void hookAllMethodsOfClass(Class cls)
{
    if (!cls) return;
    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(cls, &methodCount);
    for (unsigned int i = 0; i < methodCount; i++) {
        SEL sel = method_getName(methods[i]);
        NSString *methodName = NSStringFromSelector(sel);
        if ([methodName hasPrefix:@"."] || [methodName hasPrefix:@"init"] || [methodName isEqualToString:@"dealloc"] ||
            [methodName isEqualToString:@"class"] || [methodName isEqualToString:@"hash"] || [methodName isEqualToString:@"isEqual:"] ||
            [methodName isEqualToString:@"self"] || [methodName isEqualToString:@"performSelector:"] ||
            [methodName isEqualToString:@"respondsToSelector:"] || [methodName isEqualToString:@"methodSignatureForSelector:"] ||
            [methodName isEqualToString:@"forwardInvocation:"] || [methodName isEqualToString:@"doesNotRecognizeSelector:"]) continue;
        const char *typeEncoding = method_getTypeEncoding(methods[i]);
        if (typeEncoding && typeEncoding[0] == 'v') {
            IMP originalIMP = method_getImplementation(methods[i]);
            NSString *fullMethodName = [NSString stringWithFormat:@"[%@] %@", NSStringFromClass(cls), methodName];
            id newBlock = ^(id self) {
                if (originalIMP) ((void (*)(id, SEL))originalIMP)(self, sel);
                if (!s_isTracking && !s_isDeepTracking) return;
                if ([methodName hasPrefix:@"set"] || [methodName hasPrefix:@"log"] || [methodName containsString:@"videoPlayer"] ||
                    [methodName isEqualToString:@"adModel"] || [methodName isEqualToString:@"adConfig"] ||
                    [methodName isEqualToString:@"delegate"] || [methodName isEqualToString:@"rootView"] ||
                    [methodName isEqualToString:@"gdm"] || [methodName hasPrefix:@"init"] || [methodName hasPrefix:@"."] ||
                    [methodName hasPrefix:@"_"] || [methodName hasPrefix:@"cxx"] || [methodName isEqualToString:@".cxx_destruct"]) return;
                if (s_isTracking) {
                    @synchronized(s_trackedMethods) {
                        [s_trackedMethods addObject:@{@"method": fullMethodName, @"time": @([[NSDate date] timeIntervalSinceDate:s_trackStartTime])}];
                    }
                }
                if (s_isDeepTracking) {
                    @synchronized(s_deepTrackedMethods) {
                        [s_deepTrackedMethods addObject:@{@"method": fullMethodName, @"time": @([[NSDate date] timeIntervalSinceDate:s_deepTrackStartTime])}];
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
    s_deepTrackedMethods = [NSMutableArray array]; s_isDeepTracking = YES; s_deepTrackStartTime = [NSDate date];
    hookAllMethodsOfClass(NSClassFromString(@"GDTDLBusinessManager"));
    hookAllMethodsOfClass(NSClassFromString(@"GDTDLRootView"));
    hookAllMethodsOfClass(NSClassFromString(@"GDTSplashDLView"));
}

static NSArray *stopDeepTracking(void)
{
    s_isDeepTracking = NO; NSArray *result = [s_deepTrackedMethods copy]; s_deepTrackedMethods = nil; s_deepTrackStartTime = nil; return result;
}

static NSString *getControlEventName(UIControlEvents e)
{
    switch (e) {
        case UIControlEventTouchDown: return @"TouchDown";
        case UIControlEventTouchUpInside: return @"TouchUpInside";
        case UIControlEventValueChanged: return @"ValueChanged";
        default: return [NSString stringWithFormat:@"Evt%lu", (unsigned long)e];
    }
}

static void saveToFile(NSString *log)
{
    @try {
        NSArray *p = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        if (p.count == 0) return;
        NSString *pt = [p[0] stringByAppendingPathComponent:@"AdInspector_Logs.txt"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:pt]) { [[NSData data] writeToFile:pt atomically:YES]; }
        NSFileHandle *f = [NSFileHandle fileHandleForWritingAtPath:pt];
        if (f) { [f seekToEndOfFile]; [f writeData:[log dataUsingEncoding:NSUTF8StringEncoding]]; [f closeFile]; }
    } @catch (NSException *e) {}
}

static void highlightView(UIView *v)
{
    if (!v) return;
    UIColor *oc = nil; CGColorRef og = v.layer.borderColor;
    if (og != NULL) oc = [UIColor colorWithCGColor:og];
    CGFloat ow = v.layer.borderWidth;
    v.layer.borderColor = [UIColor redColor].CGColor; v.layer.borderWidth = 3.0;
    __weak UIView *wv = v;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong UIView *sv = wv;
        if (sv) { sv.layer.borderColor = oc ? oc.CGColor : NULL; sv.layer.borderWidth = ow; }
    });
}

static void saveRule(NSDictionary *r)
{
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSArray *ex = [ud arrayForKey:kRulesKey] ?: @[];
    NSInteger ei = -1;
    for (NSInteger i = 0; i < ex.count; i++) {
        NSDictionary *x = ex[i];
        if ([x[@"buttonClass"] isEqualToString:r[@"buttonClass"]] &&
            [x[@"buttonTextPattern"] isEqualToString:r[@"buttonTextPattern"]] &&
            [x[@"hierarchyChain"] isEqualToArray:r[@"hierarchyChain"]]) { ei = i; break; }
    }
    NSMutableArray *nr = [ex mutableCopy];
    if (ei >= 0) { [nr replaceObjectAtIndex:ei withObject:r]; showToast(@"🔄 规则已更新"); }
    else { [nr addObject:r]; showToast([NSString stringWithFormat:@"✅ 已学习：%@", r[@"buttonTextPattern"]]); }
    [ud setObject:nr forKey:kRulesKey]; [ud synchronize];
}

static UIView *findMatchingView(UIView *rt, NSDictionary *r)
{
    if ([rt isKindOfClass:[AdInspectorPanel class]] || [NSStringFromClass([rt.window class]) isEqualToString:@"AdInspectorWindow"] || (rt.tag >= 1001 && rt.tag <= 1030)) return nil;
    NSString *tc = r[@"buttonClass"], *tp = r[@"buttonTextPattern"]; NSArray *ch = r[@"hierarchyChain"];
    if ([NSStringFromClass([rt class]) isEqualToString:tc]) {
        NSString *ct = nil;
        if ([rt isKindOfClass:[UIButton class]]) ct = [(UIButton *)rt titleForState:UIControlStateNormal];
        else if ([rt isKindOfClass:[UILabel class]]) ct = [(UILabel *)rt text] ?: [(UILabel *)rt attributedText].string;
        else ct = rt.accessibilityLabel;
        if (ct) {
            BOOL tm = (tp.length <= 2) ? [ct isEqualToString:tp] : ([ct rangeOfString:tp].location != NSNotFound && ct.length <= 15);
            if (tm) {
                NSMutableArray *cc = [NSMutableArray array]; UIView *cur = rt;
                while (cur && ![cur isKindOfClass:[UIWindow class]]) { [cc addObject:NSStringFromClass([cur class])]; cur = cur.superview; }
                if ([cc isEqualToArray:ch]) return rt;
            }
        }
    }
    for (UIView *sb in rt.subviews) { UIView *f = findMatchingView(sb, r); if (f) return f; }
    return nil;
}

static void clearAllRules(void) { [[NSUserDefaults standardUserDefaults] removeObjectForKey:kRulesKey]; [[NSUserDefaults standardUserDefaults] synchronize]; }

static void saveCustomRule(NSDictionary *r)
{
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSArray *ex = [ud arrayForKey:kCustomRulesKey] ?: @[];
    for (NSDictionary *x in ex) {
        if ([x[@"targetView"] isEqualToString:r[@"targetView"]] && [x[@"keyPath"] isEqualToString:r[@"keyPath"]] && [x[@"methodName"] isEqualToString:r[@"methodName"]]) return;
    }
    NSMutableArray *nr = [ex mutableCopy]; [nr addObject:r];
    [ud setObject:nr forKey:kCustomRulesKey]; [ud synchronize];
}

static void clearCustomRules(void) { [[NSUserDefaults standardUserDefaults] removeObjectForKey:kCustomRulesKey]; [[NSUserDefaults standardUserDefaults] synchronize]; }

static id getObjectByKeyPath(id o, NSString *kp)
{
    if ([kp isEqualToString:@"self"]) return o;
    NSArray *ks = [kp componentsSeparatedByString:@"."]; id c = o;
    for (NSString *k in ks) { if (!c) return nil; c = [c valueForKey:k]; }
    return c;
}

static UIView *findViewOfClass(UIView *rt, NSString *cn)
{
    if ([NSStringFromClass([rt class]) isEqualToString:cn]) return rt;
    for (UIView *sb in rt.subviews) { UIView *f = findViewOfClass(sb, cn); if (f) return f; }
    return nil;
}

static BOOL isSkipText(NSString *t)
{
    if (!t || t.length == 0) return NO;
    for (NSString *k in @[@"跳过", @"广告", @"关闭", @"×", @"x", @"X", @"close", @"skip", @"Skip", @"Close", @"SKIP", @"CLOSE"]) {
        if ([t rangeOfString:k options:NSCaseInsensitiveSearch].location != NSNotFound && t.length <= 15) return YES;
    }
    return NO;
}

static UIView *findSkipLabelInView(UIView *rt)
{
    if ([rt isKindOfClass:[AdInspectorPanel class]] || (rt.tag >= 1001 && rt.tag <= 1030)) return nil;
    NSString *ct = nil;
    if ([rt isKindOfClass:[UIButton class]]) ct = [(UIButton *)rt titleForState:UIControlStateNormal];
    else if ([rt isKindOfClass:[UILabel class]]) ct = [(UILabel *)rt text] ?: [(UILabel *)rt attributedText].string;
    if (!ct) ct = rt.accessibilityLabel;
    if (isSkipText(ct)) return rt;
    for (UIView *sb in rt.subviews) { UIView *f = findSkipLabelInView(sb); if (f) return f; }
    return nil;
}

static void showToast(NSString *m)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *hw = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]] && s.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *w in [(UIWindowScene *)s windows]) { if (w.isKeyWindow) { hw = w; break; } }
            }
        }
        if (!hw) return;
        UIView *t = [[UIView alloc] init];
        t.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85]; t.layer.cornerRadius = 12;
        UILabel *l = [[UILabel alloc] init];
        l.text = m; l.textColor = [UIColor whiteColor]; l.font = [UIFont boldSystemFontOfSize:14]; l.numberOfLines = 0; l.textAlignment = NSTextAlignmentCenter;
        [t addSubview:l];
        CGSize ms = CGSizeMake([UIScreen mainScreen].bounds.size.width - 60, CGFLOAT_MAX);
        CGRect tr = [m boundingRectWithSize:ms options:NSStringDrawingUsesLineFragmentOrigin attributes:@{NSFontAttributeName: l.font} context:nil];
        CGFloat w = tr.size.width + 30, h = tr.size.height + 16;
        l.frame = CGRectMake(15, 8, tr.size.width, tr.size.height);
        CGPoint c = CGPointMake(hw.bounds.size.width / 2, hw.bounds.size.height - 150);
        t.frame = CGRectMake(c.x - w / 2, c.y - h / 2, w, h); t.layer.zPosition = CGFLOAT_MAX;
        [hw addSubview:t];
        [UIView animateWithDuration:0.3 delay:1.5 options:UIViewAnimationOptionCurveEaseOut animations:^{ t.alpha = 0; } completion:^(BOOL f) { [t removeFromSuperview]; }];
    });
}

static void triggerSkip(UIView *v, NSDictionary *r)
{
    if ([v isDescendantOfView:[AdInspectorPanel shared]] || [NSStringFromClass([v.window class]) isEqualToString:@"AdInspectorWindow"]) return;
    if ([r[@"triggerType"] isEqualToString:@"controlEvent"] && [v isKindOfClass:[UIControl class]]) {
        [(UIControl *)v sendActionsForControlEvents:[r[@"controlEvent"] unsignedIntegerValue]];
        showToast(@"⏩ 已自动跳过");
    }
}

// ==================== 自定义规则执行（Toast + 日志）====================
static void applyCustomRules(void)
{
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSArray *cr = [ud arrayForKey:kCustomRulesKey];
    if (!cr.count) {
        showToast(@"⚠️ 没有自定义规则");
        [[AdInspectorPanel shared] showLog:@"\n⚠️ 没有自定义规则\n"];
        return;
    }
    
    for (NSDictionary *r in cr) {
        NSString *tvc = r[@"targetView"], *kp = r[@"keyPath"], *mn = r[@"methodName"];
        if (!tvc || !kp || !mn) continue;
        
        NSString *actualMethod = mn, *paramStr = nil;
        NSRange commaRange = [mn rangeOfString:@","];
        if (commaRange.location != NSNotFound) {
            actualMethod = [mn substringToIndex:commaRange.location];
            paramStr = [mn substringFromIndex:commaRange.location + 1];
        }
        
        BOOL found = NO; id tg = nil;
        for (UIWindow *w in getAllWindows()) {
            if ([NSStringFromClass([w class]) isEqualToString:@"AdInspectorWindow"]) continue;
            UIView *tv = findViewOfClass(w, tvc);
            if (tv) { tg = getObjectByKeyPath(tv, kp); if (tg) { found = YES; break; } }
        }
        if (!found) {
            Class tc = NSClassFromString(tvc);
            if (tc) {
                SEL ss[] = {@selector(sharedInstance), @selector(sharedManager), @selector(shared), @selector(defaultManager), @selector(instance)};
                for (int i = 0; i < 5 && !tg; i++) { if ([tc respondsToSelector:ss[i]]) tg = ((id(*)(id,SEL))objc_msgSend)(tc, ss[i]); }
                if (!tg) { id ad = [UIApplication sharedApplication].delegate; @try { tg = [ad valueForKey:tvc]; } @catch(NSException *e) {} }
            }
        }
        if ([kp isEqualToString:@"self"] && !tg) { Class tc = NSClassFromString(tvc); if (tc) { id ad = [UIApplication sharedApplication].delegate; @try { tg = [ad valueForKey:tvc]; } @catch(NSException *e) {} } }
        else if (tg) { tg = getObjectByKeyPath(tg, kp); }
        
        if (!tg) {
            NSString *msg = [NSString stringWithFormat:@"❌ 未找到 %@ 实例", tvc];
            showToast(msg);
            [[AdInspectorPanel shared] showLog:[NSString stringWithFormat:@"\n%@\n", msg]];
            continue;
        }
        
        SEL m = NSSelectorFromString(actualMethod);
        if (![tg respondsToSelector:m]) {
            NSString *msg = [NSString stringWithFormat:@"❌ %@ 不响应 %@", NSStringFromClass([tg class]), actualMethod];
            showToast(msg);
            [[AdInspectorPanel shared] showLog:[NSString stringWithFormat:@"\n%@\n", msg]];
            continue;
        }
        
        NSMethodSignature *sig = [tg methodSignatureForSelector:m];
        NSUInteger ac = sig.numberOfArguments;
        NSString *logMsg = nil;
        
        if (ac <= 2) {
            ((void(*)(id,SEL))objc_msgSend)(tg, m);
            logMsg = [NSString stringWithFormat:@"✅ %@.%@ (无参) 已执行", NSStringFromClass([tg class]), actualMethod];
            showToast([NSString stringWithFormat:@"✅ %@ (无参)", actualMethod]);
        } else if (ac == 3 && paramStr) {
            const char *type = [sig getArgumentTypeAtIndex:2];
            if (strcmp(type,"q")==0 || strcmp(type,"i")==0 || strcmp(type,"Q")==0) {
                NSInteger val = [paramStr integerValue];
                
                // 查找跳过按钮的父视图来触发手势
                UIView *skipLabel = findSkipLabelInView(tg);
                UIView *targetView = skipLabel ?: tg;
                
                // 遍历手势识别器，找到 GDTSystemGestureRecognizer 并触发
                BOOL gestureTriggered = NO;
                for (UIGestureRecognizer *gr in targetView.gestureRecognizers) {
                    if ([NSStringFromClass([gr class]) containsString:@"GDTSystem"]) {
                        // 模拟手势状态变化：Began → Ended
                        [gr setValue:@(UIGestureRecognizerStateBegan) forKey:@"state"];
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.01 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            [gr setValue:@(UIGestureRecognizerStateEnded) forKey:@"state"];
                        });
                        gestureTriggered = YES;
                        break;
                    }
                }
                
                // 也遍历父视图的手势
                if (!gestureTriggered) {
                    UIView *parent = targetView.superview;
                    for (int i = 0; i < 5 && parent && !gestureTriggered; i++) {
                        for (UIGestureRecognizer *gr in parent.gestureRecognizers) {
                            if ([NSStringFromClass([gr class]) containsString:@"GDTSystem"]) {
                                [gr setValue:@(UIGestureRecognizerStateBegan) forKey:@"state"];
                                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.01 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                    [gr setValue:@(UIGestureRecognizerStateEnded) forKey:@"state"];
                                });
                                gestureTriggered = YES;
                                break;
                            }
                        }
                        parent = parent.superview;
                    }
                }
                
                // 同时直接调用跳过方法
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    ((void(*)(id,SEL,NSInteger))objc_msgSend)(tg, m, val);
                });
                
                if (gestureTriggered) {
                    logMsg = [NSString stringWithFormat:@"✅ %@.%@ 手势触发+参数:%ld 已执行", NSStringFromClass([tg class]), actualMethod, (long)val];
                    showToast([NSString stringWithFormat:@"✅ 手势+%@(%ld)", actualMethod, (long)val]);
                } else {
                    logMsg = [NSString stringWithFormat:@"⚠️ %@.%@ 参数:%ld 已执行(未找到手势)", NSStringFromClass([tg class]), actualMethod, (long)val];
                    showToast([NSString stringWithFormat:@"⚠️ %@(%ld)无手势", actualMethod, (long)val]);
                }

            } else if (strcmp(type,"B")==0) {
                BOOL val = [paramStr boolValue];
                ((void(*)(id,SEL,BOOL))objc_msgSend)(tg, m, val);
                logMsg = [NSString stringWithFormat:@"✅ %@.%@ 参数:%d 类型:BOOL 已执行", NSStringFromClass([tg class]), actualMethod, val];
                showToast([NSString stringWithFormat:@"✅ %@(%d)", actualMethod, val]);
            } else if (strcmp(type,"d")==0) {
                double val = [paramStr doubleValue];
                ((void(*)(id,SEL,double))objc_msgSend)(tg, m, val);
                logMsg = [NSString stringWithFormat:@"✅ %@.%@ 参数:%.1f 类型:double 已执行", NSStringFromClass([tg class]), actualMethod, val];
                showToast([NSString stringWithFormat:@"✅ %@(%.1f)", actualMethod, val]);
            } else {
                ((void(*)(id,SEL,id))objc_msgSend)(tg, m, paramStr);
                logMsg = [NSString stringWithFormat:@"✅ %@.%@ 参数:\"%@\" 类型:NSString 已执行", NSStringFromClass([tg class]), actualMethod, paramStr];
                showToast([NSString stringWithFormat:@"✅ %@(@)", actualMethod]);
            }
        } else if (ac == 3 && !paramStr) {
            ((void(*)(id,SEL,id))objc_msgSend)(tg, m, nil);
            logMsg = [NSString stringWithFormat:@"⚠️ %@.%@ 参数:nil (方法需要参数但未提供)", NSStringFromClass([tg class]), actualMethod];
            showToast([NSString stringWithFormat:@"⚠️ %@(nil) 缺参数", actualMethod]);
        } else {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:tg]; [inv setSelector:m];
            id nilArg = nil;
            for (NSUInteger i = 2; i < ac; i++) [inv setArgument:&nilArg atIndex:i];
            [inv invoke];
            logMsg = [NSString stringWithFormat:@"✅ %@.%@ (%lu个参数，均传nil) 已执行", NSStringFromClass([tg class]), actualMethod, (unsigned long)(ac-2)];
            showToast([NSString stringWithFormat:@"✅ %@ (多参nil)", actualMethod]);
        }
        
        [[AdInspectorPanel shared] showLog:[NSString stringWithFormat:@"\n%@\n", logMsg]];
    }
}

static void applyAllSavedRules(void)
{
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSArray *cr = [ud arrayForKey:kCustomRulesKey] ?: @[], *ar = [ud arrayForKey:kRulesKey] ?: @[];
    if (cr.count > 0) applyCustomRules();
    if (ar.count > 0) {
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if (![s isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in [(UIWindowScene *)s windows]) {
                if ([NSStringFromClass([w class]) isEqualToString:@"AdInspectorWindow"]) continue;
                for (NSDictionary *r in ar) { UIView *m = findMatchingView(w, r); if (m && !m.hidden && m.alpha > 0) { triggerSkip(m, r); return; } }
            }
        }
    }
}

static void analyzeTouchView(UIView *v, CGPoint pt)
{
    if (!v) return;
    if ([v isDescendantOfView:[AdInspectorPanel shared]] || [NSStringFromClass([v.window class]) isEqualToString:@"AdInspectorWindow"] || (v.tag >= 1001 && v.tag <= 1030)) return;
    NSDate *n = [NSDate date];
    if (s_lastAnalysisTime && [n timeIntervalSinceDate:s_lastAnalysisTime] < kMinAnalysisInterval) return;
    s_lastAnalysisTime = n;
    UIView *av = findSkipLabelInView(v);
    if (!av) { showToast(@"⚠️ 未检测到跳过按钮"); return; }
    @try {
        UIWindow *aw = av.window;
        NSString *wc = aw ? NSStringFromClass([aw class]) : @"未知";
        NSMutableString *o = [NSMutableString string];
        [o appendFormat:@"\n══════ %@ ══════\n", [NSDateFormatter localizedStringFromDate:n dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle]];
        NSMutableArray *ca = [NSMutableArray array]; UIView *cur = av;
        while (cur && ![cur isKindOfClass:[UIWindow class]]) { [ca addObject:NSStringFromClass([cur class])]; cur = cur.superview; }
        [o appendString:@"📊 视图层级链:\n"]; cur = av; int d = 0;
        while (cur && d < 15) {
            NSString *ind = [@"" stringByPaddingToLength:d * 2 withString:@" " startingAtIndex:0];
            [o appendFormat:@"%@▸ %@", ind, NSStringFromClass([cur class])];
            if ([cur isKindOfClass:[UILabel class]]) { NSString *t = [(UILabel *)cur text] ?: [(UILabel *)cur attributedText].string; if (t.length) [o appendFormat:@" [\"%@\"]", t.length > 20 ? [[t substringToIndex:20] stringByAppendingString:@"..."] : t]; }
            if ([cur isKindOfClass:[UIButton class]]) { NSString *t = [(UIButton *)cur titleForState:UIControlStateNormal]; if (t.length) [o appendFormat:@" [\"%@\"]", t]; }
            [o appendFormat:@"\n%@  %@\n", ind, NSStringFromCGRect(cur.frame)];
            cur = cur.superview; d++;
        }
        [o appendFormat:@"\n🔍 诊断信息:\n  窗口:%@\n  目标:%@\n  frame:%@\n══════\n", wc, NSStringFromClass([av class]), NSStringFromCGRect(av.frame)];
        [[AdInspectorPanel shared] showLog:o]; saveToFile(o); highlightView(av);
        NSString *bt = nil;
        if ([av isKindOfClass:[UIButton class]]) bt = [(UIButton *)av titleForState:UIControlStateNormal];
        else if ([av isKindOfClass:[UILabel class]]) bt = [(UILabel *)av text] ?: [(UILabel *)av attributedText].string;
        if (bt.length == 0) bt = av.accessibilityLabel;
        if (bt.length == 0) { showToast(@"⚠️ 按钮无文字"); return; }
        NSMutableDictionary *r = [NSMutableDictionary dictionary];
        r[@"buttonClass"] = NSStringFromClass([av class]); r[@"buttonTextPattern"] = bt; r[@"hierarchyChain"] = ca;
        if (wc) r[@"windowClass"] = wc;
        saveRule(r);
    } @catch (NSException *e) { showToast(@"⚠️ 分析异常"); }
}

// ==================== AdInspectorWindow ====================
@implementation AdInspectorWindow
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) { self.windowLevel = CGFLOAT_MAX; self.backgroundColor = [UIColor clearColor]; self.hidden = NO; self.userInteractionEnabled = YES; s_floatWindow = self; }
    return self;
}
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self || (id)hit == (id)self.panel) return nil;
    while (hit && (id)hit != (id)self.panel) { if (hit.tag >= 1001 && hit.tag <= 1030) return hit; hit = hit.superview; }
    return nil;
}
- (void)setHidden:(BOOL)hidden { if (hidden && !self.isHidden) return; [super setHidden:hidden]; }
@end

// ==================== AdInspectorPanel ====================
@implementation AdInspectorPanel
+ (instancetype)shared { static AdInspectorPanel *i = nil; static dispatch_once_t t; dispatch_once(&t, ^{ i = [[AdInspectorPanel alloc] initWithFrame:CGRectMake(5, 180, [UIScreen mainScreen].bounds.size.width - 10, 360)]; }); return i; }
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.90]; self.layer.cornerRadius = 10; self.layer.borderWidth = 1.5; self.layer.borderColor = [UIColor cyanColor].CGColor; self.userInteractionEnabled = YES; self.clipsToBounds = NO; self.hidden = YES;
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(kbShow:) name:UIKeyboardWillShowNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(kbHide:) name:UIKeyboardWillHideNotification object:nil];
        UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, 180, 20)]; t.text = @"🔍 AdInspector"; t.textColor = [UIColor cyanColor]; t.font = [UIFont boldSystemFontOfSize:12]; t.tag = 1001; [self addSubview:t];
        UIButton *copyBtn = [UIButton buttonWithType:UIButtonTypeSystem]; copyBtn.frame = CGRectMake(self.bounds.size.width - 235, 3, 55, 30); [copyBtn setTitle:@"📋复制" forState:UIControlStateNormal]; [copyBtn setTitleColor:[UIColor colorWithRed:0.0 green:1.0 blue:0.5 alpha:1.0] forState:UIControlStateNormal]; copyBtn.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold]; copyBtn.tag = 1021; [copyBtn addTarget:self action:@selector(copyLog) forControlEvents:UIControlEventTouchUpInside]; [self addSubview:copyBtn];
        UILabel *l1 = [[UILabel alloc] initWithFrame:CGRectMake(12, 34, 80, 20)]; l1.text = @"目标视图类:"; l1.textColor = [UIColor whiteColor]; l1.font = [UIFont systemFontOfSize:11]; [self addSubview:l1];
        _targetViewField = [[UITextField alloc] initWithFrame:CGRectMake(95, 32, self.bounds.size.width - 110, 26)]; _targetViewField.borderStyle = UITextBorderStyleRoundedRect; _targetViewField.backgroundColor = [UIColor darkGrayColor]; _targetViewField.textColor = [UIColor whiteColor]; _targetViewField.font = [UIFont systemFontOfSize:12]; _targetViewField.placeholder = @"如 GDTDLRootView"; _targetViewField.tag = 1011; _targetViewField.delegate = self; [self addSubview:_targetViewField];
        UILabel *l2 = [[UILabel alloc] initWithFrame:CGRectMake(12, 64, 80, 20)]; l2.text = @"KVC路径:"; l2.textColor = [UIColor whiteColor]; l2.font = [UIFont systemFontOfSize:11]; [self addSubview:l2];
        _keyPathField = [[UITextField alloc] initWithFrame:CGRectMake(95, 62, self.bounds.size.width - 110, 26)]; _keyPathField.borderStyle = UITextBorderStyleRoundedRect; _keyPathField.backgroundColor = [UIColor darkGrayColor]; _keyPathField.textColor = [UIColor whiteColor]; _keyPathField.font = [UIFont systemFontOfSize:12]; _keyPathField.placeholder = @"如 self"; _keyPathField.tag = 1012; _keyPathField.delegate = self; [self addSubview:_keyPathField];
        UILabel *l3 = [[UILabel alloc] initWithFrame:CGRectMake(12, 94, 80, 20)]; l3.text = @"方法名:"; l3.textColor = [UIColor whiteColor]; l3.font = [UIFont systemFontOfSize:11]; [self addSubview:l3];
        _methodNameField = [[UITextField alloc] initWithFrame:CGRectMake(95, 92, self.bounds.size.width - 110, 26)]; _methodNameField.borderStyle = UITextBorderStyleRoundedRect; _methodNameField.backgroundColor = [UIColor darkGrayColor]; _methodNameField.textColor = [UIColor whiteColor]; _methodNameField.font = [UIFont systemFontOfSize:12]; _methodNameField.placeholder = @"如 GDTfunctionu0H2Y8:,3"; _methodNameField.tag = 1013; _methodNameField.delegate = self; [self addSubview:_methodNameField];
        UIButton *addBtn = [UIButton buttonWithType:UIButtonTypeSystem]; addBtn.frame = CGRectMake(12, 126, 60, 30); [addBtn setTitle:@"添加" forState:UIControlStateNormal]; [addBtn setTitleColor:[UIColor greenColor] forState:UIControlStateNormal]; addBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12]; addBtn.tag = 1014; [addBtn addTarget:self action:@selector(addCustomRuleFromFields) forControlEvents:UIControlEventTouchUpInside]; [self addSubview:addBtn];
        UIButton *testBtn = [UIButton buttonWithType:UIButtonTypeSystem]; testBtn.frame = CGRectMake(80, 126, 60, 30); [testBtn setTitle:@"测试" forState:UIControlStateNormal]; [testBtn setTitleColor:[UIColor yellowColor] forState:UIControlStateNormal]; testBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12]; testBtn.tag = 1015; [testBtn addTarget:self action:@selector(testCustomRules) forControlEvents:UIControlEventTouchUpInside]; [self addSubview:testBtn];
        UIButton *p1 = [UIButton buttonWithType:UIButtonTypeSystem]; p1.frame = CGRectMake(148, 126, 60, 30); [p1 setTitle:@"预设1" forState:UIControlStateNormal]; [p1 setTitleColor:[UIColor cyanColor] forState:UIControlStateNormal]; p1.titleLabel.font = [UIFont systemFontOfSize:11]; p1.tag = 1016; [p1 addTarget:self action:@selector(fillPreset1) forControlEvents:UIControlEventTouchUpInside]; [self addSubview:p1];
        UIButton *p2 = [UIButton buttonWithType:UIButtonTypeSystem]; p2.frame = CGRectMake(216, 126, 60, 30); [p2 setTitle:@"预设2" forState:UIControlStateNormal]; [p2 setTitleColor:[UIColor cyanColor] forState:UIControlStateNormal]; p2.titleLabel.font = [UIFont systemFontOfSize:11]; p2.tag = 1017; [p2 addTarget:self action:@selector(fillPreset2) forControlEvents:UIControlEventTouchUpInside]; [self addSubview:p2];
        UIButton *trkBtn = [UIButton buttonWithType:UIButtonTypeSystem]; trkBtn.frame = CGRectMake(12, 160, 90, 30); [trkBtn setTitle:@"▶开始追踪" forState:UIControlStateNormal]; [trkBtn setTitleColor:[UIColor colorWithRed:1.0 green:0.5 blue:0.0 alpha:1.0] forState:UIControlStateNormal]; trkBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11]; trkBtn.tag = 1018; [trkBtn addTarget:self action:@selector(toggleTracking:) forControlEvents:UIControlEventTouchUpInside]; [self addSubview:trkBtn];
        UIButton *deepBtn = [UIButton buttonWithType:UIButtonTypeSystem]; deepBtn.frame = CGRectMake(110, 160, 100, 30); [deepBtn setTitle:@"🔬深度追踪" forState:UIControlStateNormal]; [deepBtn setTitleColor:[UIColor colorWithRed:1.0 green:0.3 blue:0.7 alpha:1.0] forState:UIControlStateNormal]; deepBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11]; deepBtn.tag = 1022; [deepBtn addTarget:self action:@selector(toggleDeepTracking:) forControlEvents:UIControlEventTouchUpInside]; [self addSubview:deepBtn];
        UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem]; closeBtn.frame = CGRectMake(self.bounds.size.width - 45, 3, 40, 30); [closeBtn setTitle:@"✕" forState:UIControlStateNormal]; [closeBtn setTitleColor:[UIColor redColor] forState:UIControlStateNormal]; closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:20]; closeBtn.tag = 1002; [closeBtn addTarget:self action:@selector(hidePanel) forControlEvents:UIControlEventTouchUpInside]; [self addSubview:closeBtn];
        UIButton *clearBtn = [UIButton buttonWithType:UIButtonTypeSystem]; clearBtn.frame = CGRectMake(self.bounds.size.width - 135, 3, 45, 30); [clearBtn setTitle:@"清空" forState:UIControlStateNormal]; [clearBtn setTitleColor:[UIColor orangeColor] forState:UIControlStateNormal]; clearBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold]; clearBtn.tag = 1003; [clearBtn addTarget:self action:@selector(clearRulesTapped) forControlEvents:UIControlEventTouchUpInside]; [self addSubview:clearBtn];
        UIButton *viewBtn = [UIButton buttonWithType:UIButtonTypeSystem]; viewBtn.frame = CGRectMake(self.bounds.size.width - 90, 3, 45, 30); [viewBtn setTitle:@"查看" forState:UIControlStateNormal]; [viewBtn setTitleColor:[UIColor yellowColor] forState:UIControlStateNormal]; viewBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold]; viewBtn.tag = 1006; [viewBtn addTarget:self action:@selector(viewRulesTapped) forControlEvents:UIControlEventTouchUpInside]; [self addSubview:viewBtn];
        UIView *handle = [[UIView alloc] initWithFrame:CGRectMake(self.bounds.size.width / 2 - 15, 4, 30, 4)]; handle.backgroundColor = [UIColor colorWithWhite:0.4 alpha:0.6]; handle.layer.cornerRadius = 2; handle.tag = 1004; [self addSubview:handle];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)]; [self addGestureRecognizer:pan];
        CGFloat tvY = 196;
        _logTextView = [[UITextView alloc] initWithFrame:CGRectMake(5, tvY, self.bounds.size.width - 10, self.bounds.size.height - tvY - 5)]; _logTextView.backgroundColor = [UIColor clearColor]; _logTextView.textColor = [UIColor greenColor]; _logTextView.font = [UIFont fontWithName:@"Courier" size:10] ?: [UIFont systemFontOfSize:10]; _logTextView.editable = NO; _logTextView.selectable = YES; _logTextView.tag = 1005; _logTextView.textContainerInset = UIEdgeInsetsMake(2, 2, 2, 2); [self addSubview:_logTextView];
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
- (void)fillPreset1 { self.targetViewField.text = @"GDTDLRootView"; self.keyPathField.text = @"self"; self.methodNameField.text = @"GDTfunctionu0H2Y8:,3"; }
- (void)fillPreset2 { self.targetViewField.text = @"GDTDLBusinessManager"; self.keyPathField.text = @"self"; self.methodNameField.text = @"onDestroy"; }
- (void)copyLog { NSString *text = self.logBuffer; if (text.length == 0) { showToast(@"⚠️ 日志为空"); return; } [[UIPasteboard generalPasteboard] setString:text]; showToast(@"✅ 日志已复制"); }
- (void)addCustomRuleFromFields { NSString *tv = self.targetViewField.text, *kp = self.keyPathField.text, *mn = self.methodNameField.text; [self.targetViewField resignFirstResponder]; [self.keyPathField resignFirstResponder]; [self.methodNameField resignFirstResponder]; if (tv.length == 0 || kp.length == 0 || mn.length == 0) { showToast(@"⚠️ 请填写完整"); return; } saveCustomRule(@{@"targetView": tv, @"keyPath": kp, @"methodName": mn}); [self showLog:[NSString stringWithFormat:@"\n✅ 已添加: %@ → [%@] %@\n", tv, kp, mn]]; showToast(@"✅ 规则已添加"); }
- (void)testCustomRules { applyCustomRules(); }
- (void)clearRulesTapped { clearAllRules(); clearCustomRules(); [self showLog:@"\n🗑️ 已清空\n"]; showToast(@"🗑️ 已清空"); }
- (void)toggleTracking:(UIButton *)sender {
    if (s_isTracking) { stopTracking(); [sender setTitle:@"▶开始追踪" forState:UIControlStateNormal]; [sender setTitleColor:[UIColor colorWithRed:1.0 green:0.5 blue:0.0 alpha:1.0] forState:UIControlStateNormal]; if (s_trackedMethods.count > 0) { NSMutableString *o = [NSMutableString stringWithFormat:@"\n📊 追踪结果 (%lu个):\n", (unsigned long)s_trackedMethods.count]; for (NSDictionary *e in s_trackedMethods) [o appendFormat:@"  +%.2fs → %@\n", [e[@"time"] doubleValue], e[@"method"]]; [self showLog:o]; } else { [self showLog:@"\n⚠️ 未捕获到方法调用\n"]; } }
    else { startTracking(); [sender setTitle:@"⏹停止追踪" forState:UIControlStateNormal]; [sender setTitleColor:[UIColor redColor] forState:UIControlStateNormal]; [self showLog:@"\n🔍 开始追踪...\n"]; }
}
- (void)toggleDeepTracking:(UIButton *)sender {
    if (s_isDeepTracking) { NSArray *methods = stopDeepTracking(); [sender setTitle:@"🔬深度追踪" forState:UIControlStateNormal]; [sender setTitleColor:[UIColor colorWithRed:1.0 green:0.3 blue:0.7 alpha:1.0] forState:UIControlStateNormal]; if (methods.count > 0) { NSMutableString *o = [NSMutableString stringWithFormat:@"\n🔬 深度追踪结果 (%lu个方法):\n", (unsigned long)methods.count]; for (NSDictionary *e in methods) [o appendFormat:@"  +%.3fs → %@\n", [e[@"time"] doubleValue], e[@"method"]]; [self showLog:o]; } else { [self showLog:@"\n⚠️ 未捕获到\n"]; } }
    else { startDeepTracking(); [sender setTitle:@"⏹停止深度" forState:UIControlStateNormal]; [sender setTitleColor:[UIColor redColor] forState:UIControlStateNormal]; [self showLog:@"\n🔬 深度追踪已开启\n"]; }
}
- (void)viewRulesTapped { NSUserDefaults *ud = [NSUserDefaults standardUserDefaults]; NSArray *ar = [ud arrayForKey:kRulesKey] ?: @[], *cr = [ud arrayForKey:kCustomRulesKey] ?: @[]; NSMutableString *o = [NSMutableString string]; [o appendFormat:@"\n📋 自动规则 (%lu条):\n", (unsigned long)ar.count]; for (NSInteger i = 0; i < ar.count; i++) { NSDictionary *r = ar[i]; [o appendFormat:@"  %ld: %@ \"%@\"\n", (long)i + 1, r[@"buttonClass"], r[@"buttonTextPattern"]]; } [o appendFormat:@"\n📋 自定义规则 (%lu条):\n", (unsigned long)cr.count]; for (NSInteger i = 0; i < cr.count; i++) { NSDictionary *r = cr[i]; [o appendFormat:@"  %ld: %@ → [%@] %@\n", (long)i + 1, r[@"targetView"], r[@"keyPath"], r[@"methodName"]]; } [self showLog:o]; }
- (void)forceShow { if (!s_floatWindow) { UIWindowScene *as = nil; for (UIScene *s in [UIApplication sharedApplication].connectedScenes) { if ([s isKindOfClass:[UIWindowScene class]] && s.activationState == UISceneActivationStateForegroundActive) { as = (UIWindowScene *)s; break; } } if (as) { s_floatWindow = [[AdInspectorWindow alloc] initWithFrame:as.coordinateSpace.bounds]; s_floatWindow.windowScene = as; [s_floatWindow addSubview:self]; self.frame = CGRectMake(5, 180, s_floatWindow.bounds.size.width - 10, 360); s_floatWindow.panel = self; s_floatWindow.hidden = NO; } } else { if (!self.superview) { [s_floatWindow addSubview:self]; self.frame = CGRectMake(5, 180, s_floatWindow.bounds.size.width - 10, 360); s_floatWindow.panel = self; } s_floatWindow.hidden = NO; s_floatWindow.alpha = 1.0; [s_floatWindow bringSubviewToFront:self]; } self.hidden = NO; self.alpha = 1.0; showToast(@"👆 面板已呼出"); [self viewRulesTapped]; }
- (void)showLog:(NSString *)log { dispatch_async(dispatch_get_main_queue(), ^{ [self.logBuffer appendString:log]; if (self.logBuffer.length > 8000) [self.logBuffer deleteCharactersInRange:NSMakeRange(0, self.logBuffer.length - 8000)]; self.logTextView.text = self.logBuffer; if (self.logTextView.text.length > 0) [self.logTextView scrollRangeToVisible:NSMakeRange(self.logTextView.text.length - 1, 1)]; }); }
@end
// ==================== 捕获跳过参数 ====================
%hook GDTDLRootView

- (void)GDTfunctionu0H2Y8:(NSInteger)arg1 {
    NSMutableString *log = [NSMutableString string];
    [log appendFormat:@"\n🎯 捕获到跳过参数!\n"];
    [log appendFormat:@"方法: GDTfunctionu0H2Y8:\n"];
    [log appendFormat:@"参数值: %ld\n", (long)arg1];
    [log appendFormat:@"参数类型: NSInteger\n"];
    [log appendString:@"💡 自定义规则填: GDTfunctionu0H2Y8:,参数值\n"];
    [log appendString:@"══════\n"];
    [[AdInspectorPanel shared] showLog:log];
    saveToFile(log);
    %orig;
}

%end
// ==================== Hook ====================
%hook UIGestureRecognizer
- (void)setState:(UIGestureRecognizerState)state {
    %orig;
    if (state == UIGestureRecognizerStateEnded) {
        UIView *view = self.view; if (!view) return;
        UIView *skipView = findSkipLabelInView(view);
        if (skipView) {
            NSString *callStack = getCallStackSymbols();
            NSMutableString *log = [NSMutableString string];
            [log appendFormat:@"\n🔔 手势触发! 手势:%@ View:%@\n📚 调用栈:\n%@\n", NSStringFromClass([self class]), NSStringFromClass([view class]), callStack];
            @try { id delegate = self.delegate; if (delegate) [log appendFormat:@"🎯 delegate: %@\n", NSStringFromClass([delegate class])]; } @catch (NSException *e) {}
            [log appendString:@"══════\n"]; [[AdInspectorPanel shared] showLog:log]; saveToFile(log);
        }
    }
}
%end

%hook UIApplication
- (void)sendEvent:(UIEvent *)e {
    %orig;
    if (e.type == UIEventTypeTouches) {
        NSSet *ts = [e allTouches];
        if (ts.count >= 2) {
            BOOL as = YES;
            for (UITouch *t in ts) { if (t.phase == UITouchPhaseEnded || t.phase == UITouchPhaseCancelled) { as = NO; break; } }
            if (as && !s_twoFingerStart) s_twoFingerStart = [NSDate date];
            if (s_twoFingerStart && [[NSDate date] timeIntervalSinceDate:s_twoFingerStart] >= kTwoFingerHoldDuration) {
                AdInspectorPanel *p = [AdInspectorPanel shared]; if (p.hidden) [p forceShow];
                s_twoFingerStart = nil; s_ignoreSingleTouchUntil = [NSDate dateWithTimeIntervalSinceNow:0.5];
            }
        } else { s_twoFingerStart = nil; }
        if (ts.count == 1) {
            UITouch *t = [ts anyObject];
            if (t.phase == UITouchPhaseEnded && t.view && !s_twoFingerStart) {
                if (!s_ignoreSingleTouchUntil || [[NSDate date] compare:s_ignoreSingleTouchUntil] != NSOrderedAscending) {
                    analyzeTouchView(t.view, [t locationInView:nil]);
                }
            }
        }
    }
}
%end

%hook UIControl
- (void)addTarget:(id)t action:(SEL)a forControlEvents:(UIControlEvents)e {
    NSLog(@"[AdInspector] 🔗 %@ → %@.%@ [%@]", NSStringFromClass([self class]), NSStringFromClass([t class]), NSStringFromSelector(a), getControlEventName(e));
    %orig;
}
%end

%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindowScene *as = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) { if ([s isKindOfClass:[UIWindowScene class]] && s.activationState == UISceneActivationStateForegroundActive) { as = (UIWindowScene *)s; break; } }
        if (as) {
            s_floatWindow = [[AdInspectorWindow alloc] initWithFrame:as.coordinateSpace.bounds]; s_floatWindow.windowScene = as;
            AdInspectorPanel *p = [AdInspectorPanel shared]; p.frame = CGRectMake(5, 180, s_floatWindow.bounds.size.width - 10, 360); p.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
            [s_floatWindow addSubview:p]; s_floatWindow.panel = p; s_floatWindow.hidden = NO;
        }
        hookAllMethodsOfClass(NSClassFromString(@"GDTDLBusinessManager"));
        showToast(@"🔍 已激活 | 双指呼面板");
        if (isFlexingAvailable()) raiseFlexingWindow();
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
            applyAllSavedRules();
            if (s_floatWindow && !s_isKeyboardVisible) s_floatWindow.hidden = NO;
            if (isFlexingAvailable()) raiseFlexingWindow();
        }];
    });
}
#pragma clang diagnostic pop
