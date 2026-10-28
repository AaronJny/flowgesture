#include "FlowGestureNative.h"
#include "TouchDecode.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

static void put32(unsigned char *record, size_t offset, int32_t value) { memcpy(record + offset, &value, 4); }
static void putf(unsigned char *record, size_t offset, float value) { memcpy(record + offset, &value, 4); }
static void fill(unsigned char *record, int32_t id, int32_t state, float x, float y) {
    memset(record, 0, FG_MT_RECORD_BYTES);
    put32(record, 16, id); put32(record, 20, state);
    putf(record, 32, x); putf(record, 36, y); putf(record, 48, .5);
}
#if !defined(__APPLE__)
static void callback(void *context, const FGTouchFrame *frame) { (void)context; (void)frame; assert(0); }
#endif
int main(void) {
    unsigned char records[FG_MT_RECORD_BYTES * 2];
    FGTouchContact result[2];
    fill(records, 1, 3, .2, .8);
    fill(records + FG_MT_RECORD_BYTES, 42, 4, .7, .4);
    assert(FGDecodeTouchRecords(records, 2, 1.5, result, 2));
    assert(result[0].identifier == 1 && result[1].identifier == 42);
    assert(result[0].state == 3 && result[1].state == 4);
    assert(fabs(result[0].x - .2) < .00001 && fabs(result[0].y - .8) < .00001);
    assert(FGDecodeTouchRecords(NULL, 0, 2, NULL, 0));
    assert(!FGDecodeTouchRecords(NULL, 1, 2, result, 2));
    assert(!FGDecodeTouchRecords(records, 65, 2, result, 2));
    assert(!FGDecodeTouchRecords(records, 2, 2, result, 1));
    assert(!FGDecodeTouchRecords(records, 2, NAN, result, 2));
    assert(!FGDecodeTouchRecords(records, 2, -1, result, 2));
    fill(records + FG_MT_RECORD_BYTES, 1, 4, .7, .4);
    assert(!FGDecodeTouchRecords(records, 2, 2, result, 2));
    fill(records, -1, 3, .2, .8);
    assert(!FGDecodeTouchRecords(records, 1, 2, result, 2));
    fill(records, 1, 8, .2, .8);
    assert(!FGDecodeTouchRecords(records, 1, 2, result, 2));
    fill(records, 1, 3, INFINITY, .8);
    assert(!FGDecodeTouchRecords(records, 1, 2, result, 2));
    fill(records, 1, 3, -.3, .8);
    assert(!FGDecodeTouchRecords(records, 1, 2, result, 2));
    fill(records, 1, 3, -.1, 1.1);
    assert(FGDecodeTouchRecords(records, 1, 2, result, 2));
    assert(result[0].x == 0 && result[0].y == 1);
    putf(records, 48, NAN);
    assert(!FGDecodeTouchRecords(records, 1, 2, result, 2));
    #if !defined(__APPLE__)
    FGTouchMonitor *monitor = FGTouchMonitorCreate(callback, NULL);
    assert(monitor);
    assert(FGTouchMonitorStart(monitor) == FGTouchStatusUnavailable);
    assert(FGTouchMonitorGetDiagnostics(monitor).status == FGTouchStatusUnavailable);
    assert(FGTouchMonitorDeviceCount(monitor) == 0);
    assert(!FGTouchMonitorDevicesChanged(monitor));
    assert(!FGEventSenderAPIAvailable());
    assert(FGGetEventDeviceInfo(NULL).kind == FGDeviceUnknown);
    assert(FGGetEventDeviceInfo(NULL).sender_id == 0);
    FGTouchMonitorStop(monitor);
    assert(FGTouchMonitorGetDiagnostics(monitor).status == FGTouchStatusStopped);
    FGTouchMonitorDestroy(monitor);
    #endif
    puts("PASS: touch ABI decoder checks (and unavailable/unknown stubs on non-macOS)");
}
