#include "include/FlowGestureNative.h"
#include "TouchDecode.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(__APPLE__)
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <IOKit/hid/IOHIDUsageTables.h>
#include <ctype.h>
#include <dlfcn.h>
#include <pthread.h>

/* Runtime declarations of interoperable signatures; no private headers or
   implementation sources are vendored. See docs/touch-device-validation.md. */
typedef const void *MTHandle;
typedef void (*MTFrameFunction)(MTHandle, const void *, size_t, double, size_t);
typedef struct {
    void *library;
    CFArrayRef (*create_list)(void);
    void (*register_frame)(MTHandle, MTFrameFunction);
    void (*unregister_frame)(MTHandle, MTFrameFunction);
    int32_t (*start)(MTHandle, int);
    int32_t (*stop)(MTHandle);
    int32_t (*get_id)(MTHandle, uint64_t *);
    io_service_t (*get_service)(MTHandle);
    bool (*is_built_in)(MTHandle);
    bool available;
    char error[192];
} MTRuntime;
static MTRuntime runtime;
static pthread_once_t runtime_once = PTHREAD_ONCE_INIT;
static pthread_mutex_t state_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t callbacks_drained = PTHREAD_COND_INITIALIZER;
static FGTouchMonitor *active_monitor;
static uint64_t next_session_device_id = 1;

typedef struct {
    MTHandle handle; /* Explicitly retained for the registration lifetime. */
    FGTouchDeviceInfo info;
    bool registered;
} DeviceRecord;
struct FGTouchMonitor {
    FGTouchFrameCallback callback;
    void *context;
    DeviceRecord *devices;
    size_t count;
    size_t in_flight;
    FGTouchDiagnostics diagnostics;
    char message[256];
};

static void load_runtime(void) {
    runtime.library = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY | RTLD_LOCAL);
    if (!runtime.library) {
        snprintf(runtime.error, sizeof(runtime.error), "MultitouchSupport is unavailable on this system.");
        return;
    }
#define MT_LOAD(field, name) do { \
    void *symbol = dlsym(runtime.library, name); \
    _Static_assert(sizeof(runtime.field) == sizeof(symbol), "Unsupported function-pointer ABI"); \
    memcpy(&runtime.field, &symbol, sizeof(symbol)); \
} while (0)
    MT_LOAD(create_list, "MTDeviceCreateList");
    MT_LOAD(register_frame, "MTRegisterContactFrameCallback");
    MT_LOAD(unregister_frame, "MTUnregisterContactFrameCallback");
    MT_LOAD(start, "MTDeviceStart");
    MT_LOAD(stop, "MTDeviceStop");
    MT_LOAD(get_id, "MTDeviceGetDeviceID");
    MT_LOAD(get_service, "MTDeviceGetService");
    MT_LOAD(is_built_in, "MTDeviceIsBuiltIn");
#undef MT_LOAD
    runtime.available = runtime.create_list && runtime.register_frame &&
        runtime.unregister_frame && runtime.start && runtime.stop;
    if (!runtime.available) {
        snprintf(runtime.error, sizeof(runtime.error), "Required multitouch symbols are missing; touch capture was not started.");
    }
    /* Never dlclose: already scheduled framework callbacks must not jump into
       unloaded code. This is one bounded process-lifetime system-library load. */
}

static bool number_value(CFTypeRef object, uint32_t *out) {
    int64_t value = 0;
    if (!object || CFGetTypeID(object) != CFNumberGetTypeID() ||
        !CFNumberGetValue((CFNumberRef)object, kCFNumberSInt64Type, &value) ||
        value < 0 || value > UINT32_MAX) return false;
    *out = (uint32_t)value;
    return true;
}
static uint32_t dictionary_number(CFDictionaryRef dictionary, CFStringRef key) {
    uint32_t value = 0;
    number_value(CFDictionaryGetValue(dictionary, key), &value);
    return value;
}
static CFTypeRef copy_property(io_registry_entry_t entry, CFStringRef key) {
    return IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0);
}
static void collect_usage(uint32_t page, uint32_t usage, bool *mouse,
                          bool *trackpad, bool *digitizer) {
    if (page == kHIDPage_GenericDesktop && usage == kHIDUsage_GD_Mouse) *mouse = true;
    if (page == kHIDPage_Digitizer) {
        *digitizer = true;
        if (usage == kHIDUsage_Dig_TouchPad) *trackpad = true;
    }
}
static void registry_description(io_registry_entry_t entry, uint32_t *kind,
                                 uint32_t *evidence, uint32_t *vendor,
                                 uint32_t *product, char *name, size_t name_capacity) {
    bool mouse_usage = false, trackpad_usage = false, digitizer_usage = false;
    bool multitouch_class = false;
    io_registry_entry_t current = entry;
    IOObjectRetain(current);
    /* Bounded traversal across the sender's own ancestor chain. Never search
       all hardware or infer that an unidentified event came from the mouse. */
    for (unsigned depth = 0; current && depth < 12; ++depth) {
        CFTypeRef property = copy_property(current, CFSTR(kIOHIDProductKey));
        if (!name[0] && property && CFGetTypeID(property) == CFStringGetTypeID()) {
            CFStringGetCString((CFStringRef)property, name, (CFIndex)name_capacity, kCFStringEncodingUTF8);
        }
        if (property) CFRelease(property);
        property = copy_property(current, CFSTR(kIOHIDVendorIDKey));
        if (!*vendor) number_value(property, vendor);
        if (property) CFRelease(property);
        property = copy_property(current, CFSTR(kIOHIDProductIDKey));
        if (!*product) number_value(property, product);
        if (property) CFRelease(property);
        uint32_t page = 0, usage = 0;
        property = copy_property(current, CFSTR(kIOHIDPrimaryUsagePageKey));
        number_value(property, &page);
        if (property) CFRelease(property);
        property = copy_property(current, CFSTR(kIOHIDPrimaryUsageKey));
        number_value(property, &usage);
        if (property) CFRelease(property);
        collect_usage(page, usage, &mouse_usage, &trackpad_usage, &digitizer_usage);
        property = copy_property(current, CFSTR(kIOHIDDeviceUsagePairsKey));
        if (property && CFGetTypeID(property) == CFArrayGetTypeID()) {
            CFArrayRef pairs = (CFArrayRef)property;
            CFIndex count = CFArrayGetCount(pairs);
            if (count > 128) count = 128;
            for (CFIndex i = 0; i < count; ++i) {
                CFTypeRef item = CFArrayGetValueAtIndex(pairs, i);
                if (item && CFGetTypeID(item) == CFDictionaryGetTypeID()) {
                    CFDictionaryRef pair = (CFDictionaryRef)item;
                    collect_usage(dictionary_number(pair, CFSTR(kIOHIDDeviceUsagePageKey)),
                                  dictionary_number(pair, CFSTR(kIOHIDDeviceUsageKey)),
                                  &mouse_usage, &trackpad_usage, &digitizer_usage);
                }
            }
        }
        if (property) CFRelease(property);
        io_name_t class_name = {0};
        if (IOObjectGetClass(current, class_name) == KERN_SUCCESS &&
            (strstr(class_name, "Multitouch") || strstr(class_name, "Trackpad"))) multitouch_class = true;
        io_registry_entry_t parent = IO_OBJECT_NULL;
        if (IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) != KERN_SUCCESS) parent = IO_OBJECT_NULL;
        IOObjectRelease(current);
        current = parent;
    }
    if (current) IOObjectRelease(current);
    char lower[128] = {0};
    for (size_t i = 0; name[i] && i + 1 < sizeof(lower); ++i) lower[i] = (char)tolower((unsigned char)name[i]);
    if (strstr(lower, "trackpad") || strstr(lower, "touchpad")) {
        *kind = FGDeviceTrackpad; *evidence = FGIdentityProductName;
    } else if (trackpad_usage) {
        *kind = FGDeviceTrackpad; *evidence = FGIdentityHIDUsage;
    } else if (strstr(lower, "mouse")) {
        *kind = FGDeviceMouse; *evidence = FGIdentityProductName;
    } else if (mouse_usage && !digitizer_usage && !multitouch_class) {
        *kind = FGDeviceMouse; *evidence = FGIdentityHIDUsage;
    }
}

static void describe_device(MTHandle handle, FGTouchDeviceInfo *info) {
    memset(info, 0, sizeof(*info));
    info->device_id = next_session_device_id++;
    if (runtime.get_id && runtime.get_id(handle, &info->multitouch_id) != 0) info->multitouch_id = 0;
    if (runtime.is_built_in) {
        info->built_in_known = true;
        info->built_in = runtime.is_built_in(handle);
    }
    io_service_t service = runtime.get_service ? runtime.get_service(handle) : IO_OBJECT_NULL;
    /* Get (not Copy/Create) returns a borrowed service. */
    if (service) {
        IORegistryEntryGetRegistryEntryID(service, &info->registry_id);
        registry_description(service, &info->kind, &info->classification_evidence,
                             &info->vendor_id, &info->product_id,
                             info->product_name, sizeof(info->product_name));
    }
}

static void receive_frame(MTHandle device, const void *records, size_t count,
                          double timestamp, size_t frame_number) {
    pthread_mutex_lock(&state_lock);
    FGTouchMonitor *monitor = active_monitor;
    uint64_t device_id = 0;
    if (monitor) {
        for (size_t i = 0; i < monitor->count; ++i) {
            if (monitor->devices[i].handle == device && monitor->devices[i].registered) {
                device_id = monitor->devices[i].info.device_id;
                break;
            }
        }
    }
    if (!monitor || !device_id) { pthread_mutex_unlock(&state_lock); return; }
    ++monitor->in_flight;
    ++monitor->diagnostics.received_frames;
    pthread_mutex_unlock(&state_lock);

    FGTouchContact contacts[FG_MAX_CONTACTS];
    bool valid = FGDecodeTouchRecords(records, count, timestamp, contacts, FG_MAX_CONTACTS);
    FGTouchFrame frame = { device_id, timestamp, (uint64_t)frame_number,
                           valid && count ? contacts : NULL, valid ? count : 0, !valid };
    if (!valid) {
        /* Do not export a NaN/invalid clock even on cancellation frames. */
        frame.timestamp = 0;
        pthread_mutex_lock(&state_lock);
        ++monitor->diagnostics.rejected_frames;
        pthread_mutex_unlock(&state_lock);
    }
    monitor->callback(monitor->context, &frame);
    pthread_mutex_lock(&state_lock);
    --monitor->in_flight;
    if (!monitor->in_flight) pthread_cond_broadcast(&callbacks_drained);
    pthread_mutex_unlock(&state_lock);
}

FGTouchMonitor *FGTouchMonitorCreate(FGTouchFrameCallback callback, void *context) {
    if (!callback) return NULL;
    FGTouchMonitor *monitor = calloc(1, sizeof(*monitor));
    if (monitor) {
        monitor->callback = callback;
        monitor->context = context;
        snprintf(monitor->message, sizeof(monitor->message), "Touch capture stopped.");
    }
    return monitor;
}
int32_t FGTouchMonitorStart(FGTouchMonitor *monitor) {
    if (!monitor) return FGTouchStatusFailed;
    pthread_once(&runtime_once, load_runtime);
    if (!runtime.available) {
        monitor->diagnostics.status = FGTouchStatusUnavailable;
        snprintf(monitor->message, sizeof(monitor->message), "%s", runtime.error);
        return monitor->diagnostics.status;
    }
    pthread_mutex_lock(&state_lock);
    if (active_monitor) {
        bool same = active_monitor == monitor;
        pthread_mutex_unlock(&state_lock);
        if (same) return monitor->diagnostics.status;
        monitor->diagnostics.status = FGTouchStatusBusy;
        snprintf(monitor->message, sizeof(monitor->message), "Another touch monitor is already active.");
        return FGTouchStatusBusy;
    }
    pthread_mutex_unlock(&state_lock);
    CFArrayRef list = runtime.create_list();
    if (!list) {
        monitor->diagnostics.status = FGTouchStatusNoDevices;
        snprintf(monitor->message, sizeof(monitor->message), "No multitouch devices were returned; reconnect a device or check Input Monitoring.");
        return monitor->diagnostics.status;
    }
    CFIndex count = CFArrayGetCount(list);
    if (count < 0 || count > 256) {
        CFRelease(list);
        monitor->diagnostics.status = FGTouchStatusFailed;
        snprintf(monitor->message, sizeof(monitor->message), "Unexpected device count; touch capture was not started.");
        return monitor->diagnostics.status;
    }
    monitor->devices = count ? calloc((size_t)count, sizeof(DeviceRecord)) : NULL;
    if (count && !monitor->devices) {
        CFRelease(list);
        monitor->diagnostics.status = FGTouchStatusFailed;
        snprintf(monitor->message, sizeof(monitor->message), "Insufficient memory for touch-device enumeration.");
        return monitor->diagnostics.status;
    }
    for (CFIndex i = 0; i < count; ++i) {
        MTHandle handle = CFArrayGetValueAtIndex(list, i);
        if (!handle) continue;
        bool duplicate = false;
        for (size_t j = 0; j < monitor->count; ++j) {
            if (monitor->devices[j].handle == handle) { duplicate = true; break; }
        }
        if (duplicate) continue;
        DeviceRecord *record = &monitor->devices[monitor->count++];
        record->handle = CFRetain(handle);
        describe_device(handle, &record->info);
    }
    CFRelease(list);
    pthread_mutex_lock(&state_lock);
    active_monitor = monitor;
    monitor->diagnostics.enumerated_devices = monitor->count;
    monitor->diagnostics.started_devices = 0;
    pthread_mutex_unlock(&state_lock);
    for (size_t i = 0; i < monitor->count; ++i) {
        DeviceRecord *record = &monitor->devices[i];
        pthread_mutex_lock(&state_lock);
        record->registered = true;
        pthread_mutex_unlock(&state_lock);
        runtime.register_frame(record->handle, receive_frame);
        record->info.start_error = runtime.start(record->handle, 0);
        record->info.started = record->info.start_error == 0;
        if (record->info.started) ++monitor->diagnostics.started_devices;
        else {
            runtime.unregister_frame(record->handle, receive_frame);
            runtime.stop(record->handle);
            pthread_mutex_lock(&state_lock);
            record->registered = false;
            pthread_mutex_unlock(&state_lock);
        }
    }
    monitor->diagnostics.status = monitor->diagnostics.started_devices ? FGTouchStatusRunning :
        (monitor->count ? FGTouchStatusFailed : FGTouchStatusNoDevices);
    snprintf(monitor->message, sizeof(monitor->message), "%zu of %zu multitouch devices started. Private API compatibility must be validated on this Mac.",
             monitor->diagnostics.started_devices, monitor->count);
    return monitor->diagnostics.status;
}
void FGTouchMonitorStop(FGTouchMonitor *monitor) {
    if (!monitor) return;
    pthread_mutex_lock(&state_lock);
    if (active_monitor == monitor) active_monitor = NULL;
    pthread_mutex_unlock(&state_lock);
    for (size_t i = 0; i < monitor->count; ++i) {
        DeviceRecord *record = &monitor->devices[i];
        if (record->registered) {
            runtime.unregister_frame(record->handle, receive_frame);
            runtime.stop(record->handle);
        }
    }
    pthread_mutex_lock(&state_lock);
    while (monitor->in_flight) pthread_cond_wait(&callbacks_drained, &state_lock);
    pthread_mutex_unlock(&state_lock);
    for (size_t i = 0; i < monitor->count; ++i) CFRelease(monitor->devices[i].handle);
    free(monitor->devices);
    monitor->devices = NULL;
    monitor->count = 0;
    monitor->diagnostics.enumerated_devices = 0;
    monitor->diagnostics.started_devices = 0;
    monitor->diagnostics.status = FGTouchStatusStopped;
    snprintf(monitor->message, sizeof(monitor->message), "Touch capture stopped.");
}
void FGTouchMonitorDestroy(FGTouchMonitor *monitor) {
    if (!monitor) return;
    FGTouchMonitorStop(monitor);
    free(monitor);
}
size_t FGTouchMonitorDeviceCount(FGTouchMonitor *monitor) { return monitor ? monitor->count : 0; }
bool FGTouchMonitorGetDevice(FGTouchMonitor *monitor, size_t index, FGTouchDeviceInfo *info) {
    if (!monitor || !info || index >= monitor->count) return false;
    *info = monitor->devices[index].info;
    return true;
}
FGTouchDiagnostics FGTouchMonitorGetDiagnostics(FGTouchMonitor *monitor) {
    pthread_mutex_lock(&state_lock);
    FGTouchDiagnostics result = monitor ? monitor->diagnostics : (FGTouchDiagnostics){0};
    pthread_mutex_unlock(&state_lock);
    return result;
}
void FGTouchMonitorCopyStatusMessage(FGTouchMonitor *monitor, char *buffer, size_t capacity) {
    if (buffer && capacity) snprintf(buffer, capacity, "%s", monitor ? monitor->message : "No touch monitor.");
}
bool FGTouchMonitorDevicesChanged(FGTouchMonitor *monitor) {
    if (!monitor) return false;
    pthread_once(&runtime_once, load_runtime);
    if (!runtime.available) return false;
    CFArrayRef list = runtime.create_list();
    if (!list) return monitor->count != 0;
    CFIndex count = CFArrayGetCount(list);
    bool changed = count < 0 || (size_t)count != monitor->count;
    for (CFIndex i = 0; !changed && i < count; ++i) {
        MTHandle handle = CFArrayGetValueAtIndex(list, i);
        uint64_t private_id = 0, registry_id = 0;
        if (runtime.get_id && runtime.get_id(handle, &private_id) != 0) private_id = 0;
        io_service_t service = runtime.get_service ? runtime.get_service(handle) : IO_OBJECT_NULL;
        if (service) IORegistryEntryGetRegistryEntryID(service, &registry_id);
        bool found = false;
        for (size_t j = 0; j < monitor->count; ++j) {
            DeviceRecord *record = &monitor->devices[j];
            if ((registry_id && registry_id == record->info.registry_id) ||
                (private_id && private_id == record->info.multitouch_id) ||
                (!registry_id && !private_id && handle == record->handle)) { found = true; break; }
        }
        if (!found) changed = true;
    }
    CFRelease(list);
    return changed;
}

typedef CFTypeRef (*CopyHIDEventFunction)(CGEventRef);
typedef uint64_t (*SenderIDFunction)(CFTypeRef);
static CopyHIDEventFunction copy_hid_event;
static SenderIDFunction get_sender_id;
static pthread_once_t sender_once = PTHREAD_ONCE_INIT;
static void load_sender_api(void) {
    void *graphics = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY | RTLD_LOCAL);
    void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_LOCAL);
    _Static_assert(sizeof(copy_hid_event) == sizeof(void *), "Unsupported function-pointer ABI");
    _Static_assert(sizeof(get_sender_id) == sizeof(void *), "Unsupported function-pointer ABI");
    if (graphics) {
        void *symbol = dlsym(graphics, "CGEventCopyIOHIDEvent");
        memcpy(&copy_hid_event, &symbol, sizeof(symbol));
    }
    if (iokit) {
        void *symbol = dlsym(iokit, "IOHIDEventGetSenderID");
        memcpy(&get_sender_id, &symbol, sizeof(symbol));
    }
    /* Same bounded process-lifetime load policy as MultitouchSupport. */
}
bool FGEventSenderAPIAvailable(void) {
    pthread_once(&sender_once, load_sender_api);
    return copy_hid_event && get_sender_id;
}
uint64_t FGGetEventSenderID(const void *cg_event) {
    if (!FGEventSenderAPIAvailable() || !cg_event) return 0;
    CFTypeRef hid_event = copy_hid_event((CGEventRef)cg_event);
    if (!hid_event) return 0;
    uint64_t sender = get_sender_id(hid_event);
    CFRelease(hid_event);
    return sender;
}
FGEventDeviceInfo FGGetSenderDeviceInfo(uint64_t sender_id) {
    FGEventDeviceInfo result = {0};
    result.sender_api_available = FGEventSenderAPIAvailable();
    result.sender_id = sender_id;
    if (!sender_id) return result;
    CFMutableDictionaryRef matching = IORegistryEntryIDMatching(sender_id);
    if (!matching) return result;
    /* IOServiceGetMatchingService consumes the matching dictionary. */
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, matching);
    if (!service) return result;
    result.registry_found = true;
    registry_description(service, &result.kind, &result.classification_evidence,
                         &result.vendor_id, &result.product_id,
                         result.product_name, sizeof(result.product_name));
    IOObjectRelease(service);
    return result;
}
FGEventDeviceInfo FGGetEventDeviceInfo(const void *cg_event) {
    return FGGetSenderDeviceInfo(FGGetEventSenderID(cg_event));
}

#else
/* Portable stubs allow decoder and explicit-unavailable behavior to be tested
   without pretending that Linux provides macOS hardware validation. */
struct FGTouchMonitor { int32_t status; };
FGTouchMonitor *FGTouchMonitorCreate(FGTouchFrameCallback callback, void *context) {
    (void)context;
    return callback ? calloc(1, sizeof(FGTouchMonitor)) : NULL;
}
int32_t FGTouchMonitorStart(FGTouchMonitor *monitor) {
    if (monitor) monitor->status = FGTouchStatusUnavailable;
    return FGTouchStatusUnavailable;
}
void FGTouchMonitorStop(FGTouchMonitor *monitor) { if (monitor) monitor->status = FGTouchStatusStopped; }
void FGTouchMonitorDestroy(FGTouchMonitor *monitor) { free(monitor); }
size_t FGTouchMonitorDeviceCount(FGTouchMonitor *monitor) { (void)monitor; return 0; }
bool FGTouchMonitorGetDevice(FGTouchMonitor *monitor, size_t index, FGTouchDeviceInfo *info) {
    (void)monitor; (void)index; (void)info; return false;
}
FGTouchDiagnostics FGTouchMonitorGetDiagnostics(FGTouchMonitor *monitor) {
    FGTouchDiagnostics result = {0}; result.status = monitor ? monitor->status : FGTouchStatusStopped; return result;
}
void FGTouchMonitorCopyStatusMessage(FGTouchMonitor *monitor, char *buffer, size_t capacity) {
    (void)monitor;
    if (buffer && capacity) snprintf(buffer, capacity, "Touch capture requires macOS.");
}
bool FGTouchMonitorDevicesChanged(FGTouchMonitor *monitor) { (void)monitor; return false; }
bool FGEventSenderAPIAvailable(void) { return false; }
uint64_t FGGetEventSenderID(const void *cg_event) { (void)cg_event; return 0; }
FGEventDeviceInfo FGGetSenderDeviceInfo(uint64_t sender_id) {
    FGEventDeviceInfo result = {0}; result.sender_id = sender_id; return result;
}
FGEventDeviceInfo FGGetEventDeviceInfo(const void *cg_event) { (void)cg_event; return (FGEventDeviceInfo){0}; }
#endif
