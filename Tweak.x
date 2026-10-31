// StretchClock 0.3.0 — минимальная и безопасная версия.
// Только transform (размер, растяжение, сдвиг) у крупных часов на локскрине.
// Часы в статус-баре (мелкий шрифт) не затрагиваются.

#import <UIKit/UIKit.h>

static NSString *const kDomain = @"com.stretchclock.tweak";

static BOOL gEnabled = YES;
static CGFloat gSize = 1.2, gSX = 1.0, gSY = 1.15, gOX = 0, gOY = 0;

static void loadPrefs(void) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kDomain];
    id v;
    v = [d objectForKey:@"enabled"];  gEnabled = v ? [v boolValue] : YES;
    v = [d objectForKey:@"size"];     gSize = v ? [v doubleValue] : 1.2;
    v = [d objectForKey:@"stretchX"]; gSX   = v ? [v doubleValue] : 1.0;
    v = [d objectForKey:@"stretchY"]; gSY   = v ? [v doubleValue] : 1.15;
    v = [d objectForKey:@"offsetX"];  gOX   = v ? [v doubleValue] : 0;
    v = [d objectForKey:@"offsetY"];  gOY   = v ? [v doubleValue] : 0;
}

static void prefsChanged(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef u) {
    loadPrefs();
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

%hook UILabel
- (void)layoutSubviews {
    %orig;
    NSString *t = self.text;
    if (!t || t.length < 3 || t.length > 8) return;
    if (self.font.pointSize < 30.0) return;      // статус-бар и мелкие надписи пропускаем
    if (!looksLikeTime(t)) return;
    CGAffineTransform tr = gEnabled
        ? CGAffineTransformMake(gSize * gSX, 0, 0, gSize * gSY, gOX, gOY)
        : CGAffineTransformIdentity;
    if (!CGAffineTransformEqualToTransform(self.transform, tr)) self.transform = tr;
}
%end

%ctor {
    @autoreleasepool {
        NSString *bid = NSBundle.mainBundle.bundleIdentifier;
        if (![bid isEqualToString:@"com.apple.springboard"] &&
            ![bid isEqualToString:@"com.apple.PosterBoard"]) return;
        loadPrefs();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            prefsChanged, CFSTR("com.stretchclock.tweak/reload"), NULL,
            CFNotificationSuspensionBehaviorCoalesce);
        %init;
    }
}
