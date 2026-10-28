#include "TouchDecode.h"
#include <math.h>
#include <string.h>

_Static_assert(sizeof(float) == 4, "Touch decoder requires 32-bit float");
_Static_assert(sizeof(double) == 8, "Touch decoder requires 64-bit double");

static uint32_t read_u32(const unsigned char *p, size_t offset) {
    uint32_t value; memcpy(&value, p + offset, sizeof(value)); return value;
}
static float read_float(const unsigned char *p, size_t offset) {
    float value; memcpy(&value, p + offset, sizeof(value)); return value;
}
static double bounded_coordinate(float value) {
    if (value < 0) return 0;
    if (value > 1) return 1;
    return (double)value;
}
bool FGDecodeTouchRecords(const void *records, size_t count, double timestamp,
                          FGTouchContact *out, size_t capacity) {
    if (!isfinite(timestamp) || timestamp < 0 || count > FG_MAX_CONTACTS ||
        count > capacity || (count && (!records || !out))) return false;
    const unsigned char *bytes = records;
    for (size_t i = 0; i < count; ++i) {
        const unsigned char *record = bytes + i * FG_MT_RECORD_BYTES;
        uint32_t state = read_u32(record, 20);
        int32_t identifier; memcpy(&identifier, record + 16, sizeof(identifier));
        float x = read_float(record, 32), y = read_float(record, 36);
        float quality = read_float(record, 48);
        /* Modest edge overshoot is allowed; arbitrary coordinates or phase
           values indicate an incompatible layout. Reject the whole frame. */
        if (state > 7 || identifier < 0 || !isfinite(x) || !isfinite(y) ||
            x < -0.25f || x > 1.25f || y < -0.25f || y > 1.25f ||
            !isfinite(quality) || quality < 0 || quality > 100) return false;
        for (size_t j = 0; j < i; ++j) {
            if (out[j].identifier == identifier) return false;
        }
        out[i] = (FGTouchContact){identifier, state, bounded_coordinate(x),
                                 bounded_coordinate(y), (double)quality};
    }
    return true;
}
