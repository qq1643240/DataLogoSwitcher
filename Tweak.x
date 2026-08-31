#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CoreText/CoreText.h>
#import <version.h>
#import <rootless.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>

#define SettingsPath @"/var/mobile/Library/Preferences/tw.hiraku.datalogoswitcher.plist"
#define DLSPreferencesID CFSTR("tw.hiraku.datalogoswitcher")

static NSDictionary *DLSSettings(void)
{
    NSDictionary *settings = [NSDictionary dictionaryWithContentsOfFile:SettingsPath];
    return settings ?: @{};
}

static NSString *DLSRewriteStatusText(NSString *text)
{
    if (![text isKindOfClass:NSString.class] || text.length == 0) return nil;
    NSDictionary *settings = DLSSettings();

    NSSet *fiveG = [NSSet setWithObjects:@"5G", @"5G+", @"5G Plus", @"5G UC", @"5G UW", @"5G UWB", @"5GE", @"5GA", @"5G-A", @"5G A", nil];
    if ([fiveG containsObject:text]) {
        NSInteger value = [settings[@"5G"] integerValue];
        NSString *custom = settings[@"custom5GString"];
        if (value == 5) return @"5Gᴀ";
        if (value == 99 && custom.length > 0 && ![custom isEqualToString:text]) return custom;
    }

    NSSet *fourG = [NSSet setWithObjects:@"4G", @"4G+", @"LTE", @"LTE+", @"LTE-A", @"5GE", nil];
    if ([fourG containsObject:text]) {
        NSInteger value = [settings[@"4G"] integerValue];
        if (value == 4) return @"4G+";
        if (value == 10) return @"4Gᴀ";
        if (value == 99 && [settings[@"custom4GString"] length] > 0) return settings[@"custom4GString"];
    }

    NSSet *threeG = [NSSet setWithObjects:@"3G", @"H", @"H+", nil];
    if ([threeG containsObject:text] && [settings[@"3G"] integerValue] == 99 && [settings[@"custom3GString"] length] > 0) {
        return settings[@"custom3GString"];
    }
    return nil;
}

static BOOL DLSUsesSystemStatusUI(void)
{
    return NSClassFromString(@"STUIStatusBarStringView") != nil;
}

static UIFont *DLSRegularGlyphFont(UIFont *nativeSuffixFont)
{
    if (nativeSuffixFont == nil) return nil;

    // The native compact '+' font is a status-bar subset font. It often has
    // no U+1D00, so changing its descriptor weight still triggers a heavy
    // fallback. Select a true Regular system font that contains ᴀ, keeping
    // the native compact run's exact point size and other attributes intact.
    CGFloat size = nativeSuffixFont.pointSize;
    NSArray<UIFont *> *candidates = @[
        [UIFont fontWithName:@".SFUI-Regular" size:size],
        [UIFont fontWithName:@"SFProText-Regular" size:size],
        [UIFont fontWithName:@"HelveticaNeue" size:size],
        [UIFont fontWithName:@"HelveticaNeue-Regular" size:size],
        [UIFont systemFontOfSize:size weight:UIFontWeightRegular]
    ];
    unichar character = 0x1D00; // LATIN LETTER SMALL CAPITAL A (ᴀ)
    for (UIFont *candidate in candidates) {
        if (candidate == nil) continue;
        CGGlyph glyph = 0;
        CTFontRef font = (__bridge CTFontRef)candidate;
        if (CTFontGetGlyphsForCharacters(font, &character, &glyph, 1) && glyph != 0) {
            return candidate;
        }
    }
    return [UIFont systemFontOfSize:size weight:UIFontWeightRegular];
}

static __thread BOOL DLSApplyingText;

static NSDictionary *DLSCompactSuffixAttributes(NSDictionary *baseAttributes)
{
    NSMutableDictionary *attributes = [baseAttributes mutableCopy] ?: [NSMutableDictionary dictionary];
    UIFont *font = attributes[NSFontAttributeName];
    if (font != nil) {
        // Match the native compact suffix used by the working 5Gᴀ path.
        attributes[NSFontAttributeName] = [UIFont fontWithDescriptor:font.fontDescriptor
                                                                  size:MAX(1.0, font.pointSize * 0.58)];
    }
    [attributes removeObjectForKey:NSBaselineOffsetAttributeName];
    return attributes;
}

static NSAttributedString *DLSAttributedReplacement(NSAttributedString *source, NSString *replacement)
{
    if (replacement.length == 0) return source;

    NSMutableAttributedString *updated = [[NSMutableAttributedString alloc] initWithString:replacement];
    if (source.length == 0) return updated;

    NSRange prefixRange = NSMakeRange(0, 0);
    NSDictionary *prefixAttributes = [source attributesAtIndex:0 effectiveRange:&prefixRange] ?: @{};
    BOOL compactSuffix = [replacement hasPrefix:@"5G"] || [replacement hasPrefix:@"4G+"] || [replacement hasPrefix:@"4Gᴀ"];
    if (!compactSuffix) {
        [updated setAttributes:prefixAttributes range:NSMakeRange(0, replacement.length)];
        return updated;
    }

    NSUInteger prefixLength = MIN((NSUInteger)replacement.length, (NSUInteger)2);
    [updated setAttributes:prefixAttributes range:NSMakeRange(0, prefixLength)];

    // SystemStatusUI gives native 5G+/5G UC a separate compact suffix run.
    // Keep its size, color, kerning and baseline; only ᴀ receives a glyph
    // font with verified U+1D00 coverage so CoreText cannot fall back bold.
    NSDictionary *nativeSuffix = [source attributesAtIndex:source.length - 1 effectiveRange:NULL];
    NSMutableDictionary *suffixAttributes = [nativeSuffix mutableCopy];
    if (suffixAttributes == nil) suffixAttributes = [DLSCompactSuffixAttributes(prefixAttributes) mutableCopy];
    if ([replacement hasSuffix:@"ᴀ"]) {
        UIFont *nativeFont = suffixAttributes[NSFontAttributeName];
        UIFont *regularFont = DLSRegularGlyphFont(nativeFont);
        if (regularFont != nil) suffixAttributes[NSFontAttributeName] = regularFont;
    }
    if (replacement.length > prefixLength) {
        [updated setAttributes:suffixAttributes range:NSMakeRange(prefixLength, replacement.length - prefixLength)];
    }
    return updated;
}

static NSAttributedString *DLSFallbackAttributedText(id object, NSString *replacement)
{
    UIFont *font = nil;
    if ([object respondsToSelector:@selector(font)]) {
        font = ((id (*)(id, SEL))objc_msgSend)(object, @selector(font));
    }
    if (font == nil) font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular];
    UIColor *color = nil;
    if ([object respondsToSelector:@selector(textColor)]) {
        color = ((id (*)(id, SEL))objc_msgSend)(object, @selector(textColor));
    }

    NSMutableDictionary *prefix = [NSMutableDictionary dictionaryWithObject:font forKey:NSFontAttributeName];
    if (color != nil) prefix[NSForegroundColorAttributeName] = color;

    NSMutableAttributedString *result = [[NSMutableAttributedString alloc] initWithString:replacement attributes:prefix];
    BOOL compact = replacement.length > 2 && ([replacement hasPrefix:@"5G"] || [replacement hasPrefix:@"4G+"] || [replacement hasPrefix:@"4Gᴀ"]);
    if (compact) {
        NSMutableDictionary *suffix = [DLSCompactSuffixAttributes(prefix) mutableCopy];
        if ([replacement hasSuffix:@"ᴀ"]) {
            UIFont *regular = DLSRegularGlyphFont(suffix[NSFontAttributeName]);
            if (regular != nil) suffix[NSFontAttributeName] = regular;
        }
        [result setAttributes:suffix range:NSMakeRange(2, replacement.length - 2)];
    }
    return result;
}

static BOOL DLSIsStatusBarObject(id object)
{
    id current = object;
    for (NSUInteger depth = 0; current != nil && depth < 10; depth++) {
        NSString *name = NSStringFromClass(object_getClass(current));
        if ([name rangeOfString:@"StatusBar" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [name rangeOfString:@"STUI" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [name rangeOfString:@"Cellular" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
        current = [current respondsToSelector:@selector(superview)] ? [current superview] : nil;
    }
    return NO;
}

// iOS 17 moved the visible carrier text into SystemStatusUI.
%group GiOS17
%hook STUIStatusBarStringView
- (void)setText:(NSString *)text {
    if (DLSApplyingText) {
        %orig(text);
        return;
    }
    // Some iOS 17 status views never call setAttributedText:. Commit an
    // explicit attributed replacement so the private status font cannot turn
    // ᴀ into '?' and the host label cannot overwrite custom text.
    NSString *replacement = DLSRewriteStatusText(text);
    if (replacement.length > 0) {
        DLSApplyingText = YES;
        ((void (*)(id, SEL, NSAttributedString *))objc_msgSend)(self, @selector(setAttributedText:), DLSFallbackAttributedText(self, replacement));
        DLSApplyingText = NO;
        return;
    }
    %orig(text);
}
- (void)setAttributedText:(NSAttributedString *)text {
    if (DLSApplyingText) {
        %orig(text);
        return;
    }
    NSString *replacement = DLSRewriteStatusText(text.string);
    %orig(replacement.length > 0 ? DLSAttributedReplacement(text, replacement) : text);
}
%end

// Some iOS 17 builds use a UILabel subclass for the final rendered text.
%hook UILabel
- (void)setText:(NSString *)text {
    if (DLSApplyingText) {
        %orig(text);
        return;
    }
    // UILabel is the final renderer on some iOS 17 builds. Use an attributed
    // string here too so 4Gᴀ/5Gᴀ has a font with a verified ᴀ glyph.
    if (DLSIsStatusBarObject(self)) {
        NSString *replacement = DLSRewriteStatusText(text);
        if (replacement.length > 0) {
            DLSApplyingText = YES;
            [self setAttributedText:DLSFallbackAttributedText(self, replacement)];
            DLSApplyingText = NO;
            return;
        }
    }
    %orig(text);
}
- (void)setAttributedText:(NSAttributedString *)text {
    if (DLSIsStatusBarObject(self)) {
        if (DLSApplyingText) {
            %orig(text);
            return;
        }
        NSString *replacement = DLSRewriteStatusText(text.string);
        if (replacement.length > 0) {
            %orig(DLSAttributedReplacement(text, replacement));
            return;
        }
    }
    %orig(text);
}
%end
%end

//Before iOS 12.2

//Before iOS 12.2
typedef NS_ENUM(NSInteger, connectionType) {
    ConnectionNone          = 0,
    Connection1x            = 1,
    ConnectionGprs          = 2,
    ConnectionEdge          = 3,
    ConnectionUmts          = 4,
    ConnectionHsdpa         = 5,
    Connection4GOverride    = 6,
    ConnectionLte           = 7,
    ConnectionBluetooth     = 8,
    ConnectionWifi          = 9,
    ConnectionOther         = 10
};

//After iOS 12.2
typedef NS_ENUM(NSInteger, newConnectionType) {
    NewConnectionNone       = 0,
    NewConnection1x         = 1,
    NewConnectionGprs       = 2,
    NewConnectionEdge       = 3,
    NewConnectionUmts       = 4,
    NewConnectionHsdpa      = 5,
    NewConnection4GOverride = 6,
    NewConnectionLte        = 7,
    NewConnectionLteA       = 8,
    NewConnectionLtePlus    = 9,
    NewConnection5GE        = 10,
    NewConnection5G         = 11,
    NewConnection5GPlus     = 12,
    NewConnection5GUWB      = 13,
    NewConnection5GUC       = 14,
    NewConnectionBluetooth  = 15,
    // NewConnectionBluetooth  = 11,
    // NewConnectionWifi       = 12,
    // NewConnectionOther      = 13
};

// //After iOS 14
// typedef NS_ENUM(NSInteger, newConnectionType) {
//     NewConnectionNone       = 0,
//     NewConnection1x         = 1,
//     NewConnectionGprs       = 2,
//     NewConnectionEdge       = 3,
//     NewConnectionUmts       = 4,
//     NewConnectionHsdpa      = 5,
//     NewConnection4GOverride = 6,
//     NewConnectionLte        = 7,
//     NewConnectionLteA       = 8,
//     NewConnectionLtePlus    = 9,
//     NewConnection5GE        = 10,
//     NewConnection5G         = 11,
//     NewConnection5GPlus     = 12,
//     NewConnection5GUWB      = 13,
//     NewConnectionBluetooth  = 14,
//     NewConnectionWifi       = 15,
//     NewConnectionOther      = 16
// };

%group GiOS13
%hook STTelephonySubscriptionContext
- (int)modemDataConnectionType
{
    int connectionType = %orig;

    NSDictionary *defaults = DLSSettings();
    if (connectionType == NewConnectionUmts ||
        connectionType == NewConnectionHsdpa)
    {
        switch([defaults[@"3G"] intValue])
        {
            case 0:
                return connectionType;
            case 1:
                return NewConnection4GOverride;
            case 2:
                return NewConnectionLte;
            case 3:
                return NewConnectionLteA;
            case 4:
                return NewConnectionLtePlus;
            case 10:
                return NewConnectionLtePlus;
            case 5:
                return NewConnection5GE;
            case 6:
                return NewConnection5G;
            case 7:
                return NewConnection5GPlus;
            case 8:
                return NewConnection5GUWB;
            case 9:
                return NewConnection5GUC;
            default:
                break;
        }
    }

    if (connectionType == NewConnection4GOverride ||
        connectionType == NewConnectionLte ||
        connectionType == NewConnectionLteA ||
        connectionType == NewConnectionLtePlus ||
        connectionType == NewConnection5GE)
    {
        switch([defaults[@"4G"] intValue])
        {
            case 0:
                return connectionType;
            case 1:
                return NewConnection4GOverride;
            case 2:
                return NewConnectionLte;
            case 3:
                return NewConnectionLteA;
            case 4:
                // Keep the real 4G host. Some iOS 17 SystemStatusUI builds
                // do not render the private LTE+ enum and show '?'.
                return connectionType;
            case 10:
                // 4Gᴀ is rendered in the final text layer on this 4G host.
                return connectionType;
            case 5:
                return NewConnection5GE;
            case 6:
                return NewConnection5G;
            case 7:
                return NewConnection5GPlus;
            case 8:
                return NewConnection5GUWB;
            case 9:
                return NewConnection5GUC;
            default:
                break;
        }
    }

    if (connectionType == NewConnection5G ||
        connectionType == NewConnection5GPlus ||
        connectionType == NewConnection5GUWB ||
        (kCFCoreFoundationVersionNumber >= kCFCoreFoundationVersionNumber_iOS_15_0 && connectionType == NewConnection5GUC))
    {
        switch([defaults[@"5G"] intValue])
        {
            case 0:
                return connectionType;
            case 1:
                return NewConnection5G;
            case 2:
                return NewConnection5GPlus;
            case 3:
                return NewConnection5GUWB;
            case 4:
                return NewConnection5GUC;
            case 5:
                // Keep the actual 5G-family host; iOS 17 rewrites the final
                // glyphs to 5Gᴀ with a font that contains U+1D00.
                return connectionType;
            case 99:
                // Custom 5G text must not force the status bar into 5G+.
                return connectionType;
        }
    }

    return connectionType;
}
%end

%hook STTelephonyCarrierBundleInfo
- (BOOL)LTEConnectionShows4G {
    return NO;
}
%end

%hook _UIStatusBarCellularItem
- (NSString *)_stringForCellularType:(int)connectionType {
    NSDictionary *defaults = DLSSettings();

    if ((connectionType == NewConnectionUmts || connectionType == NewConnectionHsdpa) &&
        [defaults[@"3G"] intValue] == 99) {
        return defaults[@"custom3GString"] ? defaults[@"custom3GString"] : @"3G";
    }

    if ((connectionType == NewConnection4GOverride ||
        connectionType == NewConnectionLte ||
        connectionType == NewConnectionLteA ||
        connectionType == NewConnectionLtePlus ||
        connectionType == NewConnection5GE) &&
        [defaults[@"4G"] intValue] == 99) {
        return defaults[@"custom4GString"] ? defaults[@"custom4GString"] : @"4G";
    }

    if ((connectionType == NewConnection4GOverride ||
        connectionType == NewConnectionLte ||
        connectionType == NewConnectionLteA ||
        connectionType == NewConnectionLtePlus ||
        connectionType == NewConnection5GE) &&
        [defaults[@"4G"] intValue] == 4) {
        if (!DLSUsesSystemStatusUI()) return @"4G+";
    }

    if ((connectionType == NewConnection4GOverride ||
        connectionType == NewConnectionLte ||
        connectionType == NewConnectionLteA ||
        connectionType == NewConnectionLtePlus ||
        connectionType == NewConnection5GE) &&
        [defaults[@"4G"] intValue] == 10) {
        if (!DLSUsesSystemStatusUI()) return @"4Gᴀ";
    }

    if ((connectionType == NewConnection5G ||
        connectionType == NewConnection5GPlus ||
        connectionType == NewConnection5GUWB ||
        (kCFCoreFoundationVersionNumber >= kCFCoreFoundationVersionNumber_iOS_15_0 && connectionType == NewConnection5GUC)) &&
        [defaults[@"5G"] intValue] == 5) {
        if (!DLSUsesSystemStatusUI()) return @"5Gᴀ";
    }

    if ((connectionType == NewConnection5G ||
        connectionType == NewConnection5GPlus ||
        connectionType == NewConnection5GUWB ||
        (kCFCoreFoundationVersionNumber >= kCFCoreFoundationVersionNumber_iOS_15_0 && connectionType == NewConnection5GUC)) &&
        [defaults[@"5G"] intValue] == 99) {
        return defaults[@"custom5GString"] ? defaults[@"custom5GString"] : @"5G";
    }

    return %orig;
}
%end
%end

%group GiOS12_2
%hook SBTelephonySubscriptionContext
- (int)modemDataConnectionType
{
    int connectionType = %orig;

    NSDictionary *defaults = DLSSettings();
    if (connectionType == NewConnectionUmts || connectionType == NewConnectionHsdpa)
    {
        switch([defaults[@"3G"] intValue])
        {
            case 0:
                return connectionType;
            case 1:
                return NewConnection4GOverride;
            case 2:
                return NewConnectionLte;
            case 3:
                return NewConnectionLteA;
            case 4:
                return NewConnectionLtePlus;
            case 10:
                return NewConnectionLtePlus;
            case 5:
                return NewConnection5GE;
            default:
                break;
        }
    }

    if (connectionType == NewConnection4GOverride ||
        connectionType == NewConnectionLte ||
        connectionType == NewConnectionLteA ||
        connectionType == NewConnectionLtePlus ||
        connectionType == NewConnection5GE)
    {
        switch([defaults[@"4G"] intValue])
        {
            case 0:
                return connectionType;
            case 1:
                return NewConnection4GOverride;
            case 2:
                return NewConnectionLte;
            case 3:
                return NewConnectionLteA;
            case 4:
                return NewConnectionLtePlus;
            case 5:
                return NewConnection5GE;
            default:
                break;
        }
    }

    return connectionType;
}
%end

%hook _UIStatusBarCellularItem
- (NSString *)_stringForCellularType:(int)connectionType {
    NSDictionary *defaults = DLSSettings();

    if ((connectionType == NewConnectionUmts || connectionType == NewConnectionHsdpa) &&
        [defaults[@"3G"] intValue] == 99) {
        return defaults[@"custom3GString"] ? defaults[@"custom3GString"] : @"3G";
    }

    if ((connectionType == NewConnection4GOverride ||
        connectionType == NewConnectionLte ||
        connectionType == NewConnectionLteA ||
        connectionType == NewConnectionLtePlus ||
        connectionType == NewConnection5GE) &&
        [defaults[@"4G"] intValue] == 99) {
        return defaults[@"custom4GString"] ? defaults[@"custom4GString"] : @"4G";
    }

    if ((connectionType == NewConnection4GOverride ||
        connectionType == NewConnectionLte ||
        connectionType == NewConnectionLteA ||
        connectionType == NewConnectionLtePlus ||
        connectionType == NewConnection5GE) &&
        [defaults[@"4G"] intValue] == 4) {
        return @"4G+";
    }

    if ((connectionType == NewConnection4GOverride ||
        connectionType == NewConnectionLte ||
        connectionType == NewConnectionLteA ||
        connectionType == NewConnectionLtePlus ||
        connectionType == NewConnection5GE) &&
        [defaults[@"4G"] intValue] == 10) {
        return @"4Gᴀ";
    }

    return %orig;
}
%end
%end


%group GiOS12_1
%hook SBTelephonySubscriptionContext
- (int)modemDataConnectionType
{
    int connectionType = %orig;

    NSDictionary *defaults = DLSSettings();
    if (connectionType == ConnectionUmts || connectionType == ConnectionHsdpa)
    {
        switch([defaults[@"3G"] intValue])
        {
            case 0:
                return connectionType;
            case 1:
                return Connection4GOverride;
            case 2:
                return ConnectionLte;
            default:
                break;
        }
    }

    if (connectionType == Connection4GOverride || connectionType == ConnectionLte)
    {
        switch([defaults[@"4G"] intValue])
        {
            case 0:
                return connectionType;
            case 1:
                return Connection4GOverride;
            case 2:
                return ConnectionLte;
            default:
                break;
        }
    }

    return connectionType;
}
%end
%end

%group GiOS12
%hook SBMutableTelephonyCarrierBundleInfo
- (BOOL)LTEConnectionShows4G
{
    return NO;
}
%end
%end

%group GiOS11
%hook SBTelephonyManager
- (int)dataConnectionType
{
    int connectionType = %orig;
    NSDictionary *defaults = DLSSettings();

    if (connectionType == ConnectionUmts || connectionType == ConnectionHsdpa)
    {
        switch([defaults[@"3G"] intValue])
        {
            case 0:
                return connectionType;
            case 1:
                return Connection4GOverride;
            case 2:
                return ConnectionLte;
            default:
                break;
        }
    }

    if (connectionType == Connection4GOverride || connectionType == ConnectionLte)
    {
        switch([defaults[@"4G"] intValue])
        {
            case 0:
                return connectionType;
            case 1:
                return Connection4GOverride;
            case 2:
                return ConnectionLte;
            default:
                break;
        }
    }

    return connectionType;
}
%end
%end

%ctor
{
    %init;

    if (kCFCoreFoundationVersionNumber < kCFCoreFoundationVersionNumber_iOS_12_0)
    {
         %init(GiOS11);
    }
    else if (kCFCoreFoundationVersionNumber >= kCFCoreFoundationVersionNumber_iOS_12_0 && kCFCoreFoundationVersionNumber < kCFCoreFoundationVersionNumber_iOS_13_0)
    {
        %init(GiOS12);

        if (kCFCoreFoundationVersionNumber < kCFCoreFoundationVersionNumber_iOS_12_2)
        {
            %init(GiOS12_1);
        }
        else
        {
            %init(GiOS12_2);
        }
    }
    else
    {
        // iOS 17 keeps the cellular host and rewrites only the final
        // attributed glyphs: LTE+ for 4G+/4Gᴀ, 5G+ for 5Gᴀ.
        %init(GiOS13);
        %init(GiOS17);
    }
}
