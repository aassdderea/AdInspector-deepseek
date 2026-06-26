#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ================= 安全的手势 Target-Action 解析 =================
static NSArray<NSString *> *extractGestureActions(UIGestureRecognizer *gr) {
    NSMutableArray *results = [NSMutableArray array];
    @try {
        NSArray *targets = [gr valueForKey:@"_targets"];
        for (id targetInfo in targets) {
            id target = [targetInfo valueForKey:@"_target"];
            id actionObj = [targetInfo valueForKey:@"_action"];
            
            SEL action = NULL;
            if ([actionObj isKindOfClass:[NSValue class]]) {
                action = (SEL)[(NSValue *)actionObj pointerValue];
            } else if ([actionObj isKindOfClass:[NSString class]]) {
                action = NSSelectorFromString((NSString *)actionObj);
            }
            
            if (target && action) {
                [results addObject:[NSString stringWithFormat:@"[Gesture:%@] %@ -> %@",
                                    NSStringFromClass([gr class]),
                                    target,
                                    NSStringFromSelector(action)]];
            }
        }
    } @catch (NSException *e) {
        [results addObject:[NSString stringWithFormat:@"[Gesture:%@] (解析异常)", NSStringFromClass([gr class])]];
    }
    return results;
}

// ================= 顶层 Toast 单例 =================
static UIWindow *g_toastWindow = nil;
static UILabel *g_toastLabel = nil;
static dispatch_block_t g_hideBlock = nil;

static void showTopLevelToast(NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (!g_toastWindow) {
                g_toastWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
                g_toastWindow.windowLevel = UIWindowLevelAlert + 999.f;
                g_toastWindow.backgroundColor = [UIColor clearColor];
                g_toastWindow.userInteractionEnabled = NO;
                
                g_toastLabel = [[UILabel alloc] init];
                g_toastLabel.numberOfLines = 0;
                g_toastLabel.font = [UIFont systemFontOfSize:14];
                g_toastLabel.textColor = [UIColor whiteColor];
                g_toastLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
                g_toastLabel.layer.cornerRadius = 12;
                g_toastLabel.clipsToBounds = YES;
                g_toastLabel.textAlignment = NSTextAlignmentCenter;
                [g_toastWindow addSubview:g_toastLabel];
            }
            
            CGFloat maxWidth = g_toastWindow.bounds.size.width - 40;
            CGRect textRect = [message boundingRectWithSize:CGSizeMake(maxWidth, CGFLOAT_MAX)
                                                    options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                                 attributes:@{NSFontAttributeName: g_toastLabel.font}
                                                    context:nil];
            g_toastLabel.frame = CGRectMake(0, 0, textRect.size.width + 30, textRect.size.height + 20);
            g_toastLabel.center = CGPointMake(g_toastWindow.center.x, g_toastWindow.bounds.size.height - 150);
            g_toastLabel.text = message;
            g_toastWindow.hidden = NO;
            
            if (g_hideBlock) {
                dispatch_block_cancel(g_hideBlock);
                g_hideBlock = nil;
            }
            g_hideBlock = dispatch_block_create(0, ^{
                g_toastWindow.hidden = YES;
                g_hideBlock = nil;
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), g_hideBlock);
        } @catch (NSException *e) {
            NSLog(@"[AdInspector] Toast异常: %@", e);
        }
    });
}

// ================= 核心诊断逻辑 =================
static void inspectViewAtPoint(CGPoint point) {
    UIWindow *keyWindow = nil;
    for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *window in scene.windows) {
                if (window.isKeyWindow) { keyWindow = window; break; }
            }
        }
    }
    
    UIView *hitView = [keyWindow hitTest:point withEvent:nil];
    if (!hitView) {
        showTopLevelToast(@"❌ 未命中视图，请对准按钮重试");
        return;
    }
    
    // 1. Hierarchy Chain
    NSMutableArray *chain = [NSMutableArray array];
    UIView *current = hitView;
    while (current) {
        [chain addObject:[NSString stringWithFormat:@"%@ (%@)",
                          NSStringFromClass([current class]),
                          current.accessibilityIdentifier ?: @"nil"]];
        current = current.superview;
    }
    
    // 2. Target-Actions
    NSMutableArray *actions = [NSMutableArray array];
    if ([hitView isKindOfClass:[UIControl class]]) {
        UIControl *control = (UIControl *)hitView;
        for (id target in control.allTargets) {
            NSArray *targetActions = [control actionsForTarget:target forControlEvent:UIControlEventAllEvents];
            for (NSString *action in targetActions) {
                [actions addObject:[NSString stringWithFormat:@"[Control] %@ -> %@", target, action]];
            }
        }
    }
    for (UIGestureRecognizer *gr in hitView.gestureRecognizers) {
        [actions addObjectsFromArray:extractGestureActions(gr)];
    }
    
    // 3. Extra Info
    NSDictionary *extraInfo = @{
        @"frame": NSStringFromCGRect(hitView.frame),
        @"windowFrame": NSStringFromCGRect([hitView convertRect:hitView.bounds toView:nil]),
        @"isHidden": @(hitView.isHidden),
        @"alpha": @(hitView.alpha),
        @"userInteractionEnabled": @(hitView.userInteractionEnabled)
    };
    
    // 4. 序列化保存
    NSDictionary *result = @{@"hierarchyChain": chain, @"targetActions": actions, @"extraInfo": extraInfo};
    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:&error];
    
    if (jsonData) {
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"ad_inspect_result.json"];
        NSString *jsonStr = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        BOOL ok = [jsonStr writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error];
        showTopLevelToast(ok ? [NSString stringWithFormat:@"✅ 诊断成功\n路径: %@", path]
                             : [NSString stringWithFormat:@"⚠️ 写入失败: %@", error.localizedDescription]);
    } else {
        showTopLevelToast([NSString stringWithFormat:@"❌ JSON序列化失败: %@", error.localizedDescription]);
    }
}

// ================= 触发器状态机 =================
static BOOL g_isThreeFingerHolding = NO;
static CGPoint g_trackedPoint = CGPointZero;
static dispatch_block_t g_inspectBlock = nil;

%hook UIApplication
- (void)sendEvent:(UIEvent *)event {
    %orig;
    if (event.type != UIEventTypeTouches) return;
    
    NSSet *touches = [event allTouches];
    BOOL isThreeFingers = (touches.count == 3);
    
    if (isThreeFingers) {
        // 计算三指中心点，更符合指向直觉
        CGPoint centerPoint = CGPointZero;
        NSInteger validCount = 0;
        for (UITouch *touch in touches) {
            CGPoint p = [touch locationInView:touch.window];
            centerPoint.x += p.x;
            centerPoint.y += p.y;
            validCount++;
        }
        if (validCount > 0) {
            centerPoint.x /= validCount;
            centerPoint.y /= validCount;
        }
        
        UITouch *anyTouch = touches.anyObject;
        if (anyTouch.phase == UITouchPhaseBegan && !g_isThreeFingerHolding) {
            g_isThreeFingerHolding = YES;
            g_trackedPoint = centerPoint;
            
            g_inspectBlock = dispatch_block_create(0, ^{
                inspectViewAtPoint(g_trackedPoint);
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    @try {
                        UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
                        [fb prepare]; [fb impactOccurred];
                    } @catch (NSException *e) {}
                });
                
                g_isThreeFingerHolding = NO;
                g_inspectBlock = nil;
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), g_inspectBlock);
        } else if (g_isThreeFingerHolding) {
            // 持续更新为中心点坐标
            g_trackedPoint = centerPoint;
        }
    } else {
        if (g_isThreeFingerHolding && g_inspectBlock) {
            dispatch_block_cancel(g_inspectBlock);
            g_inspectBlock = nil;
            g_isThreeFingerHolding = NO;
        }
    }
}
%end

%ctor {
    NSLog(@"[AdInspector] ✅ v5.0 Final 加载成功！三指静止长按0.8s触发。");
}