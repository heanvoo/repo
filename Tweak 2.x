// StretchClock 0.4.0 — размер / растяжение / сдвиг часов на экране блокировки.
// Лёгкий хук: только transform. Настройки применяются сразу.

#import <UIKit/UIKit.h>

static NSString *const kDomain = @"com.stretchclock.tweak";

static BOOL gEnabled = YES;
static CGFloat gSize = 1.2, gSX = 1.0, gSY = 1.15, gOX = 0, gOY = 0;
static NSHashTable *gTracked = nil;

static id readPref(NSString *key) {
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                       (__bridge CFStringRef)kDomain));
}

static void loadPrefs(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    id v;
    v = readPref(@"enabled");  gEnabled = v ? [v boolValue] : YES;
    v = readPref(@"size");     gSize = v ? [v doubleValue] : 1.2;
    v = readPref(@"stretchX"); gSX   = v ? [v doubleValue] : 1.0;
    v = readPref(@"stretchY"); gSY   = v ? [v doubleValue] : 1.15;
    v = readPref(@"offsetX");  gOX   = v ? [v doubleValue] : 0;
    v = readPref(@"offsetY");  gOY   = v ? [v doubleValue] : 0;
}

static void applyTo(UIView *v) {
    CGAffineTransform tr = gEnabled
        ? CGAffineTransformMake(gSize * gSX, 0, 0, gSize * gSY, gOX, gOY)
        : CGAffineTransformIdentity;
    if (!CGAffineTransformEqualToTransform(v.transform, tr)) v.transform = tr;
}

static void prefsChanged(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef u) {
    loadPrefs();
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIView *v in gTracked.allObjects) applyTo(v);
    });
}

static BOOL looksLikeTime(NSString *s) {
    NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
    BOOL sep = NO;
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c == ':' || c == '.' || c == 0xFF1A) sep = YES;
        else if (![digits characterIsMember:c] && c != ' ') return NO;
    }
    return sep;
}

static BOOL isLargeLabel(UILabel *l) {
    CGFloat fs = l.font.pointSize;
    if (l.attributedText.length > 0) {
        UIFont *f = [l.attributedText attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL];
        if (f) fs = MAX(fs, f.pointSize);
    }
    return fs >= 30.0 || l.bounds.size.height >= 45.0;
}

static BOOL inStatusBar(UIView *v) {
    UIView *p = v;
    for (int i = 0; p && i < 14; i++, p = p.superview)
        if ([NSStringFromClass(p.class) containsString:@"StatusBar"]) return YES;
    if (v.window && [NSStringFromClass(v.window.class) containsString:@"StatusBar"]) return YES;
    return NO;
}

%hook UILabel
- (void)layoutSubviews {
    %orig;
    if ([gTracked containsObject:self]) { applyTo(self); return; }
    NSString *t = self.text;
    if (!t || t.length < 3 || t.length > 8 || !looksLikeTime(t)) return;
    if (!isLargeLabel(self) || inStatusBar(self)) return;
    [gTracked addObject:self];
    UIView *p = self.superview;                      // чтобы сдвиг/увеличение не обрезались
    for (int i = 0; p && i < 2; i++, p = p.superview) p.clipsToBounds = NO;
    applyTo(self);
}
%end

%ctor {
    @autoreleasepool {
        NSString *bid = NSBundle.mainBundle.bundleIdentifier;
        if (![bid isEqualToString:@"com.apple.springboard"] &&
            ![bid isEqualToString:@"com.apple.PosterBoard"]) return;
        gTracked = [NSHashTable weakObjectsHashTable];
        loadPrefs();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            prefsChanged, CFSTR("com.stretchclock.tweak/reload"), NULL,
            CFNotificationSuspensionBehaviorCoalesce);
        %init;
    }
}
