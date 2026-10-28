#ifndef FLOW_GESTURE_TOUCH_DECODE_H
#define FLOW_GESTURE_TOUCH_DECODE_H
#include "include/FlowGestureNative.h"

/* Facts of the observed 64-bit MultitouchSupport ABI, not a copied private
   header. Layout/stride is undocumented and must be validated on each OS. */
#define FG_MT_RECORD_BYTES 96u
#define FG_MAX_CONTACTS 64u
bool FGDecodeTouchRecords(const void *records, size_t count, double timestamp,
                          FGTouchContact *out, size_t capacity);
#endif
