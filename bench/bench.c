/*
 * asm-snappy benchmark. Bench code: the library itself is assembly.
 *
 * Usage:
 *   bench run VECTOR_DIR [--quick]   time the workload and print the results
 *   bench compare BASE NEW           compare two results files
 *
 * The workload, the results format and the compare rule are in bench/README.md.
 * Every call is checked against its case before it is timed.
 */
#if defined(__APPLE__)
#define _DARWIN_C_SOURCE
#elif !defined(_WIN32)
#define _GNU_SOURCE
#endif
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#if defined(_WIN32)
#include <windows.h>
#elif defined(__APPLE__)
#include <pthread.h>
#include <sys/qos.h>
#include <sys/sysctl.h>
#else
#include <sched.h>
#endif

#if defined(_WIN32) && defined(__x86_64__)
#define SNAPPY_ABI __attribute__((sysv_abi))
#else
#define SNAPPY_ABI
#endif

/* The library (docs/reference/). */
SNAPPY_ABI uint64_t snappy_compress(const void *input, void *scratch, void *compressed);
SNAPPY_ABI uint64_t snappy_get_uncompressed_length(const void *compressed, void *length);
SNAPPY_ABI uint64_t snappy_uncompress(const void *compressed, void *uncompressed);
SNAPPY_ABI uint64_t snappy_frame_compress(const void *input, void *scratch, void *framed);
SNAPPY_ABI uint64_t snappy_frame_uncompress(const void *framed, const void *length, void *uncompressed,
                                            void *consumed);

#if defined(_WIN32)
#define OS_NAME "windows"
#elif defined(__APPLE__)
#define OS_NAME "macos"
#else
#define OS_NAME "linux"
#endif
#if defined(__x86_64__)
#define ISA_NAME "x86_64"
#elif defined(__aarch64__)
#define ISA_NAME "arm64"
#else
#define ISA_NAME "riscv64"
#endif

/* The workload (bench/README.md): each file and the case timed from it. */
static const char *const workload[][2] = {
    {"testdata-block-valid.bin", "testdata/html"},
    {"testdata-block-valid.bin", "testdata/urls.10K"},
    {"testdata-block-valid.bin", "testdata/fireworks.jpeg"},
    {"testdata-block-valid.bin", "testdata/paper-100k.pdf"},
    {"testdata-block-valid.bin", "testdata/alice29.txt"},
    {"testdata-block-valid.bin", "testdata/geo.protodata"},
    {"consensus-block-valid.bin", "/electra/ssz_static/Attestation/"},
    {"consensus-block-valid.bin", "/electra/ssz_static/SignedBeaconBlock/"},
    {"consensus-block-valid.bin", "/fulu/ssz_static/BeaconState/"},
};
#define WORKLOAD (sizeof workload / sizeof workload[0])
static const char *const files[] = {"testdata-block-valid.bin", "consensus-block-valid.bin"};
#define FILES (sizeof files / sizeof files[0])
#define SCRATCH_FRAME 109272

/* Each item gets ROUNDS rounds of SAMPLES_PER_ROUND samples, pooled. A round
 * times every item once, so drift between rounds widens each item's spread. */
#define ROUNDS 3
#define SAMPLES_PER_ROUND 7
#define SAMPLES (ROUNDS * SAMPLES_PER_ROUND)
#define QUICK_SAMPLES 3
#define SAMPLE_NS 2000000.0 /* each sample runs the call about this long */
#define QUICK_SAMPLE_NS 0.0
/* compare: a change counts only when the middle halves of the samples do not
 * overlap and the medians differ by at least this much. */
#define MIN_CHANGE 0.03

static void die(const char *what) {
    fprintf(stderr, "bench: %s\n", what);
    exit(2);
}

static uint64_t rd64(const uint8_t *p) {
    uint64_t v = 0;
    for (int i = 7; i >= 0; i--) v = (v << 8) | p[i];
    return v;
}

static void wr64(uint8_t *p, uint64_t v) {
    for (int i = 0; i < 8; i++) p[i] = (uint8_t)(v >> (8 * i));
}

/* An 8-aligned buffer of n bytes, zeroed. */
static uint8_t *buffer(uint64_t n) {
    uint8_t *b = calloc(1, (size_t)(n ? n : 8));
    if (!b) die("out of memory");
    return b;
}

static uint64_t now_ns(void) {
#if defined(_WIN32)
    LARGE_INTEGER c, f;
    QueryPerformanceCounter(&c);
    QueryPerformanceFrequency(&f);
    return (uint64_t)(c.QuadPart / f.QuadPart) * 1000000000u
           + (uint64_t)(c.QuadPart % f.QuadPart) * 1000000000u / (uint64_t)f.QuadPart;
#elif defined(__APPLE__)
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#else
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000u + (uint64_t)t.tv_nsec;
#endif
}

/* The CPU's name as the OS reports it, on one line. */
static void cpu_name(char *out, size_t size) {
    snprintf(out, size, "unknown");
#if defined(_WIN32)
    DWORD n = (DWORD)size;
    if (RegGetValueA(HKEY_LOCAL_MACHINE, "HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0",
                     "ProcessorNameString", RRF_RT_REG_SZ, NULL, out, &n) != ERROR_SUCCESS)
        snprintf(out, size, "unknown");
#elif defined(__APPLE__)
    size_t n = size;
    if (sysctlbyname("machdep.cpu.brand_string", out, &n, NULL, 0) != 0) snprintf(out, size, "unknown");
#else
    FILE *f = fopen("/proc/cpuinfo", "r");
    char line[256], implementer[32] = "", part[32] = "", isa[64] = "";
    if (!f) return;
    while (fgets(line, sizeof line, f)) {
        char *v = strchr(line, ':');
        if (!v) continue;
        v++;
        while (*v == ' ' || *v == '\t') v++;
        v[strcspn(v, "\n")] = 0;
        if (!strncmp(line, "model name", 10)) {
            snprintf(out, size, "%s", v);
            fclose(f);
            return;
        }
        if (!strncmp(line, "CPU implementer", 15) && !*implementer) snprintf(implementer, sizeof implementer, "%s", v);
        if (!strncmp(line, "CPU part", 8) && !*part) snprintf(part, sizeof part, "%s", v);
        if (!strncmp(line, "isa", 3) && !*isa) snprintf(isa, sizeof isa, "%s", v);
    }
    fclose(f);
    if (*implementer) snprintf(out, size, "Arm implementer %s part %s", implementer, part);
    else if (*isa) snprintf(out, size, "RISC-V %s", isa);
#endif
    for (char *p = out; *p; p++)
        if (*p == '\n' || *p == '\r' || *p == '\t') *p = ' ';
    /* Some OSes pad the name with spaces: drop them at both ends. */
    size_t end = strlen(out), lead = strspn(out, " ");
    while (end > lead && out[end - 1] == ' ') end--;
    memmove(out, out + lead, end - lead);
    out[end - lead] = 0;
}

/* ---------------------------------------------------------------- Vector files */

typedef struct {
    uint8_t *data;
    uint64_t len, ncases;
    const uint8_t *cases;
    char sha256[65];
} vecfile;

typedef struct {
    const uint8_t *p, *end;
} cursor;

static const uint8_t *take(cursor *c, uint64_t n) {
    if ((uint64_t)(c->end - c->p) < n) die("vector file ends early");
    const uint8_t *r = c->p;
    c->p += n;
    return r;
}

static uint64_t take64(cursor *c) { return rd64(take(c, 8)); }

/* The SHA-256 of a vector file, from the generator's manifest.txt. */
static void manifest_sha256(const char *dir, const char *name, char *out) {
    char path[4096], line[512];
    snprintf(path, sizeof path, "%s/manifest.txt", dir);
    FILE *f = fopen(path, "r");
    if (!f) die("cannot read manifest.txt");
    size_t n = strlen(name);
    while (fgets(line, sizeof line, f)) {
        char *last = strrchr(line, ' ');
        if (!strncmp(line, name, n) && line[n] == ' ' && last && strlen(last + 1) >= 64) {
            memcpy(out, last + 1, 64);
            out[64] = 0;
            fclose(f);
            return;
        }
    }
    die("a workload file is not in manifest.txt");
}

static void load(vecfile *v, const char *dir, const char *name) {
    char path[4096];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    FILE *f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "bench: cannot read %s\n", path);
        exit(2);
    }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    v->data = buffer((uint64_t)n);
    if (fread(v->data, 1, (size_t)n, f) != (size_t)n) die("short read");
    fclose(f);
    v->len = (uint64_t)n;
    manifest_sha256(dir, name, v->sha256);
    cursor c = {v->data, v->data + v->len};
    if (memcmp(take(&c, 8), "SNPVEC01", 8)) die("wrong magic");
    if (take64(&c) != 1) die("not a block valid case file");
    v->ncases = take64(&c);
    v->cases = c.p;
}

/* ---------------------------------------------------------------- Timed calls */

enum { F_COMPRESS, F_UNCOMPRESS, F_GET_LENGTH, F_FRAME_COMPRESS, F_FRAME_UNCOMPRESS };
static const char *const fn_name[] = {"snappy_compress", "snappy_uncompress", "snappy_get_uncompressed_length",
                                      "snappy_frame_compress", "snappy_frame_uncompress"};

typedef struct {
    int fn;
    char name[256];
    uint64_t bytes;
    uint8_t *a, *b, *c, *d; /* the call's arguments */
    uint64_t calls;         /* calls in one sample */
    double t[SAMPLES];      /* ns per call, one entry for each sample */
    int n;
} item;

static item *items;
static int nitems;

static uint64_t call(const item *it) {
    switch (it->fn) {
    case F_COMPRESS: return snappy_compress(it->a, it->b, it->c);
    case F_UNCOMPRESS: return snappy_uncompress(it->a, it->b);
    case F_GET_LENGTH: return snappy_get_uncompressed_length(it->a, it->b);
    case F_FRAME_COMPRESS: return snappy_frame_compress(it->a, it->b, it->c);
    default: return snappy_frame_uncompress(it->a, it->b, it->c, it->d);
    }
}

static int cmp_double(const void *x, const void *y) {
    double a = *(const double *)x, b = *(const double *)y;
    return (a > b) - (a < b);
}

/* Keep the timed thread on one fast core as far as the OS allows. */
static void settle(void) {
#if defined(__APPLE__)
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
#elif defined(_WIN32)
    SetThreadAffinityMask(GetCurrentThread(), (DWORD_PTR)1 << GetCurrentProcessorNumber());
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_HIGHEST);
#else
    cpu_set_t set;
    int cpu = sched_getcpu();
    CPU_ZERO(&set);
    CPU_SET(cpu < 0 ? 0 : cpu, &set);
    sched_setaffinity(0, sizeof set, &set);
#endif
}

static uint64_t refused;

/* Calls in one sample: double the batch until it runs an eighth of the target, then scale it. */
static void calibrate(item *it, double target) {
    uint64_t calls = 1;
    for (;;) {
        uint64_t start = now_ns();
        for (uint64_t k = 0; k < calls; k++) refused |= call(it);
        double took = (double)(now_ns() - start);
        if (took >= target / 8 || calls >= (1ull << 40)) {
            if (took > 0 && took < target) calls = (uint64_t)((double)calls * target / took) + 1;
            break;
        }
        calls *= 2;
    }
    it->calls = calls;
}

static void sample(item *it) {
    uint64_t start = now_ns();
    for (uint64_t k = 0; k < it->calls; k++) refused |= call(it);
    it->t[it->n++] = (double)(now_ns() - start) / (double)it->calls;
}

static void add_item(const item *it) {
    items = realloc(items, (size_t)(nitems + 1) * sizeof *items);
    if (!items) die("out of memory");
    items[nitems++] = *it;
}

static void check(int ok, const item *it, const char *what) {
    if (!ok) {
        fprintf(stderr, "bench: %s %s: %s\n", fn_name[it->fn], it->name, what);
        exit(1);
    }
}

static uint8_t *bytelist(const uint8_t *bytes, uint64_t len) {
    uint8_t *b = buffer(24 + len);
    wr64(b, 24 + len);
    wr64(b + 8, 24);
    wr64(b + 16, len);
    memcpy(b + 24, bytes, (size_t)len);
    return b;
}

/*
 * The timed calls for one case: the case named want, or for a want that ends
 * with "/", the largest case whose name contains it.
 * The case gives a block from python-snappy or google/snappy, and its data.
 */
static void bench_case(const vecfile *v, const char *want) {
    cursor c = {v->cases, v->data + v->len};
    const uint8_t *enc = NULL, *raw = NULL;
    uint64_t el = 0, rl = 0;
    char name[256] = "";
    for (uint64_t i = 0; i < v->ncases; i++) {
        uint64_t nl = take64(&c);
        const char *cn = (const char *)take(&c, nl);
        uint64_t l1 = take64(&c);
        const uint8_t *e = take(&c, l1);
        uint64_t l2 = take64(&c);
        const uint8_t *r = take(&c, l2);
        char cname[512];
        snprintf(cname, sizeof cname, "%.*s", (int)(nl < 511 ? nl : 511), cn);
        size_t wl = strlen(want);
        int match = want[wl - 1] == '/' ? strstr(cname, want) != NULL : strcmp(cname, want) == 0;
        if (!match || (raw && l2 <= rl)) continue;
        enc = e, el = l1, raw = r, rl = l2;
        snprintf(name, sizeof name, "%.*s", (int)(nl < 255 ? nl : 255), cn);
    }
    if (!raw) {
        fprintf(stderr, "bench: no case %s\n", want);
        exit(2);
    }
    uint8_t *in = bytelist(raw, rl), *block = bytelist(enc, el);
    uint64_t csize = 24 + 32 + rl + rl / 6, fsize = 24 + 10 + rl + 8 * ((rl + 65535) / 65536);
    uint8_t *scr = buffer(SCRATCH_FRAME), *cout = buffer(csize), *fout = buffer(fsize), *out = buffer(24 + rl);
    uint64_t *length = malloc(8), *consumed = malloc(8);
    wr64(scr, SCRATCH_FRAME);
    wr64(cout, csize);
    wr64(fout, fsize);
    wr64(out, 24 + rl);
    *length = rl;
    item it = {0};
    snprintf(it.name, sizeof it.name, "%s", name);
    it.bytes = rl;

    it.fn = F_COMPRESS, it.a = in, it.b = scr, it.c = cout;
    check(call(&it) == 0 && rd64(cout + 16) <= csize - 24, &it, "refused");
    add_item(&it);
    it.fn = F_UNCOMPRESS, it.a = block, it.b = out;
    check(call(&it) == 0 && !memcmp(out + 24, raw, (size_t)rl), &it, "wrong data");
    add_item(&it);
    it.fn = F_GET_LENGTH, it.a = block, it.b = (uint8_t *)length;
    check(call(&it) == 0 && *length == rl, &it, "wrong length");
    add_item(&it);
    it.fn = F_FRAME_COMPRESS, it.a = in, it.b = scr, it.c = fout;
    check(call(&it) == 0, &it, "refused");
    add_item(&it);
    uint8_t *framed = bytelist(fout + 24, rd64(fout + 16));
    it.fn = F_FRAME_UNCOMPRESS, it.a = framed, it.b = (uint8_t *)length, it.c = out, it.d = (uint8_t *)consumed;
    check(call(&it) == 0 && *consumed == rd64(fout + 16) && !memcmp(out + 24, raw, (size_t)rl), &it, "wrong data");
    add_item(&it);
}

static int run(const char *dir, int quick) {
    static vecfile vf[FILES];
    for (size_t i = 0; i < FILES; i++) load(&vf[i], dir, files[i]);
    char cpu[256];
    cpu_name(cpu, sizeof cpu);
    printf("asm-snappy bench\n");
    printf("os %s\nisa %s\ncpu %s\n", OS_NAME, ISA_NAME, cpu);
    printf("samples %d%s\n", quick ? QUICK_SAMPLES : SAMPLES, quick ? " quick" : "");
    for (size_t i = 0; i < FILES; i++) printf("file %s %s\n", files[i], vf[i].sha256);
    printf("function case bytes calls p25_ns median_ns p75_ns\n");
    fflush(stdout);
    for (size_t k = 0; k < WORKLOAD; k++) {
        size_t f = 0;
        while (strcmp(files[f], workload[k][0])) f++;
        bench_case(&vf[f], workload[k][1]);
    }

    settle();
    for (int i = 0; i < nitems; i++) calibrate(&items[i], quick ? QUICK_SAMPLE_NS : SAMPLE_NS);
    int rounds = quick ? 1 : ROUNDS, per_round = quick ? QUICK_SAMPLES : SAMPLES_PER_ROUND;
    for (int r = 0; r < rounds; r++)
        for (int i = 0; i < nitems; i++)
            for (int k = 0; k < per_round; k++) sample(&items[i]);
    if (refused) die("a call returned a refusal while timed");
    for (int i = 0; i < nitems; i++) {
        item *it = &items[i];
        qsort(it->t, (size_t)it->n, sizeof it->t[0], cmp_double);
        printf("%s %s %llu %llu %.1f %.1f %.1f\n", fn_name[it->fn], it->name, (unsigned long long)it->bytes,
               (unsigned long long)it->calls, it->t[it->n / 4], it->t[it->n / 2], it->t[(3 * it->n) / 4]);
    }
    return 0;
}

/* ---------------------------------------------------------------- Compare */

typedef struct {
    char fn[64], name[256];
    double p25, median, p75;
} row;

typedef struct {
    char header[8][320]; /* os, isa, cpu, samples, then the workload files */
    int nheader;
    row *rows;
    int nrows;
} results;

static void read_results(results *r, const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) {
        fprintf(stderr, "bench: cannot read %s\n", path);
        exit(2);
    }
    char line[1024];
    int in_rows = 0;
    memset(r, 0, sizeof *r);
    r->rows = calloc(4096, sizeof *r->rows);
    while (fgets(line, sizeof line, f)) {
        line[strcspn(line, "\r\n")] = 0;
        if (!strncmp(line, "function ", 9)) {
            in_rows = 1;
            continue;
        }
        if (!in_rows) {
            if ((!strncmp(line, "os ", 3) || !strncmp(line, "isa ", 4) || !strncmp(line, "cpu ", 4)
                 || !strncmp(line, "samples ", 8) || !strncmp(line, "file ", 5)) && r->nheader < 8)
                snprintf(r->header[r->nheader++], sizeof r->header[0], "%s", line);
            continue;
        }
        row *w = &r->rows[r->nrows];
        unsigned long long bytes, calls;
        if (r->nrows < 4096 && sscanf(line, "%63s %255s %llu %llu %lf %lf %lf", w->fn, w->name, &bytes, &calls,
                                      &w->p25, &w->median, &w->p75) == 7)
            r->nrows++;
    }
    fclose(f);
    if (!in_rows) die("not a results file");
}

static int compare(const char *base_path, const char *new_path) {
    results a, b;
    read_results(&a, base_path);
    read_results(&b, new_path);
    if (a.nheader != b.nheader) die("the two results have different headers");
    for (int i = 0; i < a.nheader; i++) {
        if (!strncmp(a.header[i], "samples ", 8)) continue;
        if (strcmp(a.header[i], b.header[i])) {
            fprintf(stderr, "bench: the runs differ: \"%s\" and \"%s\"\n", a.header[i], b.header[i]);
            fprintf(stderr, "bench: compare runs from the same machine and workload only\n");
            return 2;
        }
    }
    int faster = 0, slower = 0, same = 0;
    printf("%-30s %-56s %12s %12s %7s  %s\n", "function", "case", "base_ns", "new_ns", "ratio", "result");
    for (int i = 0; i < a.nrows; i++) {
        const row *x = &a.rows[i], *y = NULL;
        for (int j = 0; j < b.nrows && !y; j++)
            if (!strcmp(x->fn, b.rows[j].fn) && !strcmp(x->name, b.rows[j].name)) y = &b.rows[j];
        if (!y) continue;
        const char *verdict = "within noise";
        if (y->p75 < x->p25 && x->median >= y->median * (1 + MIN_CHANGE)) verdict = "faster", faster++;
        else if (y->p25 > x->p75 && y->median >= x->median * (1 + MIN_CHANGE)) verdict = "slower", slower++;
        else same++;
        printf("%-30s %-56s %12.1f %12.1f %7.3f  %s\n", x->fn, x->name, x->median, y->median, x->median / y->median,
               verdict);
    }
    printf("faster %d, slower %d, within noise %d\n", faster, slower, same);
    return 0;
}

int main(int argc, char **argv) {
    if (argc >= 3 && !strcmp(argv[1], "run")) return run(argv[2], argc >= 4 && !strcmp(argv[3], "--quick"));
    if (argc == 4 && !strcmp(argv[1], "compare")) return compare(argv[2], argv[3]);
    fprintf(stderr, "usage: bench run VECTOR_DIR [--quick]\n       bench compare BASE NEW\n");
    return 2;
}
