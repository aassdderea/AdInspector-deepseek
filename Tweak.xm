// ==================== 在文件顶部添加全局变量 ====================
static NSInteger s_capturedSkipParam = NSIntegerMin; // 捕获的跳过参数
static BOOL s_isCapturingParams = NO; // 是否正在捕获参数
static NSString *const kCapturedParamKey = @"AdInspector_CapturedSkipParam";
static NSString *const kCapturedMethodKey = @"AdInspector_CapturedSkipMethod";

// ==================== Hook 关键方法来捕获参数 ====================

// Hook 1: 捕获触摸事件开始
%hook GDTDLRootView
- (void)GDTfunctionm80Ge8:(id)arg1 beganWithTouches:(id)arg2 andEvent:(id)arg3 {
    s_isCapturingParams = YES; // 开始捕获
    [[AdInspectorPanel shared] showLog:@"🔍 开始捕获跳过参数..."];
    %orig;
}

// Hook 2: 捕获触摸事件结束
- (void)GDTfunctionm80Ge8:(id)arg1 endedWithTouches:(id)arg2 andEvent:(id)arg3 {
    [[AdInspectorPanel shared] showLog:@"👆 触摸事件结束"];
    %orig;
}

// Hook 3: 捕获手势触发方法
- (void)GDTfunctiont2vpjZ:(id)arg1 event:(id)arg2 {
    [[AdInspectorPanel shared] showLog:[NSString stringWithFormat:@"🖐 手势触发: %@", NSStringFromSelector(_cmd)]];
    %orig;
}

// Hook 4: 最重要的 - 捕获跳过方法及其参数
- (void)GDTfunctionu0H2Y8:(NSInteger)arg1 {
    NSMutableString *log = [NSMutableString string];
    [log appendFormat:@"\n🎯🎯🎯 捕获到跳过方法调用! 🎯🎯🎯\n"];
    [log appendFormat:@"方法: GDTfunctionu0H2Y8:\n"];
    [log appendFormat:@"参数值: %ld\n", (long)arg1];
    [log appendFormat:@"参数类型: NSInteger\n"];
    [log appendFormat:@"时间: %@\n", [NSDateFormatter localizedStringFromDate:[NSDate date] dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle]];
    
    // 保存捕获的参数
    s_capturedSkipParam = arg1;
    [[NSUserDefaults standardUserDefaults] setInteger:arg1 forKey:kCapturedParamKey];
    [[NSUserDefaults standardUserDefaults] setObject:@"GDTfunctionu0H2Y8:" forKey:kCapturedMethodKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    [log appendString:@"\n✅ 参数已保存，可用于自动跳过\n"];
    
    // 获取调用栈
    NSString *callStack = getCallStackSymbols();
    [log appendFormat:@"\n📚 调用栈:\n%@\n", callStack];
    
    [[AdInspectorPanel shared] showLog:log];
    saveToFile(log);
    
    s_isCapturingParams = NO; // 停止捕获
    
    // 调用原方法
    %orig;
}

// Hook 5: 捕获可能的清理方法
- (void)GDTfunctione5qsNB:(id)arg1 {
    if (s_isCapturingParams) {
        [[AdInspectorPanel shared] showLog:[NSString stringWithFormat:@"🧹 清理方法被调用: GDTfunctione5qsNB: 参数:%@", arg1 ?: @"nil"]];
    }
    %orig;
}

// Hook 6: 捕获其他可能的相关方法
- (void)GDTfunctiona3Gplz {
    if (s_isCapturingParams) {
        [[AdInspectorPanel shared] showLog:@"🔄 GDTfunctiona3Gplz 被调用"];
    }
    %orig;
}

- (void)GDTfunctionu0H2Y8:(NSInteger)arg1 {
    // 重复 Hook 是为了确保能捕获到，有些 SDK 可能用不同的方法签名
    if (s_isCapturingParams && s_capturedSkipParam == NSIntegerMin) {
        [self GDTfunctionu0H2Y8:arg1]; // 调用上面的处理逻辑
    } else {
        %orig;
    }
}
%end

// Hook 7: 捕获 BusinessManager 的相关方法
%hook GDTDLBusinessManager
- (void)onDestroy {
    if (s_isCapturingParams) {
        [[AdInspectorPanel shared] showLog:@"💀 广告被销毁: onDestroy"];
        
        // 如果还没有捕获到参数，说明可能不是通过 GDTfunctionu0H2Y8: 跳过的
        if (s_capturedSkipParam == NSIntegerMin) {
            [[AdInspectorPanel shared] showLog:@"⚠️ 未捕获到 GDTfunctionu0H2Y8: 参数，尝试其他方法..."];
        }
    }
    %orig;
}

// 触摸事件相关方法
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

// ==================== 修改 AdInspectorPanel ====================

%new
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
    
    // 同时显示当前捕获状态
    if (s_isCapturingParams) {
        [log appendString:@"  🔍 当前正在捕获中...\n"];
    }
    if (s_capturedSkipParam != NSIntegerMin) {
        [log appendString:[NSString stringWithFormat:@"  💾 内存中的参数: %ld\n", (long)s_capturedSkipParam]];
    }
    
    [self showLog:log];
}

%new
- (void)testCapturedParam {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSInteger savedParam = [ud integerForKey:kCapturedParamKey];
    
    if (savedParam == NSIntegerMin) {
        [self showLog:@"⚠️ 没有已保存的参数，请先手动跳过广告一次"];
        showToast(@"⚠️ 请先手动跳过广告");
        return;
    }
    
    // 查找 GDTDLRootView
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
    
    // 使用捕获的参数执行跳过
    SEL selector = NSSelectorFromString(@"GDTfunctionu0H2Y8:");
    if ([rootView respondsToSelector:selector]) {
        [self showLog:[NSString stringWithFormat:@"🧪 测试跳过: 使用参数 %ld", (long)savedParam]];
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(rootView, selector, savedParam);
        
        // 检查是否成功
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

%new
- (void)clearCapturedParams {
    s_capturedSkipParam = NSIntegerMin;
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kCapturedParamKey];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kCapturedMethodKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self showLog:@"🗑️ 已清除捕获的参数"];
    showToast(@"🗑️ 参数已清除");
}

// ==================== 增强的自动跳过逻辑 ====================
%new
- (void)performAutoSkipWithCapturedParam {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSInteger savedParam = [ud integerForKey:kCapturedParamKey];
    
    if (savedParam == NSIntegerMin) {
        // 没有捕获到参数，不执行跳过
        return;
    }
    
    // 检查是否有广告
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

// ==================== 在面板初始化中添加新按钮 ====================
// 在 initWithFrame 方法中添加以下按钮：

// 查看捕获参数按钮
UIButton *showParamBtn = [UIButton buttonWithType:UIButtonTypeSystem];
showParamBtn.frame = CGRectMake(12, 194, 60, 30);
[showParamBtn setTitle:@"📊参数" forState:UIControlStateNormal];
[showParamBtn setTitleColor:[UIColor cyanColor] forState:UIControlStateNormal];
showParamBtn.titleLabel.font = [UIFont boldSystemFontOfSize:10];
showParamBtn.tag = 1028;
[showParamBtn addTarget:self action:@selector(showCapturedParams) forControlEvents:UIControlEventTouchUpInside];
[self addSubview:showParamBtn];

// 测试参数按钮
UIButton *testParamBtn = [UIButton buttonWithType:UIButtonTypeSystem];
testParamBtn.frame = CGRectMake(80, 194, 60, 30);
[testParamBtn setTitle:@"🧪测试" forState:UIControlStateNormal];
[testParamBtn setTitleColor:[UIColor yellowColor] forState:UIControlStateNormal];
testParamBtn.titleLabel.font = [UIFont boldSystemFontOfSize:10];
testParamBtn.tag = 1029;
[testParamBtn addTarget:self action:@selector(testCapturedParam) forControlEvents:UIControlEventTouchUpInside];
[self addSubview:testParamBtn];

// 清除参数按钮
UIButton *clearParamBtn = [UIButton buttonWithType:UIButtonTypeSystem];
clearParamBtn.frame = CGRectMake(148, 194, 60, 30);
[clearParamBtn setTitle:@"🗑️清除" forState:UIControlStateNormal];
[clearParamBtn setTitleColor:[UIColor redColor] forState:UIControlStateNormal];
clearParamBtn.titleLabel.font = [UIFont boldSystemFontOfSize:10];
clearParamBtn.tag = 1030;
[clearParamBtn addTarget:self action:@selector(clearCapturedParams) forControlEvents:UIControlEventTouchUpInside];
[self addSubview:clearParamBtn];

// ==================== 修改自动执行定时器 ====================
- (void)autoApplyRulesIfNeeded {
    if (s_lastAutoApplyTime && 
        [[NSDate date] timeIntervalSinceDate:s_lastAutoApplyTime] < s_autoApplyCooldown) {
        return;
    }
    
    // 优先使用捕获的参数进行跳过
    NSInteger savedParam = [[NSUserDefaults standardUserDefaults] integerForKey:kCapturedParamKey];
    if (savedParam != NSIntegerMin) {
        [self performAutoSkipWithCapturedParam];
    } else {
        // 如果没有捕获参数，使用自定义规则
        applyCustomRules();
    }
}

// ==================== 更新自动执行按钮逻辑 ====================
%new
- (void)toggleAutoApply:(UIButton *)sender {
    s_autoApplyRulesEnabled = !s_autoApplyRulesEnabled;
    
    if (s_autoApplyRulesEnabled) {
        // 检查是否有捕获的参数
        NSInteger savedParam = [[NSUserDefaults standardUserDefaults] integerForKey:kCapturedParamKey];
        
        [sender setTitle:@"🤖自动跳过" forState:UIControlStateNormal];
        [sender setTitleColor:[UIColor greenColor] forState:UIControlStateNormal];
        
        if (!s_autoApplyTimer) {
            s_autoApplyTimer = [NSTimer scheduledTimerWithTimeInterval:s_autoApplyInterval 
                                                                repeats:YES 
                                                                  block:^(NSTimer *timer) {
                [self autoApplyRulesIfNeeded];
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
