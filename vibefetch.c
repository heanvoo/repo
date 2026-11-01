/*
 * vibefetch - tiny neofetch-style system info for jailbroken iOS (NewTerm).
 * Only POSIX / sysctl / mach APIs, no private frameworks.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdarg.h>
#include <unistd.h>
#include <pwd.h>
#include <time.h>
#include <sys/types.h>
#include <sys/time.h>
#include <sys/sysctl.h>
#include <sys/utsname.h>
#include <sys/mount.h>
#include <mach/mach.h>
#include <mach/mach_host.h>

#define VERSION "1.0.0"

static int use_color = 1;

static const int GRAD[] = {213, 177, 141, 105, 75, 45, 49, 83};
#define NGRAD ((int)(sizeof(GRAD) / sizeof(GRAD[0])))

static void sgr(int c) {
    if (use_color) printf("\033[1;38;5;%dm", c);
}
static void reset(void) {
    if (use_color) printf("\033[0m");
}

static int sysstr(const char *name, char *buf, size_t n) {
    size_t l = n - 1;
    buf[0] = 0;
    if (sysctlbyname(name, buf, &l, NULL, 0) != 0) {
        buf[0] = 0;
        return 0;
    }
    buf[l < n ? l : n - 1] = 0;
    return buf[0] != 0;
}

static uint64_t sysu64(const char *name) {
    uint64_t v = 0;
    size_t l = sizeof(v);
    if (sysctlbyname(name, &v, &l, NULL, 0) != 0) return 0;
    return v; /* 4-byte values land in the low half (little endian) */
}

static void fmt_bytes(uint64_t b, char *out, size_t n) {
    const char *u[] = {"B", "KiB", "MiB", "GiB", "TiB"};
    double d = (double)b;
    int i = 0;
    while (d >= 1024.0 && i < 4) { d /= 1024.0; i++; }
    snprintf(out, n, i == 0 ? "%.0f %s" : "%.2f %s", d, u[i]);
}

static void fmt_uptime(long s, char *out, size_t n) {
    long d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60;
    if (d > 0) snprintf(out, n, "%ldd %ldh %ldm", d, h, m);
    else if (h > 0) snprintf(out, n, "%ldh %ldm", h, m);
    else snprintf(out, n, "%ldm", m);
}

static int count_packages(void) {
    const char *paths[] = {"/var/jb/var/lib/dpkg/status", "/var/lib/dpkg/status"};
    for (size_t i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
        FILE *f = fopen(paths[i], "r");
        if (!f) continue;
        char line[512];
        int cnt = 0;
        while (fgets(line, sizeof line, f))
            if (strncmp(line, "Status: install ok installed", 28) == 0) cnt++;
        fclose(f);
        return cnt;
    }
    return -1;
}

static const char *LOGO[] = {
    "  .----------.  ",
    "  | ~      ~ |  ",
    "  |  ~~~~~~  |  ",
    "  |   vibe   |  ",
    "  |  ~~~~~~  |  ",
    "  | ~      ~ |  ",
    "  |    (o)   |  ",
    "  '----------'  ",
};
#define NLOGO ((int)(sizeof(LOGO) / sizeof(LOGO[0])))

#define MAXL 20
static char keys[MAXL][24];
static char vals[MAXL][160];
static int nl = 0;

static void add(const char *k, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void add(const char *k, const char *fmt, ...) {
    if (nl >= MAXL) return;
    snprintf(keys[nl], sizeof keys[nl], "%s", k);
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(vals[nl], sizeof vals[nl], fmt, ap);
    va_end(ap);
    nl++;
}

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--no-color")) use_color = 0;
        else if (!strcmp(argv[i], "--version") || !strcmp(argv[i], "-v")) {
            printf("vibefetch %s\n", VERSION);
            return 0;
        } else if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
            printf("vibefetch %s - system info for iOS\n"
                   "usage: vibefetch [--no-color] [--version] [--help]\n", VERSION);
            return 0;
        }
    }
    if (!isatty(STDOUT_FILENO) || getenv("NO_COLOR")) use_color = 0;

    char buf[128], buf2[128], tmp[64];

    char host[128] = "iphone";
    gethostname(host, sizeof host);
    char *dot = strchr(host, '.');
    if (dot) *dot = 0;
    struct passwd *pw = getpwuid(getuid());
    const char *user = pw ? pw->pw_name : "mobile";

    char title[300];
    snprintf(title, sizeof title, "%s@%s", user, host);

    /* Device */
    if (sysstr("hw.machine", buf, sizeof buf)) add("Device", "%s", buf);

    /* OS */
    char ver[64] = "", build[64] = "";
    sysstr("kern.osproductversion", ver, sizeof ver);
    sysstr("kern.osversion", build, sizeof build);
    if (ver[0]) add("OS", "iOS %s%s%s%s", ver, build[0] ? " (" : "", build, build[0] ? ")" : "");
    else add("OS", "iOS");

    /* Kernel */
    struct utsname un;
    if (uname(&un) == 0) add("Kernel", "%s %s", un.sysname, un.release);

    /* Uptime */
    struct timeval bt;
    size_t bl = sizeof bt;
    if (sysctlbyname("kern.boottime", &bt, &bl, NULL, 0) == 0) {
        fmt_uptime((long)(time(NULL) - bt.tv_sec), buf, sizeof buf);
        add("Uptime", "%s", buf);
    }

    /* Packages */
    int pk = count_packages();
    if (pk >= 0) add("Packages", "%d (dpkg)", pk);

    /* Shell / Terminal */
    const char *sh = getenv("SHELL");
    if (sh) {
        const char *b = strrchr(sh, '/');
        add("Shell", "%s", b ? b + 1 : sh);
    }
    const char *term = getenv("TERM");
    add("Terminal", "NewTerm (%s)", term ? term : "unknown");

    /* CPU */
    uint64_t ncpu = sysu64("hw.ncpu");
    if (ncpu) add("CPU", "arm64, %llu cores", (unsigned long long)ncpu);

    /* Memory */
    uint64_t total = sysu64("hw.memsize");
    vm_size_t ps = 0;
    host_page_size(mach_host_self(), &ps);
    vm_statistics64_data_t vm;
    mach_msg_type_number_t cnt = HOST_VM_INFO64_COUNT;
    if (total && ps &&
        host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &cnt) == KERN_SUCCESS) {
        uint64_t used = ((uint64_t)vm.active_count + vm.wire_count + vm.compressor_page_count) * ps;
        fmt_bytes(used, buf, sizeof buf);
        fmt_bytes(total, buf2, sizeof buf2);
        snprintf(tmp, sizeof tmp, "%d%%", (int)(used * 100 / total));
        add("Memory", "%s / %s (%s)", buf, buf2, tmp);
    } else if (total) {
        fmt_bytes(total, buf, sizeof buf);
        add("Memory", "%s", buf);
    }

    /* Disk */
    struct statfs fs;
    if (statfs("/private/var", &fs) == 0 || statfs("/", &fs) == 0) {
        uint64_t t = (uint64_t)fs.f_blocks * fs.f_bsize;
        uint64_t u = (uint64_t)(fs.f_blocks - fs.f_bfree) * fs.f_bsize;
        fmt_bytes(u, buf, sizeof buf);
        fmt_bytes(t, buf2, sizeof buf2);
        add("Disk", "%s / %s", buf, buf2);
    }

    /* ---- print ---- */
    int rows = nl + 3; /* title, rule, blank-ish */
    if (rows < NLOGO) rows = NLOGO;
    int info_row = 0;
    int total_rows = rows + 2; /* + color bars */
    for (int r = 0; r < total_rows; r++) {
        /* logo column */
        if (r < NLOGO) {
            sgr(GRAD[r % NGRAD]);
            printf("%s", LOGO[r]);
            reset();
        } else {
            printf("%*s", 16, "");
        }
        /* info column */
        if (r == 0) {
            sgr(GRAD[1]);
            printf("%s", title);
            reset();
        } else if (r == 1) {
            for (size_t i = 0; i < strlen(title); i++) putchar('-');
        } else if (info_row < nl) {
            sgr(GRAD[(info_row + 2) % NGRAD]);
            printf("%s", keys[info_row]);
            reset();
            printf(": %s", vals[info_row]);
            info_row++;
        } else if (r == rows) {
            if (use_color) for (int c = 0; c < NGRAD; c++) printf("\033[48;5;%dm   ", GRAD[c]);
            reset();
        }
        putchar('\n');
    }
    return 0;
}
