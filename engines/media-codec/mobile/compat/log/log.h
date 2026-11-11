// SPDX-License-Identifier: MIT
#pragma once
#include <android/log.h>
// AOSP's private security-event API is unavailable to NDK apps. Keep the
// upstream validation/early-return intact and report the same incident ID.
static inline int android_errorWriteLog(int tag, const char* issue) {
  return __android_log_print(ANDROID_LOG_ERROR,"TermPilotMedia","Malformed media rejected (tag=%d issue=%s)",tag,issue);
}
