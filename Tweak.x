// StretchClock 0.7.0 — безопасная версия.
// Масштаб/растяжение/сдвиг часов через transform (его не обрезают границы надписи)
// + перерисовка в повышенном разрешении (цифры остаются чёткими).
// НЕ меняет шрифт, границы и раскладку -> нет циклов раскладки и зависаний.
// Скрытие даты по совпадению текста с сегодняшней датой. Журнал отладки.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *const kDomain = @"com.stretchclock.tweak";
static NSString *const kLogPath = @"/var/mobile/StretchClock.log";
static const CGFloat kMinClockFont = 30.0;

static BOOL gEnabled = YES, gHideDate = NO, gDebug = NO, gScaleBroken = NO;
static CGFloat gSize = 1.2, gSX = 1.0, gSY = 1.0, gOX = 0, gOY = 0;
static NSHashTable *gClocks = nil, *gDates = nil;
static const void *kPendingKey = &kPendingKey;

#pragma mark - Настройки

static id readPref(NSString *key) {
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                       (__bridge CFStringRef)kDomain));
}

static void loadPrefs(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    id v;
    v = readPref(@"enabled");   gEnabled  = v ? [v boolValue] : YES;
    v = readPref(@"hideDate");  gHideDate = v ? [v boolValue] : NO;
    v = readPref(@"debug");     gDebug    = v ? [v boolValue] : NO;
    v = readPref(@"size");      gSize = v ? [v doubleValue] : 1.2;
    v = readPref(@"stretchX");  gSX   = v ? [v doubleValue] : 1.0;
    v = readPref(@"stretchY");  gSY   = v ? [v doubleValue] : 1.0;
    v = readPref(@"offsetX");   gOX   = v ? [v doubleValue] : 0;
    v = readPref(@"offsetY");   gOY   = v ? [v doubleValue] : 0;
    gScaleBroken = NO;
}

#pragma mark - Помощники

static UIFont *currentFont(UILabel *l) {
    if (l.attributedText.length > 0) {
        UIFont *f = [l.attributedText attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL];
        if (f) return f;
    }
    return l.font;
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

#pragma mark - Дата (по совпадению текста с сегодняшней датой)

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

static void setDateHidden(UILabel *l, BOOL hide) {
    if (l.hidden != hide) l.hidden = hide;
    CGFloat a = hide ? 0.0 : 1.0;
    if (l.alpha != a) l.alpha = a;
}

#pragma mark - Журнал отладки

static void logAppend(NSString *s) {
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
    if (!h) {
        [@"" writeToFile:kLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        h = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
    }
    [h seekToEndOfFile];
    [h writeData:[s dataUsingEncoding:NSUTF8StringEncoding]];
    [h closeFile];
}

static void dumpView(UIView *v, int depth, int maxDepth, NSMutableString *out) {
    if (out.length > 14000) return;
    NSString *indent = [@"" stringByPaddingToLength:(NSUInteger)depth * 2 withString:@" " startingAtIndex:0];
    NSString *extra = @"";
    if ([v isKindOfClass:[UILabel class]]) {
        UILabel *l = (UILabel *)v;
        extra = [NSString stringWithFormat:@" text='%@' font=%.1f", l.text ?: @"", currentFont(l).pointSize];
    }
    [out appendFormat:@"%@%@ frame=%@ clip=%d hidden=%d alpha=%.2f%@\n", indent, NSStringFromClass(v.class),
        NSStringFromCGRect(v.frame), v.clipsToBounds, v.hidden, v.alpha, extra];
    if (depth >= maxDepth) return;
    for (UIView *s in v.subviews) dumpView(s, depth + 1, maxDepth, out);
}

static void dumpAround(UIView *label) {
    if (!gDebug) return;
    UIView *top = label;
    for (int i = 0; i < 4 && top.superview; i++) top = top.superview;
    NSMutableString *out = [NSMutableString stringWithFormat:@"=== %@ %@ ===\n",
        NSProcessInfo.processInfo.processName, [NSDate date]];
    dumpView(top, 0, 5, out);
    logAppend(out);
}

#pragma mark - Применение к часам (только transform + чёткость)

static BOOL scaleBudgetOK(void) {
    static CFAbsoluteTime start = 0;
    static int count = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - start > 2.0) { start = now; count = 0; }
    if (++count > 30) { gScaleBroken = YES; return NO; }
    return YES;
}

static CGFloat targetScaleFactor(void) {
    CGFloat s = (gEnabled && !gScaleBroken) ? MAX(gSize * gSX, gSize * gSY) : 1.0;
    return UIScreen.mainScreen.scale * MAX(1.0, MIN(s, 3.0));
}

// Снять обрезку у контейнеров (кроме полноэкранных). Вызывается вне раскладки.
static void unclipAncestors(UIView *v) {
    CGSize scr = UIScreen.mainScreen.bounds.size;
    UIView *p = v.superview;
    for (int i = 0; p && i < 8; i++, p = p.superview) {
        if (p.bounds.size.width >= scr.width - 1 && p.bounds.size.height >= scr.height - 1) break;
        if (p.clipsToBounds) p.clipsToBounds = NO;
    }
}

// Тяжёлое — только асинхронно, не из layoutSubviews.
static void applyExtras(UILabel *l) {
    CGFloat target = targetScaleFactor();
    if (fabs(l.contentScaleFactor - target) > 0.01 && scaleBudgetOK()) l.contentScaleFactor = target;
    if (gEnabled) unclipAncestors(l);
}

static void scheduleExtras(UILabel *l) {
    if (objc_getAssociatedObject(l, kPendingKey)) return;
    objc_setAssociatedObject(l, kPendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UILabel *w = l;
    dispatch_async(dispatch_get_main_queue(), ^{
        UILabel *s = w;
        if (!s) return;
        objc_setAssociatedObject(s, kPendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        applyExtras(s);
    });
}

static void applyTo(UILabel *l) {
    CGAffineTransform tr = gEnabled
        ? CGAffineTransformMake(gSize * gSX, 0, 0, gSize * gSY, gOX, gOY)
        : CGAffineTransformIdentity;
    if (!CGAffineTransformEqualToTransform(l.transform, tr)) l.transform = tr;
    if (fabs(l.contentScaleFactor - targetScaleFactor()) > 0.01) scheduleExtras(l);
}

static void relayoutLabels(UIView *v, int depth) {
    if (depth > 24) return;
    if ([v isKindOfClass:[UILabel class]]) [v setNeedsLayout];
    for (UIView *s in v.subviews) relayoutLabels(s, depth + 1);
}

static void prefsChanged(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef u) {
    loadPrefs();
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UILabel *l in gClocks.allObjects) { applyTo(l); applyExtras(l); dumpAround(l); }
        for (UILabel *l in gDates.allObjects) setDateHidden(l, gEnabled && gHideDate);
        if (gEnabled && gHideDate) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            for (UIWindow *w in UIApplication.sharedApplication.windows) relayoutLabels(w, 0);
#pragma clang diagnostic pop
        }
    });
}

#pragma mark - Хук

%hook UILabel
- (void)layoutSubviews {
    %orig;
    if ([gClocks containsObject:self]) { applyTo(self); return; }
    if ([gDates containsObject:self]) { setDateHidden(self, gEnabled && gHideDate); return; }

    NSString *t = self.text;
    if (!t || t.length < 3 || t.length > 48) return;

    if (t.length <= 8 && looksLikeTime(t)) {
        if (isLargeLabel(self) && !inStatusBar(self)) {
            [gClocks addObject:self];
            applyTo(self);
            scheduleExtras(self);
            dumpAround(self);
        }
        return;
    }

    if (gHideDate && gEnabled && looksLikeDate(t) && !inStatusBar(self)) {
        [gDates addObject:self];
        setDateHidden(self, YES);
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
            prefsChanged, CFSTR("com.stretchclock.tweak/reload"), NULL,
            CFNotificationSuspensionBehaviorCoalesce);
        %init;
    }
}
