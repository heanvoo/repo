// StretchClock 0.2 — размер / растяжение / позиция часов на экране блокировки,
// скрытие даты. Часы ищутся автоматически (UILabel с текстом "9:41" и крупным шрифтом).
// Часы в статус-баре (у чёлки) исключены.

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

// Только лёгкая операция: transform. Вызывается из layoutSubviews.
static void applyTransform(UIView *v) {
    CGAffineTransform t = CGAffineTransformIdentity;
    if (gEnabled) {
        t = CGAffineTransformMake(gSize * gStretchX, 0, 0, gSize * gStretchY, gOffX, gOffY);
    }
    if (!CGAffineTransformEqualToTransform(v.transform, t)) v.transform = t;
}

// Тяжёлое (чёткость, обрезка) — НИКОГДА не из layoutSubviews, только асинхронно.
static void applyExtras(UIView *v) {
    CGFloat s = gEnabled ? MAX(gSize * gStretchX, gSize * gStretchY) : 1.0;
    CGFloat target = UIScreen.mainScreen.scale * MAX(1.0, MIN(s, 3.0));
    if (fabs(v.contentScaleFactor - target) > 0.01) v.contentScaleFactor = target;
    UIView *p = v.superview;
    for (int i = 0; p && i < 3; i++, p = p.superview) {
        if (p.clipsToBounds) p.clipsToBounds = NO;
    }
}

static void trackClock(UIView *v) {
    if ([gClockViews containsObject:v]) return;
    [gClockViews addObject:v];
    __weak UIView *w = v;
    dispatch_async(dispatch_get_main_queue(), ^{ if (w) applyExtras(w); });
}

static void refreshAll(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIView *v in gClockViews.allObjects) { applyTransform(v); applyExtras(v); }
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
    static BOOL busy = NO;
    if (busy || !self.window) return;
    busy = YES;

    if ([gClockViews containsObject:self]) {
        applyTransform(self);                       // уже знаем, что это часы
    } else {
        CGFloat fs = self.font.pointSize;           // дёшево
        NSString *t = self.text;
        if (t.length >= 3 && t.length <= 40) {
            if (!gClassName && fs >= kMinClockFont && looksLikeTime(t) && !inStatusBar(self)) {
                trackClock(self);
                debugLog(self, @"CLOCK", t);
                applyTransform(self);
            } else if (gHideDate && gEnabled && fs < kMinClockFont && t.length >= 4
                       && !looksLikeTime(t) && chainContains(self, @"Date", 8) && !inStatusBar(self)) {
                [gDateViews addObject:self];
                debugLog(self, @"DATE?", t);
                self.hidden = YES;
            }
        }
    }
    busy = NO;
}
%end

%group ClockHook
%hook ClockView
- (void)layoutSubviews {
    %orig;
    trackClock((UIView *)self);
    applyTransform((UIView *)self);
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
