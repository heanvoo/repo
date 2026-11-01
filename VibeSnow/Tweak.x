// VibeSnow - animated snowfall overlay for SpringBoard (rootless, iOS 15+).
// One passthrough UIWindow above everything + a CAEmitterLayer. No private frameworks.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <notify.h>

#define PREFS_ID CFSTR("com.heanvoo.overlaysnow")
#define RELOAD_NOTE "com.heanvoo.overlaysnow/reload"

@interface SpringBoard : UIApplication
- (id)_accessibilityFrontMostApplication;
@end

// Window that never catches touches and never becomes key.
@interface VSPassWindow : UIWindow
@end
@implementation VSPassWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { return nil; }
- (BOOL)canBecomeKeyWindow { return NO; }
@end

static VSPassWindow *gWindow;
static CAEmitterLayer *gEmitter;
static NSTimer *gTimer;
static int gNotifyToken;

static BOOL gEnabled = YES;
static BOOL gInApps = NO;
static double gAmount = 40.0; // 5...100
static double gSpeed = 1.0;   // 0.3...3
static double gSize = 1.0;    // 0.4...2
static int gColor = 0;        // 0 white, 1 blue

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

static void configureEmitter(void) {
    CGRect b = UIScreen.mainScreen.bounds;
    CGFloat w = b.size.width, h = b.size.height;

    gEmitter.frame = b;
    gEmitter.emitterShape = kCAEmitterLayerLine;
    gEmitter.emitterPosition = CGPointMake(w / 2, -20);
    gEmitter.emitterSize = CGSizeMake(w * 1.3, 1);
    gEmitter.renderMode = kCAEmitterLayerUnordered;

    double vel = 70.0 * gSpeed;
    CAEmitterCell *c = [CAEmitterCell emitterCell];
    c.contents = (__bridge id)flakeImage().CGImage;
    c.contentsScale = UIScreen.mainScreen.scale;
    c.birthRate = (float)(gAmount * 0.3);
    c.lifetime = (float)((h + 60.0) / (vel * 0.6)); // slowest flake still reaches the bottom
    c.velocity = vel;
    c.velocityRange = vel * 0.4;
    c.emissionLongitude = M_PI_2;   // straight down
    c.emissionRange = M_PI / 10.0;  // slight spread
    c.xAcceleration = 6.0;          // gentle wind drift
    c.scale = 0.35 * gSize;
    c.scaleRange = 0.25 * gSize;
    c.alphaRange = 0.4;

    UIColor *col = gColor == 1 ? [UIColor colorWithRed:0.6 green:0.8 blue:1.0 alpha:0.95]
                               : [UIColor colorWithWhite:1.0 alpha:0.95];
    c.color = col.CGColor;

    gEmitter.emitterCells = @[c];
}

static UIWindowScene *pickScene(void) {
    CGSize full = UIScreen.mainScreen.bounds.size;
    UIWindowScene *best = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)s;
        CGSize cs = ws.coordinateSpace.bounds.size;
        // skip status-bar-sized and other partial scenes
        if (fabs(cs.width - full.width) > 1 || fabs(cs.height - full.height) > 1) continue;
        best = ws;
        if (ws.activationState == UISceneActivationStateForegroundActive) break;
    }
    return best;
}

static void ensureWindow(void) {
    if (gWindow) return;
    CGRect b = UIScreen.mainScreen.bounds;

    UIWindowScene *scene = pickScene();
    gWindow = scene ? [[VSPassWindow alloc] initWithWindowScene:scene]
                    : [[VSPassWindow alloc] initWithFrame:b];
    gWindow.frame = b;
    gWindow.windowLevel = UIWindowLevelAlert + 1000;
    gWindow.backgroundColor = UIColor.clearColor;
    gWindow.userInteractionEnabled = NO;

    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = UIColor.clearColor;
    vc.view.userInteractionEnabled = NO;
    vc.view.clipsToBounds = NO;
    gWindow.rootViewController = vc;

    gEmitter = [CAEmitterLayer layer];
    gEmitter.masksToBounds = NO;
    [vc.view.layer addSublayer:gEmitter];
}

static void checkFrontmost(void) {
    if (!gWindow) return;
    id app = [(SpringBoard *)UIApplication.sharedApplication _accessibilityFrontMostApplication];
    gWindow.hidden = (app != nil); // an app is open -> hide, Home/Lock -> show
}

static void refresh(void) {
    loadPrefs();

    [gTimer invalidate];
    gTimer = nil;

    if (!gEnabled) {
        gWindow.hidden = YES;
        gEmitter.birthRate = 0;
        return;
    }

    ensureWindow();
    configureEmitter();
    gEmitter.birthRate = 1;
    gWindow.hidden = NO;

    if (!gInApps) {
        checkFrontmost();
        gTimer = [NSTimer scheduledTimerWithTimeInterval:0.6 repeats:YES block:^(NSTimer *t) { checkFrontmost(); }];
    }
}

#pragma mark - Hook

%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        refresh();
        notify_register_dispatch(RELOAD_NOTE, &gNotifyToken, dispatch_get_main_queue(), ^(int token) { refresh(); });
    });
}
%end
