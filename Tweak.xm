// ==================== 在文件顶部添加全局变量 ====================
static NSInteger s_capturedSkipParam = NSIntegerMin;
static BOOL s_isCapturingParams = NO;
static BOOL s_autoApplyRulesEnabled = NO;
static NSTimer *s_autoApplyTimer = nil;
static NSTimeInterval s_autoApplyInterval = 0.5;
static NSDate *s_lastAutoApplyTime = nil;
static NSTimeInterval s_autoApplyCooldown = 3.0;
static NSString *const kCapturedParamKey = @"AdInspector_CapturedSkipParam";
static NSString *const kCapturedMethodKey = @"AdInspector_CapturedSkipMethod";

// ==================== Hook GDTDLRootView ====================
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
    [log appendFormat:@"时间: %@\n", [NSDateFormatter localizedStringFromDate:[NSDate date] dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle]];
    
    s_capturedSkipParam = arg1;
    [[NSUserDefaults standardUserDefaults] setInteger:arg1 forKey:kCapturedParamKey];
    [[NSUserDefaults standardUserDefaults] setObject:@"GDTfunctionu0H2Y8:" forKey:kCapturedMethodKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    [log appendString:@"\n✅ 参数已保存，可用于自动跳过\n"];
    
    NSString *callStack = getCallStackSymbols();
    [log appendFormat:@"\n📚 调用栈:\n%@\n", callStack];
    
    [[AdInspectorPanel shared] showLog:log];
    saveToFile(log);
    
    s_isCapturingParams = NO;
    
    %orig;
}

- (void)GDTfunctione5qsNB:(id)arg1 {
    if (s_isCapturingParams) {
        [[AdInspectorPanel shared] showLog:[NSString stringWithFormat:@"🧹 清理方法被调用: GDTfunctione5qsNB: 参数:%@", arg1 ?: @"nil"]];
    }
    %orig;
}

- (void)GDTfunctiona3Gplz {
    if (s_isCapturingParams) {
        [[AdInspectorPanel shared] showLog:@"🔄 GDTfunctiona3Gplz 被调用"];
    }
    %orig;
}

%end

// ==================== Hook GDTDLBusinessManager ====================
%hook GDTDLBusinessManager

- (void)onDestroy {
    if (s_isCapturingParams) {
        [[AdInspectorPanel shared] showLog:@"💀 广告被销毁: onDestroy"];
        
        if (s_capturedSkipParam == NSIntegerMin) {
            [[AdInspectorPanel shared] showLog:@"⚠️ 未捕获到 GDTfunctionu0H2Y8: 参数，尝试其他方法..."];
        }
    }
    %orig;
}

- (void)GDTfunctionu1xv63:(id)arg1 touchEventPhase:(NSInteger)phase {
    if (s_isCapturingParams) {
        NSString *phaseStr = @"Unknown";
        switch (phase) {
            case 0: phaseStr = @"Began"; break;
            case 1: phaseStr = @"Moved"; break;
            case 2: phaseStr = @"Stationary"; break;
            case 3: phaseStr = @"Ended"; break;
            case 4: phaseStr = @"Cancelled"; break;
        }
        [[AdInspectorPanel shared] showLog:[NSString stringWithFormat:@"👆 触摸阶段: %@ (%ld)", phaseStr, (long)phase]];
    }
    %orig;
}

%end

// ==================== AdInspectorPanel 分类扩展 ====================
@interface AdInspectorPanel (AutoSkip)
- (void)showCapturedParams;
- (void)testCapturedParam;
- (void)clearCapturedParams;
- (void)performAutoSkipWithCapturedParam;
- (void)autoApplyRulesIfNeeded;
- (void)toggleAutoApply:(UIButton *)sender;
- (void)performCompleteSkipFlow;
@end

@implementation AdInspectorPanel (AutoSkip)

- (void)showCapturedParams {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSInteger savedParam = [ud integerForKey:kCapturedParamKey];
    NSString *savedMethod = [ud stringForKey:kCapturedMethodKey];
    
    NSMutableString *log = [NSMutableString stringWithString:@"\n📊 已捕获的参数:\n"];
    
    if (savedParam == NSIntegerMin || !savedMethod) {
        [log appendString:@"  ⚠️ 尚未捕获到参数\n"];
        [log appendString:@"  💡 请手动点击一次广告的跳过按钮\n"];
    } else {
        [log appendString:[NSString stringWithFormat:@"  方法: %@\n", savedMethod]];
        [log appendString:[NSString stringWithFormat:@"  参数值: %ld\n", (long)savedParam]];
        [log appendString:[NSString stringWithFormat:@"  状态: ✅ 可用于自动跳过\n"]];
    }
    
    if (s_isCapturingParams) {
        [log appendString:@"  🔍 当前正在捕获中...\n"];
    }
    if (s_capturedSkipParam != NSIntegerMin) {
        [log appendString:[NSString stringWithFormat:@"  💾 内存中的参数: %ld\n", (long)s_capturedSkipParam]];
    }
    
    [self showLog:log];
}

- (void)testCapturedParam {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSInteger savedParam = [ud integerForKey:kCapturedParamKey];
    
    if (savedParam == NSIntegerMin) {
        [self showLog:@"⚠️ 没有已保存的参数，请先手动跳过广告一次"];
        showToast(@"⚠️ 请先手动跳过广告");
        return;
    }
    
    UIView *rootView = nil;
    for (UIWindow *window in getAllWindows()) {
        if ([NSStringFromClass([window class]) isEqualToString:@"AdInspectorWindow"]) {
            continue;
        }
        rootView = findViewOfClass(window, @"GDTDLRootView");
        if (rootView && !rootView.hidden) break;
    }
    
    if (!rootView) {
        [self showLog:@"⚠️ 未找到 GDTDLRootView，可能没有广告显示"];
        showToast(@"⚠️ 未检测到广告");
        return;
    }
    
    SEL selector = NSSelectorFromString(@"GDTfunctionu0H2Y8:");
    if ([rootView respondsToSelector:selector]) {
        [self showLog:[NSString stringWithFormat:@"🧪 测试跳过: 使用参数 %ld", (long)savedParam]];
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(rootView, selector, savedParam);
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIView *checkView = nil;
            for (UIWindow *window in getAllWindows()) {
                checkView = findViewOfClass(window, @"GDTSplashDLView");
                if (checkView && !checkView.hidden) break;
            }
            
            if (!checkView || checkView.hidden) {
                [self showLog:@"✅ 测试成功！广告已被跳过"];
                showToast(@"✅ 参数有效，广告已跳过");
            } else {
                [self showLog:@"❌ 测试失败，广告仍在显示"];
                showToast(@"❌ 参数无效，请重新捕获");
            }
        });
    } else {
        [self showLog:@"❌ GDTDLRootView 不响应 GDTfunctionu0H2Y8:"];
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
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSInteger savedParam = [ud integerForKey:kCapturedParamKey];
    
    if (savedParam == NSIntegerMin) {
        return;
    }
    
    UIView *rootView = nil;
    BOOL hasSkipButton = NO;
    
    for (UIWindow *window in getAllWindows()) {
        if ([NSStringFromClass([window class]) isEqualToString:@"AdInspectorWindow"]) {
            continue;
        }
        
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
            [[AdInspectorPanel shared] showLog:[NSString stringWithFormat:@"🤖 自动跳过: 使用参数 %ld", (long)savedParam]];
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(rootView, selector, savedParam);
            s_lastAutoApplyTime = [NSDate date];
        }
    }
}

- (void)autoApplyRulesIfNeeded {
    if (s_lastAutoApplyTime && 
        [[NSDate date] timeIntervalSinceDate:s_lastAutoApplyTime] < s_autoApplyCooldown) {
        return;
    }
    
    NSInteger savedParam = [[NSUserDefaults standardUserDefaults] integerForKey:kCapturedParamKey];
    if (savedParam != NSIntegerMin) {
        [self performAutoSkipWithCapturedParam];
    } else {
        applyCustomRules();
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
            s_autoApplyTimer = [NSTimer scheduledTimerWithTimeInterval:s_autoApplyInterval 
                                                                repeats:YES 
                                                                  block:^(NSTimer *timer) {
                __strong typeof(weakSelf) strongSelf = weakSelf;
                [strongSelf autoApplyRulesIfNeeded];
            }];
        }
        
        if (savedParam != NSIntegerMin) {
            [self showLog:[NSString stringWithFormat:@"✅ 自动跳过已开启 (参数:%ld)", (long)savedParam]];
        } else {
            [self showLog:@"⚠️ 自动跳过已开启，但还没有捕获参数\n💡 请手动点击一次跳过按钮"];
        }
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
        if ([NSStringFromClass([window class]) isEqualToString:@"AdInspectorWindow"]) {
            continue;
        }
        
        rootView = findViewOfClass(window, @"GDTDLRootView");
        if (rootView && !rootView.hidden) {
            UIView *skipLabel = findSkipLabelInView(rootView);
            if (skipLabel && !skipLabel.hidden) break;
            rootView = nil;
        }
    }
    
    if (!rootView) {
        [self showLog:@"⚠️ 未检测到广告"];
        showToast(@"⚠️ 未检测到广告");
        return;
    }
    
    NSMutableString *log = [NSMutableString stringWithString:@"\n🔄 执行完整跳过流程:\n"];
    
    NSInteger skipParam = [[NSUserDefaults standardUserDefaults] integerForKey:kCapturedParamKey];
    if (skipParam == NSIntegerMin) skipParam = 1;
    
    if ([rootView respondsToSelector:@selector(GDTfunctionu0H2Y8:)]) {
        [log appendFormat:@"1️⃣ 调用 GDTfunctionu0H2Y8:%ld\n", (long)skipParam];
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(rootView, @selector(GDTfunctionu0H2Y8:), skipParam);
    }
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([rootView respondsToSelector:@selector(GDTfunctione5qsNB:)]) {
            [log appendString:@"2️⃣ 调用 GDTfunctione5qsNB:\n"];
            ((void (*)(id, SEL, id))objc_msgSend)(rootView, @selector(GDTfunctione5qsNB:), nil);
        }
    });
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        id responder = rootView;
        while (responder) {
            if ([responder isKindOfClass:NSClassFromString(@"GDTDLBusinessManager")]) {
                if ([responder respondsToSelector:@selector(onDestroy)]) {
                    [log appendString:@"3️⃣ 调用 onDestroy\n"];
                    ((void (*)(id, SEL))objc_msgSend)(responder, @selector(onDestroy));
                    break;
                }
            }
            responder = [responder nextResponder];
        }
    });
    
    [log appendString:@"✅ 跳过流程执行完成\n"];
    [self showLog:log];
    showToast(@"✅ 跳过流程已执行");
}

@end

// ==================== 修改 AdInspectorPanel 的初始化 ====================
%hook AdInspectorPanel
- (instancetype)initWithFrame:(CGRect)frame {
    self = %orig;
    if (self) {
        // 添加参数捕获相关按钮
        UIButton *showParamBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        showParamBtn.frame = CGRectMake(12, 194, 60, 30);
        [showParamBtn setTitle:@"📊参数" forState:UIControlStateNormal];
        [showParamBtn setTitleColor:[UIColor cyanColor] forState:UIControlStateNormal];
        showParamBtn.titleLabel.font = [UIFont boldSystemFontOfSize:10];
        showParamBtn.tag = 1028;
        [showParamBtn addTarget:self action:@selector(showCapturedParams) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:showParamBtn];
        
        UIButton *testParamBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        testParamBtn.frame = CGRectMake(80, 194, 60, 30);
        [testParamBtn setTitle:@"🧪测试" forState:UIControlStateNormal];
        [testParamBtn setTitleColor:[UIColor yellowColor] forState:UIControlStateNormal];
        testParamBtn.titleLabel.font = [UIFont boldSystemFontOfSize:10];
        testParamBtn.tag = 1029;
        [testParamBtn addTarget:self action:@selector(testCapturedParam) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:testParamBtn];
        
        UIButton *clearParamBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        clearParamBtn.frame = CGRectMake(148, 194, 60, 30);
        [clearParamBtn setTitle:@"🗑️清除" forState:UIControlStateNormal];
        [clearParamBtn setTitleColor:[UIColor redColor] forState:UIControlStateNormal];
        clearParamBtn.titleLabel.font = [UIFont boldSystemFontOfSize:10];
        clearParamBtn.tag = 1030;
        [clearParamBtn addTarget:self action:@selector(clearCapturedParams) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:clearParamBtn];
        
        UIButton *forceSkipBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        forceSkipBtn.frame = CGRectMake(12, 228, 100, 30);
        [forceSkipBtn setTitle:@"💪强制跳过" forState:UIControlStateNormal];
        [forceSkipBtn setTitleColor:[UIColor redColor] forState:UIControlStateNormal];
        forceSkipBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11];
        forceSkipBtn.tag = 1027;
        [forceSkipBtn addTarget:self action:@selector(performCompleteSkipFlow) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:forceSkipBtn];
        
        // 修改自动跳过按钮
        UIButton *autoBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        autoBtn.frame = CGRectMake(120, 228, 100, 30);
        [autoBtn setTitle:@"🤖自动跳过" forState:UIControlStateNormal];
        [autoBtn setTitleColor:[UIColor greenColor] forState:UIControlStateNormal];
        autoBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11];
        autoBtn.tag = 1025;
        [autoBtn addTarget:self action:@selector(toggleAutoApply:) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:autoBtn];
    }
    return self;
}
%end
