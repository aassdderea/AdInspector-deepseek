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
        NSString *tvc = r[@"targetView"];
        NSString *kp = r[@"keyPath"];
        NSString *mn = r[@"methodName"];
        if (!tvc || !kp || !mn)
        {
            continue;
        }

        // 特殊规则：AdInspector_SkipSequence 执行完整跳过序列
        if ([mn isEqualToString:@"AdInspector_SkipSequence"])
        {
            // 先找 GDTDLRootView 实例
            id rootView = nil;
            for (UIWindow *w in getAllWindows())
            {
                if ([NSStringFromClass([w class]) isEqualToString:@"AdInspectorWindow"]) continue;
                UIView *skipView = findSkipLabelInView(w);
                if (!skipView) continue;
                UIView *parent = skipView.superview;
                while (parent && ![parent isKindOfClass:[UIWindow class]])
                {
                    if ([NSStringFromClass([parent class]) isEqualToString:@"GDTDLRootView"])
                    {
                        rootView = parent;
                        break;
                    }
                    parent = parent.superview;
                }
                if (!rootView)
                {
                    for (UIGestureRecognizer *gr in skipView.gestureRecognizers)
                    {
                        id d = gr.delegate;
                        if ([NSStringFromClass([d class]) isEqualToString:@"GDTDLRootView"])
                        {
                            rootView = d;
                            break;
                        }
                    }
                }
                if (rootView) break;
            }

            // 找 GDTDLBusinessManager 实例
            id bm = nil;
            if (rootView && [rootView respondsToSelector:@selector(delegate)])
            {
                bm = ((id (*)(id, SEL))objc_msgSend)(rootView, @selector(delegate));
            }
            if (!bm)
            {
                for (UIWindow *w in getAllWindows())
                {
                    if ([NSStringFromClass([w class]) isEqualToString:@"AdInspectorWindow"]) continue;
                    NSMutableArray *views = [NSMutableArray arrayWithArray:w.subviews];
                    while (views.count > 0)
                    {
                        UIView *v = [views lastObject];
                        [views removeLastObject];
                        id responder = v.nextResponder;
                        while (responder)
                        {
                            if ([NSStringFromClass([responder class]) isEqualToString:@"GDTDLBusinessManager"])
                            {
                                bm = responder;
                                break;
                            }
                            responder = [responder nextResponder];
                        }
                        if (bm) break;
                        [views addObjectsFromArray:v.subviews];
                    }
                    if (bm) break;
                }
            }

            if (!rootView && !bm)
            {
                continue;
            }

            // 按顺序执行跳过序列
            // 第1步：GDTfunctions9hRIc: (在 bm 上，单参)
            if (bm && [bm respondsToSelector:NSSelectorFromString(@"GDTfunctions9hRIc:")])
            {
                ((void (*)(id, SEL, id))objc_msgSend)(bm, NSSelectorFromString(@"GDTfunctions9hRIc:"), nil);
            }
            // 第2步：GDTfunctione5qsNB: (在 rootView 上，单参)
            if (rootView && [rootView respondsToSelector:NSSelectorFromString(@"GDTfunctione5qsNB:")])
            {
                ((void (*)(id, SEL, id))objc_msgSend)(rootView, NSSelectorFromString(@"GDTfunctione5qsNB:"), nil);
            }
            // 第3步：GDTfunctiont7uUIH (在 rootView 上，无参)
            if (rootView && [rootView respondsToSelector:NSSelectorFromString(@"GDTfunctiont7uUIH")])
            {
                ((void (*)(id, SEL))objc_msgSend)(rootView, NSSelectorFromString(@"GDTfunctiont7uUIH"));
            }
            // 第4步：GDTfunctiona3Gplz (在 rootView 上，无参)
            if (rootView && [rootView respondsToSelector:NSSelectorFromString(@"GDTfunctiona3Gplz")])
            {
                ((void (*)(id, SEL))objc_msgSend)(rootView, NSSelectorFromString(@"GDTfunctiona3Gplz"));
            }
            // 第5步：onDestroy (在 bm 上，无参)
            if (bm && [bm respondsToSelector:NSSelectorFromString(@"onDestroy")])
            {
                ((void (*)(id, SEL))objc_msgSend)(bm, NSSelectorFromString(@"onDestroy"));
            }

            [[AdInspectorPanel shared] showLog:@"\n🚀 已执行完整跳过序列\n"];
            return; // 执行一次就够了
        }

        // 以下是原有单方法逻辑（保持不变）
        BOOL found = NO;
        id tg = nil;

        if ([tvc isEqualToString:@"GDTDLRootView"])
        {
            for (UIWindow *w in getAllWindows())
            {
                if ([NSStringFromClass([w class]) isEqualToString:@"AdInspectorWindow"]) continue;
                UIView *skipView = findSkipLabelInView(w);
                if (!skipView) continue;
                UIView *parent = skipView.superview;
                while (parent && ![parent isKindOfClass:[UIWindow class]])
                {
                    if ([NSStringFromClass([parent class]) isEqualToString:@"GDTDLRootView"])
                    {
                        tg = parent;
                        found = YES;
                        break;
                    }
                    parent = parent.superview;
                }
                if (!tg)
                {
                    for (UIGestureRecognizer *gr in skipView.gestureRecognizers)
                    {
                        id d = gr.delegate;
                        if ([NSStringFromClass([d class]) isEqualToString:@"GDTDLRootView"])
                        {
                            tg = d;
                            found = YES;
                            break;
                        }
                    }
                }
                if (tg) break;
            }
        }

        if (!found && [tvc isEqualToString:@"GDTDLBusinessManager"])
        {
            // 先从 rootView.delegate 获取
            id rootView = nil;
            for (UIWindow *w in getAllWindows())
            {
                if ([NSStringFromClass([w class]) isEqualToString:@"AdInspectorWindow"]) continue;
                UIView *skipView = findSkipLabelInView(w);
                if (!skipView) continue;
                UIView *parent = skipView.superview;
                while (parent && ![parent isKindOfClass:[UIWindow class]])
                {
                    if ([NSStringFromClass([parent class]) isEqualToString:@"GDTDLRootView"])
                    {
                        rootView = parent;
                        break;
                    }
                    parent = parent.superview;
                }
                if (rootView) break;
            }
            if (rootView && [rootView respondsToSelector:@selector(delegate)])
            {
                id d = ((id (*)(id, SEL))objc_msgSend)(rootView, @selector(delegate));
                if ([NSStringFromClass([d class]) isEqualToString:@"GDTDLBusinessManager"])
                {
                    tg = d;
                    found = YES;
                }
            }
        }

        if (!found)
        {
            for (UIWindow *w in getAllWindows())
            {
                if ([NSStringFromClass([w class]) isEqualToString:@"AdInspectorWindow"]) continue;
                UIView *tv = findViewOfClass(w, tvc);
                if (tv) { tg = getObjectByKeyPath(tv, kp); if (tg) { found = YES; break; } }
            }
        }

        if (!found)
        {
            Class targetClass = NSClassFromString(tvc);
            if (targetClass)
            {
                SEL ss[] = {@selector(sharedInstance), @selector(sharedManager), @selector(shared), @selector(defaultManager), @selector(instance)};
                for (int i = 0; i < 5 && !tg; i++)
                {
                    if ([targetClass respondsToSelector:ss[i]])
                        tg = ((id (*)(id, SEL))objc_msgSend)(targetClass, ss[i]);
                }
                if (!tg)
                {
                    id ad = [UIApplication sharedApplication].delegate;
                    @try { tg = [ad valueForKey:tvc]; } @catch (NSException *e) {}
                }
            }
        }

        if ([kp isEqualToString:@"self"]) { /* already tg */ }
        else if (tg) { tg = getObjectByKeyPath(tg, kp); }

        if (!tg || ![tg respondsToSelector:NSSelectorFromString(mn)]) continue;

        NSMethodSignature *sig = [tg methodSignatureForSelector:NSSelectorFromString(mn)];
        NSUInteger ac = sig.numberOfArguments;
        if (ac <= 2)
            ((void (*)(id, SEL))objc_msgSend)(tg, NSSelectorFromString(mn));
        else if (ac == 3)
        {
            const char *t = [sig getArgumentTypeAtIndex:2];
            if (strcmp(t, "B") == 0) ((void (*)(id, SEL, BOOL))objc_msgSend)(tg, NSSelectorFromString(mn), YES);
            else ((void (*)(id, SEL, id))objc_msgSend)(tg, NSSelectorFromString(mn), nil);
        }
        else
        {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:tg]; [inv setSelector:NSSelectorFromString(mn)];
            id nilArg = nil;
            for (NSUInteger i = 2; i < ac; i++) [inv setArgument:&nilArg atIndex:i];
            [inv invoke];
        }
    }
}
