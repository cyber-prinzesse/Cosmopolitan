/* Cosmopolitan: Wine loader dispatcher for Dock labels.
 *
 * macOS names a Wine app in the Dock after the *file name* of the executable it was exec'd as
 * (bin/Steam → "Steam"). LaunchServices display names (cosmo_nodock / CFBundleName) are ignored.
 *
 * Cosmopolitan starts Wine through this program and keeps WINELOADER pointing here so every child
 * CreateProcess comes back through it. Wine 10 exec's WINELOADER with argv[1] = the Windows exe
 * path (CrossOver loader/main.c apple_override_bundle_name). We look that basename up in
 * $WINEPREFIX/options/dock-names.txt (or Mac Driver AppName in user.reg), then execv a real wine
 * copy named <dir>/<Name>. No entry → $COSMO_LOADER_NAME, else "wine".
 *
 * Wine 11 (Highball): the first PE start exec's lib/wine/x86_64-unix/wine (hardcoded next to ntdll).
 * Cosmopolitan installs this file as that wine; the real loader is kept as wine.cosmo-real.
 */
#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <mach-o/dyld.h>
#endif

/* Marker so Cosmopolitan can tell this binary from a real wine loader (strings(1) / memmem). */
__attribute__((used)) static const char cosmo_marker[] = "cosmo_dock_loader_v1";

static int is_file(const char *p)
{
    struct stat st;
    return p && stat(p, &st) == 0 && S_ISREG(st.st_mode);
}

static char *dir_of(const char *path, char *buf, size_t n)
{
    const char *slash = strrchr(path, '/');
    if (!slash) { snprintf(buf, n, "."); return buf; }
    if (slash == path) { snprintf(buf, n, "/"); return buf; }
    size_t len = (size_t)(slash - path);
    if (len >= n) len = n - 1;
    memcpy(buf, path, len);
    buf[len] = 0;
    return buf;
}

static const char *base_of(const char *path)
{
    const char *s = strrchr(path, '/');
    return s ? s + 1 : path;
}

/* Spaces / : / \ → UTF-8 U+00A0 so Dock shows a space but the path has no ASCII space. */
static void sanitize_loader_name(const char *raw, char *out, size_t n)
{
    size_t j = 0;
    int space = 0;
    for (size_t i = 0; raw[i] && j + 4 < n; i++) {
        unsigned char c = (unsigned char)raw[i];
        if (c == 0xC2 && (unsigned char)raw[i + 1] == 0xA0) {
            if (!space && j) { out[j++] = (char)0xC2; out[j++] = (char)0xA0; space = 1; }
            i++;
            continue;
        }
        if (c == ':' || c == '/' || c == '\\' || c == ' ' || c == 0xA0) {
            if (!space && j) { out[j++] = (char)0xC2; out[j++] = (char)0xA0; space = 1; }
            continue;
        }
        out[j++] = (char)c;
        space = 0;
    }
    while (j >= 2 && (unsigned char)out[j - 2] == 0xC2 && (unsigned char)out[j - 1] == 0xA0) j -= 2;
    if (!j) { snprintf(out, n, "wine"); return; }
    out[j] = 0;
}

static void exe_leaf_lower(const char *arg, char *out, size_t n)
{
    const char *p = arg, *slash;
    if ((slash = strrchr(p, '\\'))) p = slash + 1;
    if ((slash = strrchr(p, '/'))) p = slash + 1;
    size_t j = 0;
    for (; p[j] && j + 1 < n; j++) {
        unsigned char c = (unsigned char)p[j];
        if (c == ' ' || c == '\t') break;
        out[j] = (char)tolower(c);
        if (j >= 3 && out[j - 3] == '.' && out[j - 2] == 'e' && out[j - 1] == 'x' && out[j] == 'e') {
            j++;
            break;
        }
    }
    out[j] = 0;
}

static int lookup_dock_names(const char *prefix, const char *exe_lc, char *name, size_t n)
{
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/options/dock-names.txt", prefix);
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    char line[2048];
    int found = 0;
    while (fgets(line, sizeof line, f)) {
        char *tab = strchr(line, '\t');
        if (!tab) continue;
        *tab = 0;
        char *nl = strchr(tab + 1, '\n');
        if (nl) *nl = 0;
        char key[256];
        size_t k;
        for (k = 0; line[k] && k + 1 < sizeof key; k++) key[k] = (char)tolower((unsigned char)line[k]);
        key[k] = 0;
        if (strcmp(key, exe_lc) != 0) continue;
        snprintf(name, n, "%s", tab + 1);
        found = 1;
        break;
    }
    fclose(f);
    return found;
}

static void utf8_append(char *name, size_t *j, size_t n, unsigned code)
{
    if (code < 0x80) {
        if (*j + 1 < n) name[(*j)++] = (char)code;
    } else if (code < 0x800) {
        if (*j + 2 < n) {
            name[(*j)++] = (char)(0xC0 | (code >> 6));
            name[(*j)++] = (char)(0x80 | (code & 0x3F));
        }
    } else if (*j + 3 < n) {
        name[(*j)++] = (char)(0xE0 | (code >> 12));
        name[(*j)++] = (char)(0x80 | ((code >> 6) & 0x3F));
        name[(*j)++] = (char)(0x80 | (code & 0x3F));
    }
}

static int lookup_appname_reg(const char *prefix, const char *exe_lc, char *name, size_t n)
{
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/user.reg", prefix);
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    char line[4096];
    int in = 0, found = 0;
    while (fgets(line, sizeof line, f)) {
        if (line[0] == '[') {
            in = 0;
            char low[512];
            size_t i;
            for (i = 0; line[i] && i + 1 < sizeof low; i++) low[i] = (char)tolower((unsigned char)line[i]);
            low[i] = 0;
            if (strstr(low, "\\\\mac driver]") && strstr(low, exe_lc)) in = 1;
            continue;
        }
        if (!in || strncmp(line, "\"AppName\"=\"", 11) != 0) continue;
        char *v = line + 11, *end = strrchr(v, '"');
        if (!end || end == v) continue;
        *end = 0;
        size_t j = 0;
        for (size_t i = 0; v[i] && j + 4 < n; ) {
            if (v[i] == '\\' && v[i + 1] == 'x') {
                unsigned code = 0; int nd = 0;
                i += 2;
                while (nd < 4 && isxdigit((unsigned char)v[i])) {
                    char c = v[i++];
                    code = code * 16u + (unsigned)(c <= '9' ? c - '0' : (c | 32) - 'a' + 10);
                    nd++;
                }
                utf8_append(name, &j, n, code);
                continue;
            }
            if (v[i] == '\\' && v[i + 1]) { name[j++] = v[i + 1]; i += 2; continue; }
            name[j++] = v[i++];
        }
        name[j] = 0;
        found = j > 0;
        break;
    }
    fclose(f);
    return found;
}

static int ensure_copy(const char *src, const char *dst)
{
    struct stat ss, ds;
    if (stat(src, &ss) != 0) return -1;
    if (stat(dst, &ds) == 0 && ds.st_mtime >= ss.st_mtime && ds.st_size == ss.st_size
        && S_ISREG(ds.st_mode)) return 0;
    /* Steam starts several helpers at once: write a private temp file and rename it into place, so no process ever
       exec's a half-written copy (a running process keeps the inode it started from). */
    char tmp[PATH_MAX];
    snprintf(tmp, sizeof tmp, "%s.%d.tmp", dst, (int)getpid());
    FILE *in = fopen(src, "rb");
    if (!in) return -1;
    FILE *out = fopen(tmp, "wb");
    if (!out) { fclose(in); return -1; }
    char buf[1 << 16];
    size_t r;
    while ((r = fread(buf, 1, sizeof buf, in)) > 0) {
        if (fwrite(buf, 1, r, out) != r) { fclose(in); fclose(out); unlink(tmp); return -1; }
    }
    fclose(in);
    if (fclose(out) != 0 || chmod(tmp, 0755) != 0 || rename(tmp, dst) != 0) { unlink(tmp); return -1; }
    return 0;
}

static int resolve_self(char *self, size_t n)
{
#if defined(__APPLE__)
    uint32_t sz = (uint32_t)n;
    if (_NSGetExecutablePath(self, &sz) == 0) {
        char tmp[PATH_MAX];
        if (realpath(self, tmp)) snprintf(self, n, "%s", tmp);
        return 0;
    }
#endif
    return -1;
}

/* Real wine bytes to copy: wine.cosmo-real (Wine 11), else bin/wine when we are cosmo_wineloader. */
static int resolve_real_wine(const char *self, const char *dir, char *real_wine, size_t n)
{
    snprintf(real_wine, n, "%s/wine.cosmo-real", dir);
    if (is_file(real_wine)) return 0;

    snprintf(real_wine, n, "%s/wine", dir);
    if (is_file(real_wine) && strcmp(real_wine, self) != 0) {
        /* Make sure it is not another copy of the dispatcher. */
        FILE *f = fopen(real_wine, "rb");
        if (f) {
            char buf[8192];
            size_t r = fread(buf, 1, sizeof buf, f);
            fclose(f);
            int is_disp = 0;
            const size_t mlen = sizeof cosmo_marker - 1;
            for (size_t i = 0; r >= mlen && i + mlen <= r; i++) {
                if (memcmp(buf + i, cosmo_marker, mlen) == 0) { is_disp = 1; break; }
            }
            if (!is_disp) return 0;
        }
    }

    /* From x86_64-unix/wine dispatcher with missing backup: refuse rather than recurse. */
    (void)base_of;
    return -1;
}

int main(int argc, char *argv[])
{
    char self[PATH_MAX], dir[PATH_MAX], real_wine[PATH_MAX], target[PATH_MAX];
    char display[512], file_name[512], exe_lc[256];

    if (resolve_self(self, sizeof self) != 0) {
        if (!argv[0]) return 127;
        if (argv[0][0] == '/') snprintf(self, sizeof self, "%s", argv[0]);
        else {
            char cwd[PATH_MAX];
            if (!getcwd(cwd, sizeof cwd)) return 127;
            snprintf(self, sizeof self, "%s/%s", cwd, argv[0]);
        }
        char tmp[PATH_MAX];
        if (realpath(self, tmp)) snprintf(self, sizeof self, "%s", tmp);
    }
    dir_of(self, dir, sizeof dir);

    if (resolve_real_wine(self, dir, real_wine, sizeof real_wine) != 0) {
        fprintf(stderr, "cosmo_wineloader: no real wine beside %s\n", self);
        return 127;
    }

    display[0] = 0;
    exe_lc[0] = 0;
    if (argc >= 2 && argv[1] && argv[1][0] && argv[1][0] != '-') {
        exe_leaf_lower(argv[1], exe_lc, sizeof exe_lc);
        const char *pfx = getenv("WINEPREFIX");
        if (pfx && exe_lc[0]) {
            if (!lookup_dock_names(pfx, exe_lc, display, sizeof display))
                lookup_appname_reg(pfx, exe_lc, display, sizeof display);
        }
    }
    if (!display[0]) {
        const char *fb = getenv("COSMO_LOADER_NAME");
        if (fb && fb[0]) snprintf(display, sizeof display, "%s", fb);
        else snprintf(display, sizeof display, "wine");
    }
    sanitize_loader_name(display, file_name, sizeof file_name);

    snprintf(target, sizeof target, "%s/%s", dir, file_name);
    if (strcmp(target, self) == 0) {
        /* Dispatcher path equals desired name (Wine 11: we *are* unix/wine). Side copy. */
        snprintf(target, sizeof target, "%s/%s", dir, file_name);
        if (strcmp(target, self) == 0)
            snprintf(target, sizeof target, "%s/_%s", dir, file_name);
    }

    if (ensure_copy(real_wine, target) != 0) {
        fprintf(stderr, "cosmo_wineloader: cannot copy %s → %s\n", real_wine, target);
        snprintf(target, sizeof target, "%s", real_wine);
    }

    setenv("WINELOADER", self, 1);

    /* The Dock labels a process with the file it was exec'd as (target). Wine's loader resolves argv[0] to find
       ../lib/wine, and ntdll then overwrites WINELOADER with <bin>/<basename of argv[0]> for every child it starts
       (init_paths; any inherited WINELOADER is dropped). Passing this dispatcher as argv[0] keeps children coming
       back here, so a program Steam starts gets its own name instead of the parent's. */
    argv[0] = self;
    execv(target, argv);
    fprintf(stderr, "cosmo_wineloader: execv %s: %s\n", target, strerror(errno));
    return 127;
}
