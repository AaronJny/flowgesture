/* Minimal fake platform types for exercising the production monitor lifecycle.
   Not linked into the application and not evidence of private API compatibility. */
typedef long CFIndex;
typedef const void *CFArrayRef;
typedef unsigned io_service_t;
#define IO_OBJECT_NULL 0
#define FG_FIXTURE_MAX_DEVICES 2
static int fake_handles[FG_FIXTURE_MAX_DEVICES];
static size_t fake_count = FG_FIXTURE_MAX_DEVICES;
static CFIndex CFArrayGetCount(CFArrayRef array) { (void)array; return (CFIndex)fake_count; }
static const void *CFArrayGetValueAtIndex(CFArrayRef array, CFIndex index) {
    (void)array; return &fake_handles[index];
}
static const void *CFRetain(const void *value) { return value; }
static void CFRelease(const void *value) { (void)value; }
static void IORegistryEntryGetRegistryEntryID(io_service_t service, uint64_t *value) {
    (void)service; *value = 0;
}
