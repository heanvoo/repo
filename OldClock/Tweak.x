// OldClock - brings back the iOS 14/15 Lock Screen clock: thin digits, date UNDER the time.
// Same safe idea as StretchClock: the system labels never draw their own text; we draw ours
// inside the system time label as subviews, so the system can't reset our changes.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *const kDomain = @"com.heanvoo.oldclock";
static const CGFloat kMinClockFont = 30.0;

static BOOL gEnabled = YES, gDateBelow = YES;
static CGFloat gSize = 82.0, gDateSize = 21.0, gOffsetY = 0.0;
static int gWeight = 2; // 0 ultralight, 1 thin, 2 light, 3 regular
static NSHashTable *gClocks = nil, *gDates = nil;

static const void *kTimeOvKey = &kTimeOvKey;   // on the system label: our time label
static const void *kDateOvKey = &kDateOvKey;   // on the system label: our date label
static const void *kIsOverlayKey = &kIsOverlayKey;
static const void *kNoClipKey = &kNoClipKey;

#pragma mark - Preferences

static id readPref(NSString *key) {
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                       (__bridge CFStringRef)kDomain));
}

static void loadPrefs(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    id v;
    v = readPref(@"enabled");   gEnabled   = v ? [v boolValue] : YES;
    v = readPref(@"dateBelow"); gDateBelow = v ? [v boolValue] : YES;
    v = readPref(@"size");      gSize      = v ? MAX(40.0, MIN(140.0, [v doubleValue])) : 82.0;
    v = readPref(@"dateSize");  gDateSize  = v ? MAX(12.0, MIN(34.0, [v doubleValue])) : 21.0;
    v = readPref(@"offsetY");   gOffsetY   = v ? MAX(-150.0, MIN(150.0, [v doubleValue])) : 0.0;
    v = readPref(@"weight");    gWeight    = v ? (int)[v integerValue] : 2;
}

static UIFontWeight weightFor(int w) {
    switch (w) {
        case 0: return UIFontWeightUltraLight;
        case 1: return UIFontWeightThin;
        case 3: return UIFontWeightRegular;
        default: return UIFontWeightLight;
    }
}

#pragma mark - Helpers

static UIFont *currentFont(UILabel *l) {
    if (l.attributedText.length > 0) {
        UIFont *f = [l.attributedText attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL];
        if (f) return f;
    }
    return l.font;
}

static UIColor *currentColor(UILabel *l) {
    if (l.attributedText.length > 0) {
        UIColor *c = [l.attributedText attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:NULL];
        if (c) return c;
    }
    return l.textColor ?: UIColor.whiteColor;
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

static BOOL isLargeLabel(UILabel *l) {
    return currentFont(l).pointSize >= kMinClockFont || l.bounds.size.height >= 45.0;
}

#pragma mark - Date detection (to hide the system date that sits ABOVE the time)

static NSString *normalizeText(NSString *s) {
    NSMutableString *o = [NSMutableString string];
    NSCharacterSet *alnum = [NSCharacterSet alphanumericCharacterSet];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if ([alnum characterIsMember:c]) [o appendFormat:@"%C", c];
    }
    return [o lowercaseString];
}

static NSArray *dateCandidates(void) {
    static NSArray *cache = nil;
    static NSInteger cacheDay = -1;
    NSDate *now = [NSDate date];
    NSInteger day = [[NSCalendar currentCalendar] component:NSCalendarUnitDay fromDate:now];
    if (cache && day == cacheDay) return cache;
    NSLocale *loc = [NSLocale currentLocale];
    NSMutableArray *a = [NSMutableArray array];
    for (NSString *tpl in @[@"EEEEMMMMd", @"EEEMMMd", @"EEEEMMMd", @"EEEMMMMd", @"MMMMd", @"MMMd", @"EEEEd", @"EEEd"]) {
        NSDateFormatter *f = [[NSDateFormatter alloc] init];
        f.locale = loc;
        f.dateFormat = [NSDateFormatter dateFormatFromTemplate:tpl options:0 locale:loc];
        NSString *s = normalizeText([f stringFromDate:now]);
        if (s.length >= 4) [a addObject:s];
    }
    cache = a; cacheDay = day;
    return a;
}

static BOOL looksLikeDate(NSString *t) {
    if (t.length < 4 || t.length > 48) return NO;
    NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
    BOOL hasDigit = NO;
    for (NSUInteger i = 0; i < t.length; i++)
        if ([digits characterIsMember:[t characterAtIndex:i]]) { hasDigit = YES; break; }
    if (!hasDigit) return NO;
    NSString *n = normalizeText(t);
    for (NSString *cand in dateCandidates())
        if ([n containsString:cand]) return YES;
    return NO;
}

static NSString *oldDateString(void) {
    NSLocale *loc = [NSLocale currentLocale];
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.locale = loc;
    f.timeZone = [NSTimeZone localTimeZone];
    f.dateFormat = [NSDateFormatter dateFormatFromTemplate:@"EEEEMMMMd" options:0 locale:loc];
    return [f stringFromDate:[NSDate date]];
}

#pragma mark - Overlays

static UILabel *makeOverlay(void) {
    UILabel *o = [[UILabel alloc] initWithFrame:CGRectZero];
    objc_setAssociatedObject(o, kIsOverlayKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    o.userInteractionEnabled = NO;
    o.backgroundColor = UIColor.clearColor;
    o.numberOfLines = 1;
    o.adjustsFontSizeToFitWidth = NO;
    o.lineBreakMode = NSLineBreakByClipping;
    o.textAlignment = NSTextAlignmentCenter;
    o.clipsToBounds = NO;
    return o;
}

static void ensureOverlays(UILabel *l) {
    if (objc_getAssociatedObject(l, kTimeOvKey)) return;
    UILabel *t = makeOverlay(), *d = makeOverlay();
    [l addSubview:t];
    [l addSubview:d];
    objc_setAssociatedObject(l, kTimeOvKey, t, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(l, kDateOvKey, d, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void syncOverlay(UILabel *l) {
    UILabel *tov = objc_getAssociatedObject(l, kTimeOvKey);
    UILabel *dov = objc_getAssociatedObject(l, kDateOvKey);
    if (!tov || !dov) return;

    tov.hidden = !gEnabled;
    dov.hidden = !(gEnabled && gDateBelow);
    if (!gEnabled) return;

    NSString *txt = l.text ?: @"";
    UIColor *col = currentColor(l);

    UIFont *tf = [UIFont systemFontOfSize:gSize weight:weightFor(gWeight)];
    if (![tov.text isEqualToString:txt]) tov.text = txt;
    if (![tov.font isEqual:tf]) tov.font = tf;
    if (![tov.textColor isEqual:col]) tov.textColor = col;

    CGSize bs = [txt sizeWithAttributes:@{NSFontAttributeName: tf}];
    CGFloat tw = ceil(bs.width) + 24.0;
    CGFloat th = ceil(tf.lineHeight) + 4.0;
    CGRect lb = l.bounds;
    CGFloat cx = CGRectGetMidX(lb);
    CGFloat cy = CGRectGetMidY(lb) + gOffsetY;

    CGRect tb = CGRectMake(0, 0, tw, th);
    if (!CGRectEqualToRect(tov.bounds, tb)) tov.bounds = tb;
    CGPoint tc = CGPointMake(cx, cy);
    if (!CGPointEqualToPoint(tov.center, tc)) tov.center = tc;

    if (!gDateBelow) return;

    UIFont *df = [UIFont systemFontOfSize:gDateSize weight:UIFontWeightRegular];
    NSString *ds = oldDateString();
    if (![dov.text isEqualToString:ds]) dov.text = ds;
    if (![dov.font isEqual:df]) dov.font = df;
    if (![dov.textColor isEqual:col]) dov.textColor = col;

    CGSize dsz = [ds sizeWithAttributes:@{NSFontAttributeName: df}];
    CGFloat dw = ceil(dsz.width) + 24.0;
    CGFloat dh = ceil(df.lineHeight) + 4.0;
    // baseline of the time text, then the date sits a little below it
    CGFloat baseline = (cy - th / 2.0) + (th - tf.lineHeight) / 2.0 + tf.ascender;
    CGRect db = CGRectMake(0, 0, dw, dh);
    if (!CGRectEqualToRect(dov.bounds, db)) dov.bounds = db;
    CGPoint dc = CGPointMake(cx, baseline + 8.0 + dh / 2.0);
    if (!CGPointEqualToPoint(dov.center, dc)) dov.center = dc;
}

#pragma mark - No clipping (kept off even if the system turns it back on)

static void unclipChain(UIView *v) {
    CGSize scr = UIScreen.mainScreen.bounds.size;
    UIView *p = v;
    for (int i = 0; p && i < 12; i++, p = p.superview) {
        if (i > 0 && p.bounds.size.width >= scr.width - 1 && p.bounds.size.height >= scr.height - 1) break;
        objc_setAssociatedObject(p, kNoClipKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(p.layer, kNoClipKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (p.clipsToBounds) p.clipsToBounds = NO;
        if (p.layer.masksToBounds) p.layer.masksToBounds = NO;
    }
}

static void scheduleUnclip(UIView *v) {
    __weak UIView *w = v;
    dispatch_async(dispatch_get_main_queue(), ^{ UIView *s = w; if (s) unclipChain(s); });
}

static void relayoutLabels(UIView *v, int depth) {
    if (depth > 24) return;
    if ([v isKindOfClass:[UILabel class]]) [v setNeedsLayout];
    for (UIView *s in v.subviews) relayoutLabels(s, depth + 1);
}

static void prefsChanged(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef u) {
    loadPrefs();
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UILabel *l in gClocks.allObjects) {
            syncOverlay(l);
            [l setNeedsDisplay];
            unclipChain(l);
        }
        for (UILabel *l in gDates.allObjects) [l setNeedsDisplay];
        if (gEnabled && gDateBelow) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            for (UIWindow *w in UIApplication.sharedApplication.windows) relayoutLabels(w, 0);
#pragma clang diagnostic pop
        }
    });
}

#pragma mark - Hooks

%hook UIView
- (void)setClipsToBounds:(BOOL)clips {
    if (clips && objc_getAssociatedObject(self, kNoClipKey)) clips = NO;
    %orig(clips);
}
%end

%hook CALayer
- (void)setMasksToBounds:(BOOL)masks {
    if (masks && objc_getAssociatedObject(self, kNoClipKey)) masks = NO;
    %orig(masks);
}
%end

%hook UILabel

- (void)drawTextInRect:(CGRect)rect {
    if (gEnabled) {
        if ([gClocks containsObject:self]) return;
        if (gDateBelow && [gDates containsObject:self]) return;
    }
    %orig;
}

- (void)setText:(NSString *)text {
    %orig;
    if ([gClocks containsObject:self]) syncOverlay(self);
}

- (void)setAttributedText:(NSAttributedString *)text {
    %orig;
    if ([gClocks containsObject:self]) syncOverlay(self);
}

- (void)didMoveToWindow {
    %orig;
    if (self.window && [gClocks containsObject:self]) scheduleUnclip(self);
}

- (void)layoutSubviews {
    %orig;
    if (objc_getAssociatedObject(self, kIsOverlayKey)) return;
    if ([gClocks containsObject:self]) { syncOverlay(self); return; }
    if ([gDates containsObject:self]) return;

    NSString *t = self.text;
    if (!t || t.length < 3 || t.length > 48) return;

    if (t.length <= 8 && looksLikeTime(t)) {
        if (isLargeLabel(self) && !inStatusBar(self)) {
            [gClocks addObject:self];
            ensureOverlays(self);
            syncOverlay(self);
            [self setNeedsDisplay];
            scheduleUnclip(self);
        }
        return;
    }

    if (gEnabled && gDateBelow && looksLikeDate(t) && !inStatusBar(self)) {
        [gDates addObject:self];
        [self setNeedsDisplay];
    }
}
%end

%ctor {
    @autoreleasepool {
        NSString *bid = NSBundle.mainBundle.bundleIdentifier;
        if (![bid isEqualToString:@"com.apple.springboard"] &&
            ![bid isEqualToString:@"com.apple.PosterBoard"]) return;
        gClocks = [NSHashTable weakObjectsHashTable];
        gDates  = [NSHashTable weakObjectsHashTable];
        loadPrefs();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            prefsChanged, CFSTR("com.heanvoo.oldclock/reload"), NULL,
            CFNotificationSuspensionBehaviorCoalesce);
        %init;
    }
}
