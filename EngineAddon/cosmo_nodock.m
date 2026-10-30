/* Cosmopolitan: per-program Dock settings, loaded into each engine's Mac driver (Sikarugir's Wine 10 one can't be rebuilt:
 * D3DMetal and DXMT use its CrossOver-only macdrv_functions). Read from the bottle's user.reg:
 *   [Software\\Wine\\AppDefaults\\<exe>\\Mac Driver] "NoDockIcon"="y"   no Dock icon of its own (steam.exe beside its window)
 *                                                    "AppName"="…"      the name macOS shows (Dock, app switcher); a game
 *                                                                        started by Steam otherwise inherits Steam's name
 * and, for games Steam starts, <prefix>/options/dock-names.txt ("exe<TAB>name" lines Cosmopolitan writes from the library).
 * Loaded by winemac.so (one extra LC_LOAD_DYLIB); replaces -[WineApplicationController transformProcessToForeground:] and
 * calls the original for every program without NoDockIcon. */
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <sys/sysctl.h>
#include <unistd.h>

static IMP original;

/* The Windows program name: Wine rewrites the process arguments to the Windows command line ("C:\...\steam.exe -args"). */
static NSString *windows_exe_name(void)
{
    int mib[3] = { CTL_KERN, KERN_PROCARGS2, getpid() };
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) || size <= sizeof(int)) return nil;
    char *buf = malloc(size), *p, *end;
    if (!buf) return nil;
    if (sysctl(mib, 3, buf, &size, NULL, 0)) { free(buf); return nil; }
    end = buf + size;
    p = buf + sizeof(int);
    while (p < end && *p) p++;   /* exec path */
    while (p < end && !*p) p++;  /* padding */
    NSString *arg0 = p < end ? [NSString stringWithUTF8String:p] : nil;
    free(buf);
    if (!arg0) return nil;
    /* argv[0] alone may still carry following words when Wine joined the command line into one string */
    NSRange exe = [arg0.lowercaseString rangeOfString:@".exe"];
    if (exe.location != NSNotFound) arg0 = [arg0 substringToIndex:NSMaxRange(exe)];
    arg0 = [[arg0 componentsSeparatedByString:@"\\"] lastObject];
    return [[arg0 componentsSeparatedByString:@"/"] lastObject].lowercaseString;
}

/* user.reg string escapes: \\ \" \n \r \t, and any character above 127 as \x plus up to 4 hex digits ("—" is \x2014). */
static NSString *unescape(NSString *s)
{
    NSMutableString *out = [NSMutableString string];
    NSUInteger n = s.length;
    for (NSUInteger i = 0; i < n; i++)
    {
        unichar c = [s characterAtIndex:i];
        if (c != '\\' || i + 1 == n) { [out appendFormat:@"%C", c]; continue; }
        unichar e = [s characterAtIndex:++i];
        if (e == 'x')
        {
            unsigned v = 0, k = 0;
            while (k < 4 && i + 1 < n && isxdigit([s characterAtIndex:i + 1])) { v = v * 16 + (unsigned)digittoint([s characterAtIndex:++i]); k++; }
            [out appendFormat:@"%C", (unichar)v];
        }
        else [out appendFormat:@"%C", (unichar)(e == 'n' ? '\n' : e == 'r' ? '\r' : e == 't' ? '\t' : e)];
    }
    return out;
}

/* This program's [AppDefaults\<exe>\Mac Driver] string values, read once. */
static NSDictionary<NSString *, NSString *> *mac_driver_values(void)
{
    static NSDictionary *values;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        const char *prefix = getenv("WINEPREFIX");
        NSString *exe = windows_exe_name();
        NSString *reg = prefix && exe.length ? [NSString stringWithContentsOfFile:[NSString stringWithFormat:@"%s/user.reg", prefix]
                                                                         encoding:NSUTF8StringEncoding error:NULL] : nil;
        NSString *want = [NSString stringWithFormat:@"[software\\\\wine\\\\appdefaults\\\\%@\\\\mac driver]", exe];
        for (NSString *section in reg ? [reg componentsSeparatedByString:@"\n\n"] : @[])
        {
            if (![[[section componentsSeparatedByString:@"\n"] firstObject].lowercaseString hasPrefix:want]) continue;
            for (NSString *line in [section componentsSeparatedByString:@"\n"])
            {
                NSRange eq = [line rangeOfString:@"\"=\""];
                if (![line hasPrefix:@"\""] || eq.location == NSNotFound || ![line hasSuffix:@"\""]) continue;
                NSString *key = [line substringWithRange:NSMakeRange(1, eq.location - 1)];
                NSString *val = [line substringWithRange:NSMakeRange(NSMaxRange(eq), line.length - NSMaxRange(eq) - 1)];
                out[key] = unescape(val);
            }
        }
        /* Cosmopolitan's per-bottle list for games Steam starts (options/dock-names.txt, "exe<TAB>name"); AppName wins. */
        NSString *names = prefix && exe.length && !out[@"AppName"] ? [NSString stringWithContentsOfFile:[NSString stringWithFormat:@"%s/options/dock-names.txt", prefix]
                                                                                              encoding:NSUTF8StringEncoding error:NULL] : nil;
        for (NSString *line in names ? [names componentsSeparatedByString:@"\n"] : @[])
        {
            NSArray *f = [line componentsSeparatedByString:@"\t"];
            if (f.count == 2 && [[f[0] lowercaseString] isEqualToString:exe] && [f[1] length]) { out[@"AppName"] = f[1]; break; }
        }
        values = [out copy];
    });
    return values;
}

static BOOL no_dock_icon(void)
{
    NSString *v = mac_driver_values()[@"NoDockIcon"];
    return v.length && strchr("yYtT1", [v characterAtIndex:0]) != NULL;
}

/* The Dock / app switcher name, set in LaunchServices' record of this running app (as Chromium names its helpers). */
static void set_app_name(void)
{
    typedef CFTypeRef (*GetASN)(void);
    typedef OSStatus (*SetItem)(int, CFTypeRef, CFStringRef, CFTypeRef, CFDictionaryRef *);
    NSString *name = mac_driver_values()[@"AppName"];
    CFBundleRef ls = CFBundleGetBundleWithIdentifier(CFSTR("com.apple.LaunchServices"));
    if (!name.length || !ls) return;
    GetASN get_asn = (GetASN)CFBundleGetFunctionPointerForName(ls, CFSTR("_LSGetCurrentApplicationASN"));
    SetItem set_item = (SetItem)CFBundleGetFunctionPointerForName(ls, CFSTR("_LSSetApplicationInformationItem"));
    CFStringRef *key = (CFStringRef *)CFBundleGetDataPointerForName(ls, CFSTR("_kLSDisplayNameKey"));
    CFTypeRef asn = get_asn ? get_asn() : NULL;
    if (set_item && key && *key && asn) set_item(-2 /* kLSDefaultSessionID */, asn, *key, (__bridge CFStringRef)name, NULL);
}

static void transform(id self, SEL _cmd, BOOL activateIfTransformed)
{
    if (!no_dock_icon())
    {
        ((void (*)(id, SEL, BOOL))original)(self, _cmd, activateIfTransformed);
        static BOOL named;
        if (!named && [NSApp activationPolicy] == NSApplicationActivationPolicyRegular) { named = YES; set_app_name(); }
        return;
    }
    if ([NSApp activationPolicy] == NSApplicationActivationPolicyProhibited)
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    if (activateIfTransformed && [self respondsToSelector:@selector(tryToActivateIgnoringOtherApps:)])
        ((void (*)(id, SEL, BOOL))objc_msgSend)(self, @selector(tryToActivateIgnoringOtherApps:), YES);
}

__attribute__((constructor)) static void install(void)
{
    Class c = objc_getClass("WineApplicationController");
    Method m = c ? class_getInstanceMethod(c, @selector(transformProcessToForeground:)) : NULL;
    if (m) original = method_setImplementation(m, (IMP)transform);
}
