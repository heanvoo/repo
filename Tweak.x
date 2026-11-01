// StretchClock 0.5.0 — «настоящее» масштабирование часов на экране блокировки.
// Режим "реальный шрифт": меняется сам шрифт часов (размер + растяжение глифов по X/Y
// через матрицу шрифта), текст остаётся чётким, а размер надписи пересчитывается.
// Режим "transform": старый вариант (растяжение картинки).
// Часы в статус-баре (у чёлки) не затрагиваются.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *const kDomain = @"com.stretchclock.tweak";
static const CGFloat kMinClockFont = 30.0;

static BOOL gEnabled = YES, gRealFont = YES, gHideDate = NO, gFontBroken = NO;
static CGFloat gSize = 1.2, gSX = 1.0, gSY = 1.0, gOX = 0, gOY = 0;
static NSHashTable *gClocks = nil, *gDates = nil;

static const void *kOrigKey = &kOrigKey;
static const void *kAppliedKey = &kAppliedKey;
static const void *kSigKey = &kSigKey;

#pragma mark - Настройки

static id readPref(NSString *key) {
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                       (__bridge CFStringRef)kDomain));
}

static void loadPrefs(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    id v;
    v = readPref(@"enabled");   gEnabled  = v ? [v boolValue] : YES;
    v = readPref(@"realFont");  gRealFont = v ? [v boolValue] : YES;
    v = readPref(@"hideDate");  gHideDate = v ? [v boolValue] : NO;
    v = readPref(@"size");      gSize = v ? [v doubleValue] : 1.2;
    v = readPref(@"stretchX");  gSX   = v ? [v doubleValue] : 1.0;
    v = readPref(@"stretchY");  gSY   = v ? [v doubleValue] : 1.0;
    v = readPref(@"offsetX");   gOX   = v ? [v doubleValue] : 0;
    v = readPref(@"offsetY");   gOY   = v ? [v doubleValue] : 0;
    gFontBroken = NO;
}

#pragma mark - Помощники

static UIFont *currentFont(UILabel *l) {
    if (l.attributedText.length > 0) {
        UIFont *f = [l.attributedText attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL];
        if (f) return f;
    }
    return l.font;
}

static BOOL sameFont(UIFont *a, UIFont *b) {
    return a && b && [a.fontName isEqualToString:b.fontName] && fabs(a.pointSize - b.pointSize) < 0.01;
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

// Защита от бесконечного цикла «мы ставим шрифт — система сбрасывает».
static BOOL fontBudgetOK(void) {
    static CFAbsoluteTime start = 0;
    static int count = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - start > 2.0) { start = now; count = 0; }
    if (++count > 20) { gFontBroken = YES; return NO; }
    return YES;
}

#pragma mark - Применение к часам

static void applyFontScale(UILabel *l, CGFloat size, CGFloat sx, CGFloat sy) {
    UIFont *cur = currentFont(l);
    UIFont *orig = objc_getAssociatedObject(l, kOrigKey);
    UIFont *applied = objc_getAssociatedObject(l, kAppliedKey);
    NSString *oldSig = objc_getAssociatedObject(l, kSigKey);

    if (!orig || !sameFont(cur, applied)) {      // первый раз или система сменила шрифт
        orig = cur;
        applied = cur;
        oldSig = nil;
        objc_setAssociatedObject(l, kOrigKey, orig, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(l, kAppliedKey, applied, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(l, kSigKey, @"orig", OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        oldSig = @"orig";
    }

    NSString *sig = [NSString stringWithFormat:@"%.3f|%.3f|%.3f", size, sx, sy];
    BOOL identity = (size == 1.0 && sx == 1.0 && sy == 1.0);
    if (identity && [oldSig isEqualToString:@"orig"]) return;
    if ([sig isEqualToString:oldSig]) return;

    UIFont *target = orig;
    if (!identity) {
        CGFloat ps = MIN(MAX(orig.pointSize * size, 4.0), 400.0);
        UIFontDescriptor *d = [orig.fontDescriptor fontDescriptorWithSize:ps];
        d = [d fontDescriptorWithMatrix:CGAffineTransformMakeScale(sx, sy)];
        UIFont *f = [UIFont fontWithDescriptor:d size:0];
        if (f) target = f;
    }
    if (!fontBudgetOK()) return;

    objc_setAssociatedObject(l, kAppliedKey, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(l, kSigKey, identity ? @"orig" : sig, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (l.attributedText.length > 0) {
        NSMutableAttributedString *m = [l.attributedText mutableCopy];
        [m addAttribute:NSFontAttributeName value:target range:NSMakeRange(0, m.length)];
        l.attributedText = m;
    } else {
        l.font = target;
    }
    l.adjustsFontSizeToFitWidth = NO;

    // пересчитать размер надписи под новый шрифт, не двигая центр
    CGSize need = [l sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)];
    CGRect b = l.bounds;
    if (need.width > b.size.width + 0.5 || need.height > b.size.height + 0.5) {
        CGPoint c = l.center;
        b.size.width = MAX(b.size.width, ceil(need.width));
        b.size.height = MAX(b.size.height, ceil(need.height));
        l.bounds = b;
        l.center = c;
    }
}

static void applyTo(UILabel *l) {
    BOOL useFont = gEnabled && gRealFont && !gFontBroken;
    applyFontScale(l, useFont ? gSize : 1.0, useFont ? gSX : 1.0, useFont ? gSY : 1.0);

    CGAffineTransform tr;
    if (!gEnabled)      tr = CGAffineTransformIdentity;
    else if (useFont)   tr = CGAffineTransformMakeTranslation(gOX, gOY);
    else                tr = CGAffineTransformMake(gSize * gSX, 0, 0, gSize * gSY, gOX, gOY);
    if (!CGAffineTransformEqualToTransform(l.transform, tr)) l.transform = tr;
}

static void prefsChanged(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef u) {
    loadPrefs();
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UILabel *l in gClocks.allObjects) applyTo(l);
        for (UILabel *l in gDates.allObjects) l.hidden = (gEnabled && gHideDate);
    });
}

#pragma mark - Хук

%hook UILabel
- (void)layoutSubviews {
    %orig;
    if ([gClocks containsObject:self]) { applyTo(self); return; }
    if ([gDates containsObject:self]) { if (gEnabled && gHideDate) self.hidden = YES; return; }

    NSString *t = self.text;
    if (!t || t.length < 3 || t.length > 40) return;

    if (t.length <= 8 && looksLikeTime(t)) {
        if (isLargeLabel(self) && !inStatusBar(self)) {
            [gClocks addObject:self];
            UIView *p = self.superview;               // чтобы увеличенные часы не обрезались
            for (int i = 0; p && i < 2; i++, p = p.superview) p.clipsToBounds = NO;
            applyTo(self);
        }
        return;
    }

    // Дата: ищем только если включено скрытие (чтобы не нагружать систему)
    if (gHideDate && gEnabled && t.length >= 4 && currentFont(self).pointSize < kMinClockFont
        && chainContains(self, @"Date", 8) && !inStatusBar(self)) {
        [gDates addObject:self];
        self.hidden = YES;
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
