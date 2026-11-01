// StretchClock 0.8.0 — «свои цифры» вместо деформации системных.
// Системная надпись с временем больше НЕ рисует текст (drawTextInRect пропускается),
// а внутри неё (как подвид) добавляется наш UILabel с тем же текстом, но с нашим шрифтом:
// размер, растяжение по X/Y (матрица шрифта) и сдвиг. Мы не трогаем ни layout, ни transform,
// ни bounds системной надписи -> система не может это сбросить, нет циклов раскладки.
// Дата: надпись с сегодняшней датой перестаёт рисоваться.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *const kDomain = @"com.stretchclock.tweak";
static NSString *const kLogPath = @"/var/mobile/StretchClock.log";
static const CGFloat kMinClockFont = 30.0;

static BOOL gEnabled = YES, gHideDate = NO, gDebug = NO, gBroken = NO;
static CGFloat gSize = 1.2, gSX = 1.0, gSY = 1.0, gOX = 0, gOY = 0;
static NSHashTable *gClocks = nil, *gDates = nil;

static const void *kOvKey = &kOvKey;          // на системной надписи: наш оверлей
static const void *kIsOverlayKey = &kIsOverlayKey; // на оверлее: пометка
static const void *kSigKey = &kSigKey;        // на оверлее: подпись шрифта
static const void *kFontKey = &kFontKey;      // на оверлее: кэш шрифта

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
    gBroken = NO;
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

#pragma mark - Дата

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

#pragma mark - Наш оверлей

static BOOL syncBudgetOK(void) {
    static CFAbsoluteTime start = 0;
    static int count = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - start > 1.0) { start = now; count = 0; }
    if (++count > 80) { gBroken = YES; return NO; }   // аварийный выключатель
    return YES;
}

static UILabel *ensureOverlay(UILabel *l) {
    UILabel *ov = objc_getAssociatedObject(l, kOvKey);
    if (ov) return ov;
    ov = [[UILabel alloc] initWithFrame:CGRectZero];
    objc_setAssociatedObject(ov, kIsOverlayKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ov.userInteractionEnabled = NO;
    ov.backgroundColor = UIColor.clearColor;
    ov.numberOfLines = 1;
    ov.adjustsFontSizeToFitWidth = NO;
    ov.lineBreakMode = NSLineBreakByClipping;
    ov.clipsToBounds = NO;
    [l addSubview:ov];
    objc_setAssociatedObject(l, kOvKey, ov, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return ov;
}

static UIFont *scaledFont(UIFont *base) {
    CGFloat ps = MIN(MAX(base.pointSize * gSize, 4.0), 800.0);
    UIFontDescriptor *d = [base.fontDescriptor fontDescriptorWithSize:ps];
    if (gSX != 1.0 || gSY != 1.0) d = [d fontDescriptorWithMatrix:CGAffineTransformMakeScale(gSX, gSY)];
    UIFont *f = [UIFont fontWithDescriptor:d size:0];
    return f ?: [base fontWithSize:ps];
}

static void syncOverlay(UILabel *l) {
    UILabel *ov = objc_getAssociatedObject(l, kOvKey);
    if (!ov) return;

    BOOL active = gEnabled && !gBroken;
    if (ov.hidden == active) ov.hidden = !active;
    if (!active) return;
    if (!syncBudgetOK()) { ov.hidden = YES; [l setNeedsDisplay]; return; }

    UIFont *base = currentFont(l);
    NSString *txt = l.text ?: @"";

    NSString *sig = [NSString stringWithFormat:@"%@|%.2f|%.3f|%.3f|%.3f", base.fontName, base.pointSize, gSize, gSX, gSY];
    UIFont *f = objc_getAssociatedObject(ov, kFontKey);
    if (!f || ![sig isEqualToString:objc_getAssociatedObject(ov, kSigKey)]) {
        f = scaledFont(base);
        objc_setAssociatedObject(ov, kFontKey, f, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(ov, kSigKey, sig, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (l.attributedText.length > 0) {
        NSMutableAttributedString *m = [l.attributedText mutableCopy];
        [m addAttribute:NSFontAttributeName value:f range:NSMakeRange(0, m.length)];
        if (![ov.attributedText isEqualToAttributedString:m]) ov.attributedText = m;
    } else {
        if (![ov.text isEqualToString:txt]) ov.text = txt;
        if (ov.font != f) ov.font = f;
        UIColor *c = l.textColor;
        if (c && ![ov.textColor isEqual:c]) ov.textColor = c;
    }

    // Границы оверлея задаём сами и с запасом — обрезки нет, система их не трогает.
    CGSize bs = [txt sizeWithAttributes:@{NSFontAttributeName: base}];
    CGFloat w = ceil(bs.width * gSize * gSX * 1.2) + 24.0;
    CGFloat h = ceil(base.lineHeight * gSize * gSY * 1.3) + 12.0;
    CGRect lb = l.bounds;
    CGFloat cx = CGRectGetMidX(lb);
    NSTextAlignment al = NSTextAlignmentCenter;
    if (lb.size.width > bs.width + 8.0) {
        if (l.textAlignment == NSTextAlignmentLeft || l.textAlignment == NSTextAlignmentNatural) {
            al = NSTextAlignmentLeft;  cx = CGRectGetMinX(lb) + w / 2.0;
        } else if (l.textAlignment == NSTextAlignmentRight) {
            al = NSTextAlignmentRight; cx = CGRectGetMaxX(lb) - w / 2.0;
        }
    }
    if (ov.textAlignment != al) ov.textAlignment = al;

    CGRect nb = CGRectMake(0, 0, w, h);
    if (!CGRectEqualToRect(ov.bounds, nb)) ov.bounds = nb;
    CGPoint nc = CGPointMake(cx, CGRectGetMidY(lb));
    if (!CGPointEqualToPoint(ov.center, nc)) ov.center = nc;
    CGAffineTransform tr = CGAffineTransformMakeTranslation(gOX, gOY);
    if (!CGAffineTransformEqualToTransform(ov.transform, tr)) ov.transform = tr;
}

// Снять обрезку у самой надписи и контейнеров (кроме полноэкранных). Только вне раскладки.
static void unclipChain(UIView *v) {
    CGSize scr = UIScreen.mainScreen.bounds.size;
    UIView *p = v;
    for (int i = 0; p && i < 9; i++, p = p.superview) {
        if (i > 0 && p.bounds.size.width >= scr.width - 1 && p.bounds.size.height >= scr.height - 1) break;
        if (p.clipsToBounds) p.clipsToBounds = NO;
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
            [l setNeedsDisplay];       // перерисовать (показать/скрыть собственный текст надписи)
            unclipChain(l);
            dumpAround(l);
        }
        for (UILabel *l in gDates.allObjects) [l setNeedsDisplay];
        if (gEnabled && gHideDate) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            for (UIWindow *w in UIApplication.sharedApplication.windows) relayoutLabels(w, 0);
#pragma clang diagnostic pop
        }
    });
}

#pragma mark - Хуки

%hook UILabel

// Системные часы/дата не рисуют свой текст — его рисует наш оверлей / он скрыт.
- (void)drawTextInRect:(CGRect)rect {
    if (gEnabled && !gBroken) {
        if ([gClocks containsObject:self]) return;
        if (gHideDate && [gDates containsObject:self]) return;
    } else if (gEnabled && gBroken && gHideDate && [gDates containsObject:self]) {
        return;
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

- (void)layoutSubviews {
    %orig;
    if (objc_getAssociatedObject(self, kIsOverlayKey)) return;       // наш оверлей не трогаем
    if ([gClocks containsObject:self]) { syncOverlay(self); return; }
    if ([gDates containsObject:self]) return;

    NSString *t = self.text;
    if (!t || t.length < 3 || t.length > 48) return;

    if (t.length <= 8 && looksLikeTime(t)) {
        if (isLargeLabel(self) && !inStatusBar(self)) {
            [gClocks addObject:self];
            ensureOverlay(self);
            syncOverlay(self);
            [self setNeedsDisplay];
            scheduleUnclip(self);
            dumpAround(self);
        }
        return;
    }

    if (gHideDate && gEnabled && looksLikeDate(t) && !inStatusBar(self)) {
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
            prefsChanged, CFSTR("com.stretchclock.tweak/reload"), NULL,
            CFNotificationSuspensionBehaviorCoalesce);
        %init;
    }
}
