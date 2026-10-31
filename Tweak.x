

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *const kDomain = @"com.stretchclock.tweak";
static const CGFloat kMinClockFont = 30.0; // часы на локскрине крупные, статус-бар ~15pt

static BOOL gEnabled = YES, gDebug = NO, gHideDate = NO;
static CGFloat gSize = 1.2, gStretchX = 1.0, gStretchY = 1.15, gOffX = 0, gOffY = 0;
static NSString *gClassName = nil;
static NSHashTable *gClockViews = nil, *gDateViews = nil;
static NSMutableSet *gLogged = nil;

static CGFloat prefFloat(NSUserDefaults *d, NSString *k, CGFloat def) {
    id v = [d objectForKey:k]; return v ? [v doubleValue] : def;
}
static BOOL prefBool(NSUserDefaults *d, NSString *k, BOOL def) {
    id v = [d objectForKey:k]; return v ? [v boolValue] : def;
}

static void loadPrefs(void) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kDomain];
    gEnabled   = prefBool(d, @"enabled", YES);
    gDebug     = prefBool(d, @"debug", NO);
    gHideDate  = prefBool(d, @"hideDate", NO);
    gSize      = prefFloat(d, @"size", 1.2);
    gStretchX  = prefFloat(d, @"stretchX", 1.0);
    gStretchY  = prefFloat(d, @"stretchY", 1.15);
    gOffX      = prefFloat(d, @"offsetX", 0);
    gOffY      = prefFloat(d, @"offsetY", 0);
    id v = [d objectForKey:@"className"];
    gClassName = ([v isKindOfClass:[NSString class]] && [v length]) ? v : nil;
}

static BOOL looksLikeTime(NSString *s) {
    NSUInteger n = s.length;
    if (n < 3 || n > 8) return NO;
    NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
    BOOL sep = NO;
    for (NSUInteger i = 0; i < n; i++) {
        unichar c = [s characterAtIndex:i];
        if (c == ':' || c == '.' || c == 0xFF1A) sep = YES;
        else if (![digits characterIsMember:c] && c != ' ') return NO;
    }
    return sep;
}

static BOOL chainContains(UIView *v, NSString *needle, int depth) {
    UIView *p = v;
    for (int i = 0; p && i < depth; i++, p = p.superview)
        if ([NSStringFromClass(p.class) containsString:needle]) return YES;
    return NO;
}

static BOOL inStatusBar(UIView *v) {
    if (chainContains(v, @"StatusBar", 14)) return YES;
    if (v.window && [NSStringFromClass(v.window.class) containsString:@"StatusBar"]) return YES;
    return NO;
}

static void debugLog(UIView *v, NSString *why, NSString *text) {
    if (!gDebug) return;
    if (!gLogged) gLogged = [NSMutableSet set];
    NSString *key = [NSString stringWithFormat:@"%@|%@|%@", why, NSStringFromClass(v.class), text];
    if ([gLogged containsObject:key]) return;
    [gLogged addObject:key];
    NSMutableArray *a = [NSMutableArray array];
    UIView *p = v.superview;
    for (int i = 0; p && i < 8; i++, p = p.superview) [a addObject:NSStringFromClass(p.class)];
    NSString *line = [NSString stringWithFormat:@"[%@] %@ text='%@' <%@> font=%.1f chain: %@\n",
        NSProcessInfo.processInfo.processName, why, text, NSStringFromClass(v.class),
        [v isKindOfClass:[UILabel class]] ? ((UILabel *)v).font.pointSize : 0.0,
        [a componentsJoinedByString:@" > "]];
    NSString *path = @"/var/mobile/StretchClock.log";
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!h) { [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
              h = [NSFileHandle fileHandleForWritingAtPath:path]; }
    [h seekToEndOfFile]; [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [h closeFile];
}

static void applyClock(UIView *v) {
    CGFloat sx = 1, sy = 1;
    CGAffineTransform t = CGAffineTransformIdentity;
    if (gEnabled) {
        sx = gSize * gStretchX;
        sy = gSize * gStretchY;
        t = CGAffineTransformMake(sx, 0, 0, sy, gOffX, gOffY);
    }
    if (!CGAffineTransformEqualToTransform(v.transform, t)) v.transform = t;
    // чтобы увеличенный текст не был мыльным — рендерим с большим разрешением
    CGFloat target = UIScreen.mainScreen.scale * MAX(1.0, MIN(MAX(sx, sy), 3.0));
    if (fabs(v.contentScaleFactor - target) > 0.01) v.contentScaleFactor = target;
    // чтобы родитель не обрезал увеличенные/сдвинутые часы
    UIView *p = v.superview;
    for (int i = 0; p && i < 3; i++, p = p.superview) p.clipsToBounds = NO;
}

static void refreshAll(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIView *v in gClockViews.allObjects) { applyClock(v); [v setNeedsLayout]; }
        for (UILabel *l in gDateViews.allObjects) l.hidden = (gEnabled && gHideDate);
    });
}

static void prefsChanged(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef u) {
    loadPrefs();
    refreshAll();
}

%hook UILabel
- (void)layoutSubviews {
    %orig;
    NSString *t = self.text;
    if (!t.length || inStatusBar(self)) return;
    CGFloat fs = self.font.pointSize;

    if (!gClassName && fs >= kMinClockFont && looksLikeTime(t)) {
        [gClockViews addObject:self];
        debugLog(self, @"CLOCK", t);
        applyClock(self);
    } else if (fs < kMinClockFont && t.length >= 4 && !looksLikeTime(t) && chainContains(self, @"Date", 8)) {
        [gDateViews addObject:self];
        debugLog(self, @"DATE?", t);
        if (gEnabled && gHideDate) self.hidden = YES;
    }
}
%end

%group ClockHook
%hook ClockView
- (void)layoutSubviews {
    %orig;
    [gClockViews addObject:(UIView *)self];
    debugLog((UIView *)self, @"CLOCK(class)", @"");
    applyClock((UIView *)self);
}
%end
%end

%ctor {
    @autoreleasepool {
        NSString *bid = NSBundle.mainBundle.bundleIdentifier;
        if (![bid isEqualToString:@"com.apple.springboard"] && ![bid isEqualToString:@"com.apple.PosterBoard"]) return;
        gClockViews = [NSHashTable weakObjectsHashTable];
        gDateViews  = [NSHashTable weakObjectsHashTable];
        loadPrefs();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            prefsChanged, CFSTR("com.stretchclock.tweak/reload"), NULL,
            CFNotificationSuspensionBehaviorCoalesce);
        if (gClassName) {
            Class cls = objc_getClass(gClassName.UTF8String);
            if (cls && [cls isSubclassOfClass:[UIView class]]) { %init(ClockHook, ClockView = cls); }
        }
        %init;
    }
}
