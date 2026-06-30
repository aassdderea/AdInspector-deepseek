#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <mach/mach_time.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <Accessibility/Accessibility.h>
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-function"

// ==================== 全局配置 ====================
static NSArray *s_tapConfigs = nil;
static BOOL s_isExecuting = NO;

@class TapControllerPanel;

@interface TapControllerPanel : UIView <UITextFieldDelegate>
@property (nonatomic, strong) UITextView *logTextView;
@property (nonatomic, strong) NSMutableString *logBuffer;
@property (nonatomic, strong) UITextField *configField;
+ (instancetype)shared;
- (void)showLog:(NSString *)log;
- (void)forceShow;
- (void)hidePanel;
- (void)executeTaps;
- (void)clearLog;
@end

@interface TapControllerWindow : UIWindow
@property (nonatomic, weak) TapControllerPanel *panel;
@end
static TapControllerWindow *s_tapWindow = nil;

static void showToast(NSString *m) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *hw = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]] && s.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *w in [(UIWindowScene *)s windows]) { if (w.isKeyWindow) { hw = w; break; } }
            }
        }
        if (!hw) return;
        UIView *t = [[UIView alloc] init]; t.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85]; t.layer.cornerRadius = 12; t.tag = 9999;
        UILabel *l = [[UILabel alloc] init]; l.text = m; l.textColor = [UIColor whiteColor]; l.font = [UIFont boldSystemFontOfSize:14]; l.numberOfLines = 0; l.textAlignment = NSTextAlignmentCenter; [t addSubview:l];
        CGSize ms = CGSizeMake([UIScreen mainScreen].bounds.size.width - 60, CGFLOAT_MAX);
        CGRect tr = [m boundingRectWithSize:ms options:NSStringDrawingUsesLineFragmentOrigin attributes:@{NSFontAttributeName: l.font} context:nil];
        CGFloat w = tr.size.width + 30, h = tr.size.height + 16; l.frame = CGRectMake(15, 8, tr.size.width, tr.size.height);
        CGPoint c = CGPointMake(hw.bounds.size.width / 2, hw.bounds.size.height - 150);
        t.frame = CGRectMake(c.x - w / 2, c.y - h / 2, w, h); t.layer.zPosition = CGFLOAT_MAX;
        [hw addSubview:t];
        [UIView animateWithDuration:0.3 delay:1.5 options:UIViewAnimationOptionCurveEaseOut animations:^{ t.alpha = 0; } completion:^(BOOL f) { [t removeFromSuperview]; }];
    });
}

// ==================== 点击指示器 ====================
static void showTapIndicator(CGFloat x, CGFloat y) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *hw = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]] && s.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *w in [(UIWindowScene *)s windows]) { if (w.isKeyWindow) { hw = w; break; } }
            }
        }
        if (!hw) return;
        CGFloat r = 20;
        UIView *circle = [[UIView alloc] initWithFrame:CGRectMake(x - r, y - r, r * 2, r * 2)];
        circle.backgroundColor = [UIColor clearColor];
        circle.layer.cornerRadius = r;
        circle.layer.borderWidth = 3;
        circle.layer.borderColor = [UIColor redColor].CGColor;
        circle.tag = 9998;
        circle.layer.zPosition = CGFLOAT_MAX;
        circle.userInteractionEnabled = NO;
        [hw addSubview:circle];
        [UIView animateWithDuration:0.5 delay:0.3 options:UIViewAnimationOptionCurveEaseOut animations:^{
            circle.alpha = 0;
            circle.transform = CGAffineTransformMakeScale(1.5, 1.5);
        } completion:^(BOOL f) { [circle removeFromSuperview]; }];
    });
}

// ==================== Accessibility 触摸 ====================
static void simulateTap(CGFloat x, CGFloat y) {
    AXUIElementRef appRef = AXUIElementCreateApplication(getpid());
    AXUIElementRef element = NULL;
    AXError err = AXUIElementCopyElementAtPosition(appRef, x, y, &element);
    if (err == kAXErrorSuccess && element) {
        AXError tapErr = AXUIElementPerformAction(element, kAXPressAction);
        if (tapErr != kAXErrorSuccess) {
            tapErr = AXUIElementPerformAction(element, kAXTapAction);
        }
        if (tapErr == kAXErrorSuccess) {
            [[TapControllerPanel shared] showLog:[NSString stringWithFormat:@"🟢 AX (%.0f,%.0f) ✅\n", x, y]];
            showTapIndicator(x, y);
        } else {
            [[TapControllerPanel shared] showLog:[NSString stringWithFormat:@"⚠️ AX 失败 err=%d (%.0f,%.0f)\n", tapErr, x, y]];
        }
        CFRelease(element);
    } else {
        [[TapControllerPanel shared] showLog:[NSString stringWithFormat:@"⚠️ AX 无元素 err=%d (%.0f,%.0f)\n", err, x, y]];
    }
    if (appRef) CFRelease(appRef);
}

static void executeTapSequence(NSArray *configs, NSUInteger index) {
    if (index >= configs.count) { s_isExecuting = NO; showToast(@"✅ 全部完成"); [[TapControllerPanel shared] showLog:@"✅ 全部完成\n"]; return; }
    NSString *cfg = [configs[index] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSArray *parts = [cfg componentsSeparatedByString:@":"];
    if (parts.count < 2) { executeTapSequence(configs, index + 1); return; }
    CGFloat x = [parts[0] floatValue], y = [parts[1] floatValue], delay = parts.count >= 3 ? [parts[2] floatValue] : 0;
    if (delay > 0) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ simulateTap(x, y); executeTapSequence(configs, index + 1); }); }
    else { simulateTap(x, y); dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ executeTapSequence(configs, index + 1); }); }
}

// ==================== UI ====================
@implementation TapControllerWindow
- (instancetype)initWithFrame:(CGRect)frame { self=[super initWithFrame:frame]; if(self){self.windowLevel=CGFLOAT_MAX;self.backgroundColor=[UIColor clearColor];self.hidden=NO;self.userInteractionEnabled=YES;s_tapWindow=self;} return self; }
- (UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event { UIView*hit=[super hitTest:point withEvent:event]; if(hit==self||(id)hit==(id)self.panel)return nil; while(hit&&(id)hit!=(id)self.panel){if(hit.tag>=2001&&hit.tag<=2020)return hit;hit=hit.superview;} return nil; }
- (void)setHidden:(BOOL)hidden { if(hidden&&!self.isHidden)return; [super setHidden:hidden]; }
@end

@implementation TapControllerPanel
+ (instancetype)shared { static TapControllerPanel *i=nil; static dispatch_once_t t; dispatch_once(&t,^{i=[[TapControllerPanel alloc]initWithFrame:CGRectMake(5,180,[UIScreen mainScreen].bounds.size.width-10,300)];}); return i; }
- (instancetype)initWithFrame:(CGRect)frame { self=[super initWithFrame:frame]; if(self){
    self.backgroundColor=[[UIColor blackColor]colorWithAlphaComponent:0.90];self.layer.cornerRadius=10;self.layer.borderWidth=1.5;self.layer.borderColor=[UIColor systemGreenColor].CGColor;self.userInteractionEnabled=YES;self.clipsToBounds=NO;self.hidden=YES;
    UILabel *t=[[UILabel alloc]initWithFrame:CGRectMake(12,8,220,20)];t.text=@"🖐 Accessibility 触摸";t.textColor=[UIColor systemGreenColor];t.font=[UIFont boldSystemFontOfSize:12];t.tag=2001;[self addSubview:t];
    UILabel *l1=[[UILabel alloc]initWithFrame:CGRectMake(12,34,80,20)];l1.text=@"点击序列:";l1.textColor=[UIColor whiteColor];l1.font=[UIFont systemFontOfSize:11];[self addSubview:l1];
    _configField=[[UITextField alloc]initWithFrame:CGRectMake(95,32,self.bounds.size.width-110,26)];_configField.borderStyle=UITextBorderStyleRoundedRect;_configField.backgroundColor=[UIColor darkGrayColor];_configField.textColor=[UIColor whiteColor];_configField.font=[UIFont systemFontOfSize:12];_configField.placeholder=@"x:y:秒|x2:y2:秒|...";_configField.tag=2011;_configField.delegate=self;[self addSubview:_configField];
    UIButton *p1=[UIButton buttonWithType:UIButtonTypeSystem];p1.frame=CGRectMake(12,66,80,26);[p1 setTitle:@"预设:左上角" forState:UIControlStateNormal];[p1 setTitleColor:[UIColor cyanColor] forState:UIControlStateNormal];p1.titleLabel.font=[UIFont systemFontOfSize:10];p1.tag=2016;[p1 addTarget:self action:@selector(preset1) forControlEvents:UIControlEventTouchUpInside];[self addSubview:p1];
    UIButton *p2=[UIButton buttonWithType:UIButtonTypeSystem];p2.frame=CGRectMake(100,66,80,26);[p2 setTitle:@"预设:右下角" forState:UIControlStateNormal];[p2 setTitleColor:[UIColor cyanColor] forState:UIControlStateNormal];p2.titleLabel.font=[UIFont systemFontOfSize:10];p2.tag=2017;[p2 addTarget:self action:@selector(preset2) forControlEvents:UIControlEventTouchUpInside];[self addSubview:p2];
    UIButton *p3=[UIButton buttonWithType:UIButtonTypeSystem];p3.frame=CGRectMake(188,66,80,26);[p3 setTitle:@"预设:屏幕中心" forState:UIControlStateNormal];[p3 setTitleColor:[UIColor cyanColor] forState:UIControlStateNormal];p3.titleLabel.font=[UIFont systemFontOfSize:10];p3.tag=2018;[p3 addTarget:self action:@selector(preset3) forControlEvents:UIControlEventTouchUpInside];[self addSubview:p3];
    UIButton *execBtn=[UIButton buttonWithType:UIButtonTypeSystem];execBtn.frame=CGRectMake(12,100,100,36);[execBtn setTitle:@"⚡立即执行" forState:UIControlStateNormal];[execBtn setTitleColor:[UIColor systemGreenColor] forState:UIControlStateNormal];execBtn.titleLabel.font=[UIFont boldSystemFontOfSize:14];execBtn.tag=2014;[execBtn addTarget:self action:@selector(executeTaps) forControlEvents:UIControlEventTouchUpInside];[self addSubview:execBtn];
    UIButton *closeBtn=[UIButton buttonWithType:UIButtonTypeSystem];closeBtn.frame=CGRectMake(self.bounds.size.width-45,3,40,30);[closeBtn setTitle:@"✕" forState:UIControlStateNormal];[closeBtn setTitleColor:[UIColor redColor] forState:UIControlStateNormal];closeBtn.titleLabel.font=[UIFont boldSystemFontOfSize:20];closeBtn.tag=2002;[closeBtn addTarget:self action:@selector(hidePanel) forControlEvents:UIControlEventTouchUpInside];[self addSubview:closeBtn];
    UIButton *clearLogBtn=[UIButton buttonWithType:UIButtonTypeSystem];clearLogBtn.frame=CGRectMake(self.bounds.size.width-180,3,40,30);[clearLogBtn setTitle:@"清屏" forState:UIControlStateNormal];[clearLogBtn setTitleColor:[UIColor grayColor] forState:UIControlStateNormal];clearLogBtn.titleLabel.font=[UIFont systemFontOfSize:11];clearLogBtn.tag=2031;[clearLogBtn addTarget:self action:@selector(clearLog) forControlEvents:UIControlEventTouchUpInside];[self addSubview:clearLogBtn];
    UIView *handle=[[UIView alloc]initWithFrame:CGRectMake(self.bounds.size.width/2-15,4,30,4)];handle.backgroundColor=[UIColor colorWithWhite:0.4 alpha:0.6];handle.layer.cornerRadius=2;handle.tag=2004;[self addSubview:handle];UIPanGestureRecognizer *pan=[[UIPanGestureRecognizer alloc]initWithTarget:self action:@selector(handlePan:)];[self addGestureRecognizer:pan];
    CGFloat tvY=144;_logTextView=[[UITextView alloc]initWithFrame:CGRectMake(5,tvY,self.bounds.size.width-10,self.bounds.size.height-tvY-5)];_logTextView.backgroundColor=[UIColor clearColor];_logTextView.textColor=[UIColor greenColor];_logTextView.font=[UIFont fontWithName:@"Courier" size:10]?:[UIFont systemFontOfSize:10];_logTextView.editable=NO;_logTextView.selectable=YES;_logTextView.tag=2005;_logTextView.textContainerInset=UIEdgeInsetsMake(2,2,2,2);[self addSubview:_logTextView];_logBuffer=[NSMutableString string];
}return self;}
- (void)handlePan:(UIPanGestureRecognizer*)p{CGPoint t=[p translationInView:self];self.center=CGPointMake(self.center.x+t.x,self.center.y+t.y);[p setTranslation:CGPointZero inView:self];}
- (BOOL)textFieldShouldReturn:(UITextField*)tf{[tf resignFirstResponder];return YES;}
- (void)hidePanel{self.hidden=YES;}
- (void)clearLog{[self.logBuffer setString:@""];self.logTextView.text=@"";showToast(@"🗑️ 日志已清屏");}
- (void)preset1{self.configField.text=@"50:100:0";[self showLog:@"📌 预设: 左上角\n"];}
- (void)preset2{CGFloat w=[UIScreen mainScreen].bounds.size.width; CGFloat h=[UIScreen mainScreen].bounds.size.height; self.configField.text=[NSString stringWithFormat:@"%.0f:%.0f:0",w-30,h-50];[self showLog:@"📌 预设: 右下角\n"];}
- (void)preset3{CGFloat w=[UIScreen mainScreen].bounds.size.width; CGFloat h=[UIScreen mainScreen].bounds.size.height; self.configField.text=[NSString stringWithFormat:@"%.0f:%.0f:0",w/2,h/2];[self showLog:@"📌 预设: 屏幕中心\n"];}
- (void)executeTaps{[self.configField resignFirstResponder];NSString *raw=self.configField.text;if(!raw.length){showToast(@"⚠️ 请填写点击序列");return;} s_tapConfigs=[raw componentsSeparatedByString:@"|"]; if(s_tapConfigs.count==0){showToast(@"⚠️ 格式: x:y:秒|x2:y2:秒");return;} s_isExecuting=YES; [self showLog:[NSString stringWithFormat:@"\n🖐 开始 %lu 步\n",(unsigned long)s_tapConfigs.count]]; showToast([NSString stringWithFormat:@"🖐 开始 %lu 步",(unsigned long)s_tapConfigs.count]); executeTapSequence(s_tapConfigs,0);}
- (void)forceShow{if(!s_tapWindow){UIWindowScene *as=nil;for(UIScene *s in [UIApplication sharedApplication].connectedScenes){if([s isKindOfClass:[UIWindowScene class]]&&s.activationState==UISceneActivationStateForegroundActive){as=(UIWindowScene*)s;break;}}if(as){s_tapWindow=[[TapControllerWindow alloc]initWithFrame:as.coordinateSpace.bounds];s_tapWindow.windowScene=as;[s_tapWindow addSubview:self];self.frame=CGRectMake(5,180,s_tapWindow.bounds.size.width-10,300);s_tapWindow.panel=self;s_tapWindow.hidden=NO;}}else{if(!self.superview){[s_tapWindow addSubview:self];self.frame=CGRectMake(5,180,s_tapWindow.bounds.size.width-10,300);s_tapWindow.panel=self;}s_tapWindow.hidden=NO;s_tapWindow.alpha=1.0;[s_tapWindow bringSubviewToFront:self];}self.hidden=NO;self.alpha=1.0;showToast(@"👆 面板已呼出");}
- (void)showLog:(NSString*)log{dispatch_async(dispatch_get_main_queue(),^{[self.logBuffer appendString:log];if(self.logBuffer.length>5000)[self.logBuffer deleteCharactersInRange:NSMakeRange(0,self.logBuffer.length-5000)];self.logTextView.text=self.logBuffer;if(self.logTextView.text.length>0)[self.logTextView scrollRangeToVisible:NSMakeRange(self.logTextView.text.length-1,1)];});}
@end

// ==================== Hook ====================
static NSDate *s_twoFingerStart=nil;
static const NSTimeInterval kTwoFingerHoldDuration=0.5;

%hook UIApplication
- (void)sendEvent:(UIEvent *)e {
    %orig;
    if(e.type==UIEventTypeTouches){
        NSSet *ts=[e allTouches];
        if(ts.count>=2){
            BOOL as=YES;
            for(UITouch *t in ts){if(t.phase==UITouchPhaseEnded||t.phase==UITouchPhaseCancelled){as=NO;break;}}
            if(as&&!s_twoFingerStart)s_twoFingerStart=[NSDate date];
            if(s_twoFingerStart&&[[NSDate date]timeIntervalSinceDate:s_twoFingerStart]>=kTwoFingerHoldDuration){
                TapControllerPanel *p=[TapControllerPanel shared];
                if(p.hidden)[p forceShow];else[p hidePanel];
                s_twoFingerStart=nil;
            }
        }else{s_twoFingerStart=nil;}
        if(ts.count==1){
            UITouch *t=[ts anyObject];
            if(t.phase==UITouchPhaseEnded&&t.view){
                CGPoint pt=[t locationInView:nil];
                NSString *cn=NSStringFromClass([t.view class]);
                [[TapControllerPanel shared]showLog:[NSString stringWithFormat:@"📍 坐标 (%.0f, %.0f) → %@\n",pt.x,pt.y,cn]];
                showToast([NSString stringWithFormat:@"📍 (%.0f,%.0f)",pt.x,pt.y]);
            }
        }
    }
}
%end

%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        UIWindowScene *as=nil;
        for(UIScene *s in [UIApplication sharedApplication].connectedScenes){if([s isKindOfClass:[UIWindowScene class]]&&s.activationState==UISceneActivationStateForegroundActive){as=(UIWindowScene*)s;break;}}
        if(as){s_tapWindow=[[TapControllerWindow alloc]initWithFrame:as.coordinateSpace.bounds];s_tapWindow.windowScene=as;TapControllerPanel *p=[TapControllerPanel shared];p.frame=CGRectMake(5,180,s_tapWindow.bounds.size.width-10,300);p.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleBottomMargin;[s_tapWindow addSubview:p];s_tapWindow.panel=p;s_tapWindow.hidden=NO;}
        showToast(@"🟢 Accessibility 触摸已激活");
        [[TapControllerPanel shared]showLog:@"🟢 Accessibility 触摸模式\n"];
    });
}
#pragma clang diagnostic pop
