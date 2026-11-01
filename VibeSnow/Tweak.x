// SnowOverlay - animated snowfall overlay for SpringBoard (rootless, iOS 15+).
// One passthrough window per full-size UIWindowScene + CAEmitterLayer. Logs to /var/mobile/vibesnow.log.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <notify.h>

#define PREFS_ID CFSTR("com.heanvoo.overlaysnow")
#define RELOAD_NOTE "com.heanvoo.overlaysnow/reload"
#define LOG_PATH @"/var/mobile/vibesnow.log"

@interface SpringBoard : UIApplication
- (id)_accessibilityFrontMostApplication;
@end

@interface VSPassWindow : UIWindow
@end
@implementation VSPassWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { return nil; }
- (BOOL)canBecomeKeyWindow { return NO; }
@end

static NSMutableArray<VSPassWindow *> *gWindows;
static NSMutableArray<CAEmitterLayer *> *gEmitters;
static NSTimer *gTimer;
static int gNotifyToken;

static BOOL gEnabled = YES;
static BOOL gInApps = NO;
static double gAmount = 40.0; // 5...100
static double gSpeed = 1.0;   // 0.3...3
static double gSize = 1.0;    // 0.4...2
static int gColor = 0;        // 0 white, 1 blue

#pragma mark - Log

static void vlog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void vlog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSFileManager *fm = NSFileManager.defaultManager;
    NSDictionary *attrs = [fm attributesOfItemAtPath:LOG_PATH error:nil];
    if ([attrs fileSize] > 65536) [fm removeItemAtPath:LOG_PATH error:nil];
    if (![fm fileExistsAtPath:LOG_PATH]) [fm createFileAtPath:LOG_PATH contents:nil attributes:nil];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:LOG_PATH];
    [h seekToEndOfFile];
    [h writeData:[[msg stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
    [h closeFile];
}

#pragma mark - Prefs

static double prefDouble(CFStringRef key, double def) {
    double r = def;
    CFPropertyListRef v = CFPreferencesCopyAppValue(key, PREFS_ID);
    if (v) {
        if (CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)v, kCFNumberDoubleType, &r);
        CFRelease(v);
    }
    return r;
}

static BOOL prefBool(CFStringRef key, BOOL def) {
    BOOL r = def;
    CFPropertyListRef v = CFPreferencesCopyAppValue(key, PREFS_ID);
    if (v) {
        if (CFGetTypeID(v) == CFBooleanGetTypeID()) r = CFBooleanGetValue((CFBooleanRef)v);
        else if (CFGetTypeID(v) == CFNumberGetTypeID()) { double d = 0; CFNumberGetValue((CFNumberRef)v, kCFNumberDoubleType, &d); r = d != 0; }
        CFRelease(v);
    }
    return r;
}

static void loadPrefs(void) {
    CFPreferencesAppSynchronize(PREFS_ID);
    gEnabled = prefBool(CFSTR("enabled"), YES);
    gInApps  = prefBool(CFSTR("showInApps"), NO);
    gAmount  = MAX(5.0, MIN(100.0, prefDouble(CFSTR("amount"), 40.0)));
    gSpeed   = MAX(0.3, MIN(3.0,   prefDouble(CFSTR("speed"), 1.0)));
    gSize    = MAX(0.4, MIN(2.0,   prefDouble(CFSTR("size"), 1.0)));
    gColor   = (int)prefDouble(CFSTR("color"), 0);
}

#pragma mark - Snow

static UIImage *flakeImage(void) {
    const CGFloat s = 24.0;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(s, s)];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGFloat comps[8] = {1, 1, 1, 1,   1, 1, 1, 0};
        CGGradientRef g = CGGradientCreateWithColorComponents(cs, comps, NULL, 2);
        CGPoint c = CGPointMake(s / 2, s / 2);
        CGContextDrawRadialGradient(ctx.CGContext, g, c, 0, c, s / 2, 0);
        CGGradientRelease(g);
        CGColorSpaceRelease(cs);
    }];
}

static void configureEmitter(CAEmitterLayer *e) {
    CGRect b = UIScreen.mainScreen.bounds;
    CGFloat w = b.size.width, h = b.size.height;

    e.frame = CGRectMake(0, 0, w, h);
    e.masksToBounds = NO;
    e.emitterShape = kCAEmitterLayerLine;
    e.emitterPosition = CGPointMake(w / 2, -20);
    e.emitterSize = CGSizeMake(w * 1.3, 1);
    e.renderMode = kCAEmitterLayerUnordered;

    double vel = 70.0 * gSpeed;
    CAEmitterCell *c = [CAEmitterCell emitterCell];
    c.contents = (__bridge id)flakeImage().CGImage;
    c.contentsScale = UIScreen.mainScreen.scale;
    c.birthRate = (float)(gAmount * 0.3);
    c.lifetime = (float)((h + 80.0) / (vel * 0.5));
    c.velocity = vel;
    c.velocityRange = vel * 0.4;
    c.emissionLongitude = M_PI_2;   // straight down
    c.emissionRange = M_PI / 10.0;
    c.xAcceleration = 6.0;
    c.scale = 0.35 * gSize;
    c.scaleRange = 0.25 * gSize;
    c.alphaRange = 0.4;

    UIColor *col = gColor == 1 ? [UIColor colorWithRed:0.6 green:0.8 blue:1.0 alpha:0.95]
                               : [UIColor colorWithWhite:1.0 alpha:0.95];
    c.color = col.CGColor;

    e.emitterCells = @[c];
}

static void addWindow(UIWindowScene *scene) {
    CGRect b = UIScreen.mainScreen.bounds;
    VSPassWindow *w = scene ? [[VSPassWindow alloc] initWithWindowScene:scene]
                            : [[VSPassWindow alloc] initWithFrame:b];
    w.frame = b;
    w.windowLevel = UIWindowLevelAlert + 1000;
    w.backgroundColor = UIColor.clearColor;
    w.userInteractionEnabled = NO;

    UIView *host = [[UIView alloc] initWithFrame:b];
    host.backgroundColor = UIColor.clearColor;
    host.userInteractionEnabled = NO;
    host.clipsToBounds = NO;
    [w addSubview:host];

    CAEmitterLayer *e = [CAEmitterLayer layer];
    [host.layer addSublayer:e];

    [gWindows addObject:w];
    [gEmitters addObject:e];
    vlog(@"added window for scene %@", scene ? scene.session.persistentIdentifier : @"(none)");
}

// One window per full-size window scene (partial scenes such as the status bar are skipped).
static void syncWindows(void) {
    if (!gWindows) { gWindows = [NSMutableArray new]; gEmitters = [NSMutableArray new]; }
    CGSize full = UIScreen.mainScreen.bounds.size;
    BOOL anyFull = NO;

    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)s;
        CGSize cs = ws.coordinateSpace.bounds.size;
        vlog(@"scene %@ class=%@ role=%@ size=%.0fx%.0f windows=%lu state=%ld",
             ws.session.persistentIdentifier, NSStringFromClass(ws.class), ws.session.role,
             cs.width, cs.height, (unsigned long)ws.windows.count, (long)ws.activationState);
        if (fabs(cs.width - full.width) > 1 || fabs(cs.height - full.height) > 1) continue;
        anyFull = YES;
        BOOL covered = NO;
        for (VSPassWindow *w in gWindows) if (w.windowScene == ws) { covered = YES; break; }
        if (!covered) addWindow(ws);
    }
    if (!anyFull && gWindows.count == 0) {
        vlog(@"no full-size scene, using scene-less window");
        addWindow(nil);
    }
}

static void setAllHidden(BOOL hidden) {
    for (VSPassWindow *w in gWindows) w.hidden = hidden;
}

static void checkFrontmost(void) {
    id app = [(SpringBoard *)UIApplication.sharedApplication _accessibilityFrontMostApplication];
    setAllHidden(app != nil); // an app is open -> hide, Home/Lock -> show
}

static void refresh(void) {
    loadPrefs();

    [gTimer invalidate];
    gTimer = nil;

    if (!gEnabled) {
        setAllHidden(YES);
        for (CAEmitterLayer *e in gEmitters) e.birthRate = 0;
        return;
    }

    syncWindows();
    for (CAEmitterLayer *e in gEmitters) { configureEmitter(e); e.birthRate = 1; }
    setAllHidden(NO);

    if (!gInApps) {
        checkFrontmost();
        gTimer = [NSTimer scheduledTimerWithTimeInterval:0.6 repeats:YES block:^(NSTimer *t) { checkFrontmost(); }];
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        for (VSPassWindow *w in gWindows)
            vlog(@"window frame=%@ hidden=%d level=%.0f scene=%@",
                 NSStringFromCGRect(w.frame), w.hidden, w.windowLevel,
                 w.windowScene ? w.windowScene.session.persistentIdentifier : @"(none)");
    });
}

#pragma mark - Hook

%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        vlog(@"=== SnowOverlay start, iOS %@ ===", UIDevice.currentDevice.systemVersion);
        refresh();
        notify_register_dispatch(RELOAD_NOTE, &gNotifyToken, dispatch_get_main_queue(), ^(int token) { refresh(); });
        // Lock screen / other scenes may connect later.
        [NSNotificationCenter.defaultCenter addObserverForName:UISceneWillConnectNotification object:nil
            queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ refresh(); });
            }];
    });
}
%end
