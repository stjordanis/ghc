/* ---------------------------------------------------------------------------
 *
 * (c) The GHC Team, 2001-2005
 *
 * Catching long lock-acquisition pauses.
 *
 * --------------------------------------------------------------------------*/


#include "PosixSource.h"

#include "Rts.h"
#include "Trace.h"
#include "LongPause.h"

#if defined(THREADED_RTS)

void longPauseCb(uint64_t dur_ns STG_UNUSED) {
  trace(1, "LONG PAUSE %f", 1.0 * dur_ns / 1e9);
}

void ACQUIRE_LOCK_CHECKED_(Mutex *mutex, int max_msec) {
  struct timespec timeout;
  timeout.tv_sec = max_msec / 1000;
  timeout.tv_nsec = (max_msec % 1000) * 1000*1000;
  int ret = pthread_mutex_timedlock(mutex, &timeout);
  if (ret == 0) {
    return;
  } else if (ret == ETIMEDOUT) {
    longPauseCb(max_msec * 1e6);
    ACQUIRE_LOCK(mutex);
  } else {
    barf("ACQUIRE_LOCK_CHECKED_: error %d", ret);
  }
}

#endif

