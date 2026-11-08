#include <pthread.h>
#include <time.h>
#include <unistd.h>
/* Observe the production drain wait without changing its synchronization. */
static int observed_cond_wait(pthread_cond_t *, pthread_mutex_t *);
#define pthread_cond_wait observed_cond_wait
#define FG_NATIVE_TEST 1
#include "../../Sources/FlowGestureNative/FlowGestureNative.c"
#undef pthread_cond_wait
#include <assert.h>

static MTFrameFunction callbacks[2];
static unsigned starts[2], stops[2], registrations[2], unregistrations[2];
static int32_t errors[2];
static uint64_t delivered[16];
static size_t delivered_count;
static size_t index_of(MTHandle handle) { return handle == &fake_handles[0] ? 0 : 1; }
static CFArrayRef fake_list(void) { return fake_handles; }
static void fake_register(MTHandle handle, MTFrameFunction callback) {
    size_t i = index_of(handle); callbacks[i] = callback; ++registrations[i];
    callback(handle, NULL, 0, 1, 1); /* Registration may call back synchronously. */
}
static void fake_unregister(MTHandle handle, MTFrameFunction callback) {
    size_t i = index_of(handle); assert(callbacks[i] == callback);
    ++unregistrations[i]; callbacks[i] = NULL;
}
static int32_t fake_start(MTHandle handle, int mode) {
    (void)mode; size_t i = index_of(handle); ++starts[i];
    callbacks[i](handle, NULL, 0, 2, 2); /* Even a failed start may emit frames. */
    return errors[i];
}
static int32_t fake_stop(MTHandle handle) { ++stops[index_of(handle)]; return 0; }
static void load_runtime(void) {
    runtime.create_list = fake_list;
    runtime.register_frame = fake_register;
    runtime.unregister_frame = fake_unregister;
    runtime.start = fake_start;
    runtime.stop = fake_stop;
    runtime.available = true;
}
static void describe_device(MTHandle handle, FGTouchDeviceInfo *info) {
    (void)handle; memset(info, 0, sizeof(*info)); info->device_id = next_session_device_id++;
}
static void receive(void *context, const FGTouchFrame *frame) {
    (void)context; assert(delivered_count < 16); delivered[delivered_count++] = frame->device_id;
}
/* Management stays on the main test thread; workers simulate only framework
   callbacks and the controller that releases a deliberately blocked callback. */
static pthread_mutex_t gate_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gate_changed = PTHREAD_COND_INITIALIZER;
static bool callback_entered, callback_release, callback_finished, drain_wait_seen;
static bool observe_drain;
static size_t concurrent_deliveries;
static FGTouchMonitor *concurrent_monitor;

static void wait_for_flag(bool *flag) {
    struct timespec deadline;
    assert(timespec_get(&deadline, TIME_UTC) == TIME_UTC);
    deadline.tv_sec += 5;
    while (!*flag) {
        assert(pthread_cond_timedwait(&gate_changed, &gate_lock, &deadline) == 0);
    }
}
static int observed_cond_wait(pthread_cond_t *condition, pthread_mutex_t *mutex) {
    if (condition == &callbacks_drained && observe_drain) {
        pthread_mutex_lock(&gate_lock);
        drain_wait_seen = true;
        pthread_cond_broadcast(&gate_changed);
        pthread_mutex_unlock(&gate_lock);
    }
    return pthread_cond_wait(condition, mutex);
}
static void blocked_receive(void *context, const FGTouchFrame *frame) {
    (void)context; (void)frame;
    pthread_mutex_lock(&gate_lock);
    ++concurrent_deliveries;
    callback_entered = true;
    pthread_cond_broadcast(&gate_changed);
    wait_for_flag(&callback_release);
    callback_finished = true;
    pthread_cond_broadcast(&gate_changed);
    pthread_mutex_unlock(&gate_lock);
}
static void *emit_blocked_frame(void *unused) {
    (void)unused;
    receive_frame(&fake_handles[0], NULL, 0, 10, 10);
    return NULL;
}
static void *release_during_stop(void *unused) {
    (void)unused;
    pthread_mutex_lock(&gate_lock);
    wait_for_flag(&drain_wait_seen);
    assert(!callback_finished);
    pthread_mutex_unlock(&gate_lock);
    /* Obtaining state_lock proves Stop released it inside the drain wait.
       Records must still exist until the admitted callback returns. */
    pthread_mutex_lock(&state_lock);
    assert(active_monitor == NULL);
    assert(concurrent_monitor->count == 2);
    assert(concurrent_monitor->devices != NULL);
    assert(concurrent_monitor->in_flight == 1);
    pthread_mutex_unlock(&state_lock);
    /* A framework callback already scheduled before unregister must be denied. */
    receive_frame(&fake_handles[1], NULL, 0, 11, 11);
    pthread_mutex_lock(&gate_lock);
    assert(concurrent_deliveries == 1);
    callback_release = true;
    pthread_cond_broadcast(&gate_changed);
    pthread_mutex_unlock(&gate_lock);
    return NULL;
}
static void reset_concurrent_gate(void) {
    callback_entered = callback_release = callback_finished = drain_wait_seen = false;
    concurrent_deliveries = 0;
}
static void test_stop_drains_callback(void) {
    reset_concurrent_gate();
    errors[0] = errors[1] = 0;
    concurrent_monitor = FGTouchMonitorCreate(blocked_receive, NULL);
    assert(FGTouchMonitorStart(concurrent_monitor) == FGTouchStatusRunning);
    pthread_t emitter, controller;
    assert(pthread_create(&emitter, NULL, emit_blocked_frame, NULL) == 0);
    pthread_mutex_lock(&gate_lock);
    wait_for_flag(&callback_entered);
    pthread_mutex_unlock(&gate_lock);
    observe_drain = true;
    assert(pthread_create(&controller, NULL, release_during_stop, NULL) == 0);
    FGTouchMonitorStop(concurrent_monitor);
    observe_drain = false;
    assert(pthread_join(emitter, NULL) == 0);
    assert(pthread_join(controller, NULL) == 0);
    assert(callback_finished && drain_wait_seen);
    assert(concurrent_monitor->devices == NULL && concurrent_monitor->count == 0);
    assert(concurrent_monitor->in_flight == 0);
    receive_frame(&fake_handles[0], NULL, 0, 12, 12);
    assert(concurrent_deliveries == 1);
    FGTouchMonitorDestroy(concurrent_monitor);
}
static void test_retry_does_not_drain_healthy_callback(void) {
    reset_concurrent_gate();
    errors[0] = 0; errors[1] = -7;
    concurrent_monitor = FGTouchMonitorCreate(blocked_receive, NULL);
    assert(FGTouchMonitorStart(concurrent_monitor) == FGTouchStatusRunning);
    unsigned healthy_starts = starts[0], healthy_stops = stops[0];
    uint64_t healthy_id = concurrent_monitor->devices[0].info.device_id;
    pthread_t emitter;
    assert(pthread_create(&emitter, NULL, emit_blocked_frame, NULL) == 0);
    pthread_mutex_lock(&gate_lock);
    wait_for_flag(&callback_entered);
    pthread_mutex_unlock(&gate_lock);
    errors[1] = 0;
    /* The callback cannot finish until after this returns. A global drain here
       deadlocks, and the bounded test watchdog fails rather than hanging CI. */
    assert(FGTouchMonitorRetryFailedDevices(concurrent_monitor) == FGTouchStatusRunning);
    assert(starts[0] == healthy_starts && stops[0] == healthy_stops);
    assert(concurrent_monitor->devices[0].info.device_id == healthy_id);
    pthread_mutex_lock(&state_lock);
    assert(concurrent_monitor->in_flight == 1);
    assert(concurrent_monitor->devices[0].in_flight == 1);
    assert(concurrent_monitor->devices[1].info.started);
    pthread_mutex_unlock(&state_lock);
    pthread_mutex_lock(&gate_lock);
    assert(!callback_finished && concurrent_deliveries == 1);
    callback_release = true;
    pthread_cond_broadcast(&gate_changed);
    pthread_mutex_unlock(&gate_lock);
    assert(pthread_join(emitter, NULL) == 0);
    assert(callback_finished);
    FGTouchMonitorDestroy(concurrent_monitor);
}
int main(void) {
    alarm(20); /* Hard bound also covers mutex/join regressions. */
    FGTouchMonitor *monitor = FGTouchMonitorCreate(receive, NULL);
    assert(FGTouchMonitorRetryFailedDevices(monitor) == FGTouchStatusStopped);
    errors[1] = -7;
    assert(FGTouchMonitorStart(monitor) == FGTouchStatusRunning);
    assert(delivered_count == 0); /* No frames admitted before start result. */
    FGTouchDeviceInfo healthy, failed, retried;
    assert(FGTouchMonitorGetDevice(monitor, 0, &healthy));
    assert(FGTouchMonitorGetDevice(monitor, 1, &failed));
    assert(healthy.started && !failed.started && failed.start_error == -7);
    callbacks[0](&fake_handles[0], NULL, 0, 3, 3);
    assert(delivered_count == 1 && delivered[0] == healthy.device_id);
    assert(FGTouchMonitorRetryFailedDevices(monitor) == FGTouchStatusRunning);
    assert(FGTouchMonitorGetDevice(monitor, 1, &retried));
    assert(retried.device_id != failed.device_id && !retried.started);
    assert(delivered_count == 1);
    uint64_t retry_id = retried.device_id;
    errors[1] = 0;
    assert(FGTouchMonitorRetryFailedDevices(monitor) == FGTouchStatusRunning);
    assert(FGTouchMonitorGetDevice(monitor, 1, &retried));
    assert(retried.started && retried.device_id != retry_id);
    assert(starts[0] == 1 && registrations[0] == 1 && stops[0] == 0 && unregistrations[0] == 0);
    callbacks[0](&fake_handles[0], NULL, 0, 4, 4);
    callbacks[1](&fake_handles[1], NULL, 0, 4, 4);
    assert(delivered[1] == healthy.device_id && delivered[2] == retried.device_id);
    assert(FGTouchMonitorRetryFailedDevices(monitor) == FGTouchStatusRunning);
    assert(starts[0] == 1 && starts[1] == 3);
    FGTouchDiagnostics diagnostics = FGTouchMonitorGetDiagnostics(monitor);
    assert(diagnostics.started_devices == 2 && diagnostics.received_frames == 3);
    FGTouchMonitorStop(monitor);
    receive_frame(&fake_handles[0], NULL, 0, 5, 5);
    assert(delivered_count == 3);
    assert(FGTouchMonitorRetryFailedDevices(monitor) == FGTouchStatusStopped);
    /* Entirely failed monitors also recover without re-enumeration. */
    errors[0] = -1; errors[1] = -1;
    assert(FGTouchMonitorStart(monitor) == FGTouchStatusFailed);
    errors[0] = 0; errors[1] = 0;
    assert(FGTouchMonitorRetryFailedDevices(monitor) == FGTouchStatusRunning);
    FGTouchMonitorDestroy(monitor);
    test_stop_drains_callback();
    test_retry_does_not_drain_healthy_callback();
    alarm(0);
    puts("Native failed-device retry and concurrent drain tests passed.");
    return 0;
}
