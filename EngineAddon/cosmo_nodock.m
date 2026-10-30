/* Cosmopolitan: NoDockIcon, loaded into each engine's Mac driver (Sikarugir's Wine 10 one can't be rebuilt: D3DMetal and DXMT use its CrossOver-only macdrv_functions).
 * A program with
 *   [Software\\Wine\\AppDefaults\\<exe>\\Mac Driver] "NoDockIcon"="y"  (bottle's user.reg)
 * becomes an accessory app the first time Wine would give it a Dock icon: its windows still show and take focus, but it has
 * no Dock icon. Loaded by winemac.so (one extra LC_LOAD_DYLIB); replaces -[WineApplicationController
 * transformProcessToForeground:] and calls the original for every other program. */
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

static BOOL no_dock_icon(void)
{
    static BOOL result;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *prefix = getenv("WINEPREFIX");
        NSString *exe = windows_exe_name();
        if (!prefix || !exe.length) return;
        NSString *reg = [NSString stringWithContentsOfFile:[NSString stringWithFormat:@"%s/user.reg", prefix]
                                                  encoding:NSUTF8StringEncoding error:NULL];
        if (!reg) return;
        for (NSString *section in [reg componentsSeparatedByString:@"\n\n"])
        {
            NSString *head = [[section componentsSeparatedByString:@"\n"] firstObject].lowercaseString;
            NSString *want = [NSString stringWithFormat:@"[software\\\\wine\\\\appdefaults\\\\%@\\\\mac driver]", exe];
            if (![head hasPrefix:want]) continue;
            for (NSString *line in [section componentsSeparatedByString:@"\n"])
                if ([line hasPrefix:@"\"NoDockIcon\"=\""] && line.length > 14)
                    result = strchr("yYtT1", [line characterAtIndex:14]) != NULL;
        }
    });
    return result;
}

static void transform(id self, SEL _cmd, BOOL activateIfTransformed)
{
    if (!no_dock_icon())
    {
        ((void (*)(id, SEL, BOOL))original)(self, _cmd, activateIfTransformed);
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
