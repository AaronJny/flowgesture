#ifndef FLOW_GESTURE_NATIVE_H
#define FLOW_GESTURE_NATIVE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* This header exposes only FlowGesture-owned values, not private Apple structs. */
typedef struct FGTouchMonitor FGTouchMonitor;

enum {
    FGTouchStatusStopped = 0,
    FGTouchStatusRunning = 1,
    FGTouchStatusNoDevices = 2,
    FGTouchStatusUnavailable = 3,
    FGTouchStatusFailed = 4,
    FGTouchStatusBusy = 5
};
enum { FGDeviceUnknown = 0, FGDeviceMouse = 1, FGDeviceTrackpad = 2 };
enum {
    FGIdentityUnknown = 0,
    FGIdentityProductName = 1,
    FGIdentityHIDUsage = 2
};

typedef struct {
    int32_t identifier;
    uint32_t state; /* 0...7 raw state; only 3 and 4 are active contacts. */
    double x;      /* Normalized 0...1, origin bottom-left. */
    double y;
    double quality; /* Contact quality, NOT calibrated force or pressure. */
} FGTouchContact;

typedef struct {
    uint64_t device_id; /* Opaque session identity; NOT a CGEvent sender ID. */
    double timestamp;
    uint64_t frame_number;
    const FGTouchContact *contacts; /* Borrowed until callback returns. */
    size_t contact_count;
    bool cancelled; /* Invalid/unsupported frame; reset recognition, do not fire. */
} FGTouchFrame;

typedef struct {
    uint64_t device_id;
    uint64_t registry_id; /* Zero means unavailable. */
    uint64_t multitouch_id; /* Separate private-framework identity namespace. */
    uint32_t kind;
    uint32_t classification_evidence;
    uint32_t vendor_id;
    uint32_t product_id;
    bool built_in_known;
    bool built_in;
    bool started;
    int32_t start_error;
    char product_name[128];
} FGTouchDeviceInfo;

typedef struct {
    uint64_t received_frames;
    uint64_t rejected_frames;
    size_t enumerated_devices;
    size_t started_devices;
    int32_t status;
} FGTouchDiagnostics;

/* Call management functions serially from the main thread. The callback is on
   a framework-owned thread and MUST NOT call Stop/Destroy/Start synchronously.
   Stop drains any callbacks already admitted; the context is safe to release
   after it returns. Only one monitor may run in a process at a time. */
typedef void (*FGTouchFrameCallback)(void *context, const FGTouchFrame *frame);
FGTouchMonitor *FGTouchMonitorCreate(FGTouchFrameCallback callback, void *context);
int32_t FGTouchMonitorStart(FGTouchMonitor *monitor);
void FGTouchMonitorStop(FGTouchMonitor *monitor);
void FGTouchMonitorDestroy(FGTouchMonitor *monitor);
size_t FGTouchMonitorDeviceCount(FGTouchMonitor *monitor);
bool FGTouchMonitorGetDevice(FGTouchMonitor *monitor, size_t index, FGTouchDeviceInfo *info);
FGTouchDiagnostics FGTouchMonitorGetDiagnostics(FGTouchMonitor *monitor);
void FGTouchMonitorCopyStatusMessage(FGTouchMonitor *monitor, char *buffer, size_t capacity);
/* Non-mutating enumeration; true means refresh is needed. */
bool FGTouchMonitorDevicesChanged(FGTouchMonitor *monitor);

/* Private symbols are optional. Null event / missing symbol / sender ID zero
   yields unknown. A zero sender is NEVER interpreted as a trackpad or mouse. */
typedef struct {
    uint64_t sender_id;
    uint32_t kind;
    uint32_t classification_evidence;
    uint32_t vendor_id;
    uint32_t product_id;
    bool sender_api_available;
    bool registry_found;
    char product_name[128];
} FGEventDeviceInfo;
uint64_t FGGetEventSenderID(const void *cg_event);
FGEventDeviceInfo FGGetSenderDeviceInfo(uint64_t sender_id);
FGEventDeviceInfo FGGetEventDeviceInfo(const void *cg_event);
bool FGEventSenderAPIAvailable(void);

#ifdef __cplusplus
}
#endif
#endif
