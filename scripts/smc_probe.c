// smc_probe.c — AppleSMC read/write probe for Cool Fan Control (Apple Silicon only).
// Build: cc -O2 -o smc_probe smc_probe.c -framework IOKit -framework CoreFoundation
// Usage:
//   smc_probe read [KEY ...]          read keys (defaults: fans + temps + battery)
//   smc_probe writeui8 <KEY> <0-255>  write a ui8 key (e.g. F0Md: 0=auto, 1=manual)
//   smc_probe writefpe2 <KEY> <rpm>   write an fpe2 key (e.g. F0Tg target RPM)
// NOTE: on macOS 26 all SMC calls require root (unprivileged → kIOReturnUnsupported).
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <IOKit/IOKitLib.h>

typedef struct { char major, minor, build, reserved[1]; uint16_t release; } SMCKeyData_vers_t;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCKeyData_pLimitData_t;
typedef struct { uint32_t dataSize; uint32_t dataType; char dataAttributes; } SMCKeyData_keyInfo_t;
typedef struct {
    uint32_t key;
    SMCKeyData_vers_t vers;
    SMCKeyData_pLimitData_t pLimitData;
    SMCKeyData_keyInfo_t keyInfo;
    char result;
    char status;
    char data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCKeyData_t;

static uint32_t fourcc(const char *s) { uint32_t v; memcpy(&v, s, 4); return v; }

static void show(const char *key, uint8_t *b, size_t n, uint32_t type) {
    char t[5] = {0}; memcpy(t, &type, 4);
    printf("%s [%s/%zu] = ", key, t, n);
    if (n == 1) printf("%u", b[0]);
    else if (n == 2 && !memcmp(t, "fpe", 3)) printf("%.0f", (float)((b[0] << 8) | b[1]) / 4.0f);
    else if (n == 2 && !memcmp(t, "sp7", 3)) { int16_t s = (int16_t)((b[0] << 8) | b[1]); printf("%.1f", (float)s / 256.0f); }
    else if (n == 4 && !memcmp(t, "flt", 3)) { float f; memcpy(&f, b, 4); printf("%g", f); }
    else { for (size_t i = 0; i < n; i++) printf("%02x", b[i]); }
    printf("\n");
}

static kern_return_t call(io_connect_t c, uint32_t sel, SMCKeyData_t *in, SMCKeyData_t *out) {
    size_t o = sizeof(*out);
    return IOConnectCallStructMethod(c, sel, in, sizeof(*in), out, &o);
}

int main(int argc, char **argv) {
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) { fprintf(stderr, "AppleSMC not found\n"); return 1; }
    io_connect_t conn = 0;
    if (IOServiceOpen(svc, mach_task_self(), 0, &conn) != kIOReturnSuccess) { fprintf(stderr, "IOServiceOpen failed\n"); return 1; }

    const char *cmd = argc > 1 ? argv[1] : "read";

    if (!strcmp(cmd, "read")) {
        const char *keys[] = {"FNum","F0Ac","F0Mn","F0Mx","F0Md","F0Tg","F1Ac","F1Mn","F1Mx","F1Md","F1Tg",
                              "TC0P","TCXC","TG0P","TM0P","TH0P","TH1P","TB0T","BT0C"};
        int count = argc > 2 ? argc - 2 : 19;
        for (int i = 0; i < count; i++) {
            const char *k = argc > 2 ? argv[i + 2] : keys[i];
            SMCKeyData_t in = {0}, out = {0};
            in.key = fourcc(k); in.data8 = 1;                 // selector 9: GET_KEY_INFO
            kern_return_t r = call(conn, 9, &in, &out);
            if (r != kIOReturnSuccess) { printf("%s = ERR(0x%x)\n", k, r); continue; }
            in.keyInfo = out.keyInfo;
            r = call(conn, 5, &in, &out);                     // selector 5: READ_KEYS
            if (r != kIOReturnSuccess) { printf("%s = ERR(0x%x)\n", k, r); continue; }
            show(k, out.bytes, out.keyInfo.dataSize, out.keyInfo.dataType);
        }
    } else if (!strcmp(cmd, "writeui8") || !strcmp(cmd, "writefpe2")) {
        if (argc < 4) { fprintf(stderr, "usage: %s %s <KEY> <value>\n", argv[0], cmd); return 2; }
        const char *k = argv[2];
        uint32_t val = (uint32_t)atoi(argv[3]);
        SMCKeyData_t in = {0}, out = {0};
        in.key = fourcc(k); in.data8 = 1;
        kern_return_t r = call(conn, 9, &in, &out);
        if (r != kIOReturnSuccess) { fprintf(stderr, "%s: keyInfo failed 0x%x\n", k, r); return 1; }
        in.keyInfo = out.keyInfo;
        size_t sz = out.keyInfo.dataSize;
        if (sz == 1) {
            in.bytes[0] = val & 0xff;
        } else if (sz == 2) {
            if (!strcmp(cmd, "writefpe2")) val *= 4;          // fpe2: 2 fractional bits
            in.bytes[0] = (val >> 8) & 0xff; in.bytes[1] = val & 0xff;
        } else { fprintf(stderr, "%s: unsupported dataSize %zu\n", k, sz); return 1; }
        r = call(conn, 6, &in, &out);                         // selector 6: WRITE_KEYS
        if (r != kIOReturnSuccess) { fprintf(stderr, "%s: write failed 0x%x\n", k, r); return 1; }
        printf("%s = written\n", k);
    } else { fprintf(stderr, "unknown cmd %s\n", cmd); return 2; }

    IOServiceClose(conn);
    return 0;
}
