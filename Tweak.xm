#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach/mach_time.h>

static NSMutableString *s_log = nil;
static void logMsg(NSString *m) {
    if (!s_log) s_log = [NSMutableString string];
    [s_log appendFormat:@"%@\n", m];
}

%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        s_log = [NSMutableString string];
        
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(10, 100, [UIScreen mainScreen].bounds.size.width - 20, 600)];
        label.text = @"用手触摸屏幕，看日志";
        label.textColor = [UIColor greenColor];
        label.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.9];
        label.font = [UIFont systemFontOfSize:10];
        label.numberOfLines = 0;
        
        UIWindow *w = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        w.windowLevel = CGFLOAT_MAX;
        w.backgroundColor = [UIColor clearColor];
        w.hidden = NO;
        w.userInteractionEnabled = NO;
        [w addSubview:label];
        
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
            label.text = s_log;
        }];
    });
}
