// smc_probe.c — AppleSMC read/write probe for Cool Fan Control (Apple Silicon only).
// Build: cc -O2 -o smc_probe smc_probe.c -framework IOKit -framework CoreFoundation
// Usage:
//   smc_probe read [KEY ...]          read keys (defaults: fans + temps + battery)
//   smc_probe writeui8 <KEY> <0-255>  write a ui8 key (e.g. F0Md: 0=auto, 1=manual)
//   smc_probe writerpm <KEY> <rpm>     write an RPM using the key's actual type (flt/fpe2)
//
// Protocol (per beltex/SMCKit + hholzgra/smc): the IOConnectCallStructMethod selector
// is ALWAYS 2 (KERNEL_INDEX_SMC / kSMCHandleYPCEvent); the operation is encoded in the
// struct's data8 field: 9 = GET_KEY_INFO, 5 = READ_BYTES, 6 = WRITE_BYTES.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <IOKit/IOKitLib.h>

#define KERNEL_INDEX_SMC   2
#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_WRITE_BYTES 6
#define SMC_CMD_READ_KEYINFO 9

typedef struct { char major, minor, build, reserved[1]; uint16_t release; } SMCKeyData_vers_t;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCKeyData_pLimitData_t;
typedef struct __attribute__((packed)) { uint32_t dataSize; uint32_t dataType; char dataAttributes; } SMCKeyData_keyInfo_t;
typedef struct {
    uint32_t key;
    SMCKeyData_vers_t vers;
    SMCKeyData_pLimitData_t pLimitData;
    SMCKeyData_keyInfo_t keyInfo;
    uint16_t padding;             // ← SMCKit SMCParamStruct: padding after keyInfo (struct must be 80 bytes)
    char result;
    char status;
    char data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCKeyData_t;

_Static_assert(sizeof(SMCKeyData_t) == 80, "SMCKeyData_t must be 80 bytes");

static uint32_t fourcc(const char *s) {
    // AppleSMC expects the numeric FourCharCode in canonical big-endian order.
    // On little-endian Macs, memcpy("FNum") would produce the reversed integer.
    return ((uint32_t)(uint8_t)s[0] << 24) |
           ((uint32_t)(uint8_t)s[1] << 16) |
           ((uint32_t)(uint8_t)s[2] << 8)  |
           ((uint32_t)(uint8_t)s[3]);
}

static void show(const char *key, uint8_t *b, size_t n, uint32_t type) {
    char t[5] = {
        (char)((type >> 24) & 0xff), (char)((type >> 16) & 0xff),
        (char)((type >> 8) & 0xff), (char)(type & 0xff), 0
    };
    printf("%s [%s/%zu] = ", key, t, n);
    if (n == 1) printf("%u", b[0]);
    else if (n == 2 && !memcmp(t, "fpe", 3)) printf("%.0f", (float)((b[0] << 8) | b[1]) / 4.0f);
    else if (n == 2 && !memcmp(t, "sp7", 3)) { int16_t s = (int16_t)((b[0] << 8) | b[1]); printf("%.1f", (float)s / 256.0f); }
    else if (n == 4 && !memcmp(t, "flt", 3)) { float f; memcpy(&f, b, 4); printf("%g", f); }
    else { for (size_t i = 0; i < n; i++) printf("%02x", b[i]); }
    printf("\n");
}

static kern_return_t smc_call(io_connect_t c, SMCKeyData_t *in, SMCKeyData_t *out) {
    size_t o = sizeof(*out);
    return IOConnectCallStructMethod(c, KERNEL_INDEX_SMC, in, sizeof(*in), out, &o);
}

static int smc_read(io_connect_t conn, const char *k, uint8_t *bytes_out, size_t *size_out, uint32_t *type_out) {
    SMCKeyData_t in = {0}, out = {0};
    in.key = fourcc(k);
    in.data8 = SMC_CMD_READ_KEYINFO;                       // 9
    kern_return_t r = smc_call(conn, &in, &out);
    if (r != kIOReturnSuccess) return -1;                  // IOKit-level failure
    uint32_t dsize = out.keyInfo.dataSize, dtype = out.keyInfo.dataType;
    if (dsize == 0 || dsize > 32) return -2;               // key not present
    in.keyInfo.dataSize = dsize;
    in.data8 = SMC_CMD_READ_BYTES;                         // 5
    memset(&out, 0, sizeof(out));
    r = smc_call(conn, &in, &out);
    if (r != kIOReturnSuccess) return -3;
    if (out.result != 0) return -4;                        // driver-level error
    memcpy(bytes_out, out.bytes, dsize);
    *size_out = dsize; *type_out = dtype;
    return 0;
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
            uint8_t b[32]; size_t n = 0; uint32_t type = 0;
            int rc = smc_read(conn, k, b, &n, &type);
            if (rc == 0) show(k, b, n, type);
            else if (rc == -1) printf("%s = ERR(0x%x)\n", k, (unsigned)0);  // errno of last call
            else if (rc == -2) printf("%s = MISSING\n", k);
            else printf("%s = ERR\n", k);
        }
    } else if (!strcmp(cmd, "writeui8") || !strcmp(cmd, "writerpm")) {
        if (argc < 4) { fprintf(stderr, "usage: %s %s <KEY> <value>\n", argv[0], cmd); return 2; }
        const char *k = argv[2];
        uint32_t val = (uint32_t)atoi(argv[3]);
        SMCKeyData_t in = {0}, out = {0};
        in.key = fourcc(k);
        in.data8 = SMC_CMD_READ_KEYINFO;
        kern_return_t r = smc_call(conn, &in, &out);
        if (r != kIOReturnSuccess) { fprintf(stderr, "%s: keyInfo failed 0x%x\n", k, r); return 1; }
        in.keyInfo = out.keyInfo;
        size_t sz = out.keyInfo.dataSize;
        char type[5] = {
            (char)((out.keyInfo.dataType >> 24) & 0xff),
            (char)((out.keyInfo.dataType >> 16) & 0xff),
            (char)((out.keyInfo.dataType >> 8) & 0xff),
            (char)(out.keyInfo.dataType & 0xff), 0
        };
        if (!strcmp(cmd, "writeui8") && sz == 1) {
            in.bytes[0] = val & 0xff;
        } else if (!strcmp(cmd, "writerpm") && sz == 2 && !memcmp(type, "fpe2", 4)) {
            val *= 4;                                      // fpe2: 2 fractional bits, big-endian bytes
            in.bytes[0] = (val >> 8) & 0xff; in.bytes[1] = val & 0xff;
        } else if (!strcmp(cmd, "writerpm") && sz == 4 && !memcmp(type, "flt ", 4)) {
            float rpm = (float)val;                        // Apple Silicon fan keys use native IEEE754 float
            memcpy(in.bytes, &rpm, sizeof(rpm));
        } else {
            fprintf(stderr, "%s: unsupported command/type %s/%s (size=%zu)\n", k, cmd, type, sz);
            return 1;
        }
        in.data8 = SMC_CMD_WRITE_BYTES;                    // 6
        memset(&out, 0, sizeof(out));
        r = smc_call(conn, &in, &out);
        if (r != kIOReturnSuccess) { fprintf(stderr, "%s: write failed 0x%x\n", k, r); return 1; }
        if (out.result != 0) { fprintf(stderr, "%s: driver error %d\n", k, out.result); return 1; }
        printf("%s = written\n", k);
    } else { fprintf(stderr, "unknown cmd %s\n", cmd); return 2; }

    IOServiceClose(conn);
    return 0;
}
