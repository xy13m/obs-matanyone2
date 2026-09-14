// SPDX-License-Identifier: GPL-3.0-or-later

#ifndef OBJC_EXCEPTION_CATCHER_H
#define OBJC_EXCEPTION_CATCHER_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (^ma2_try_block_t)(void);

/* Runs block and returns false if it raises an NSException. Swift cannot catch
 * Objective-C exceptions, and Core ML raises them on some prediction failures. */
bool ma2_try_objc(ma2_try_block_t block);

#ifdef __cplusplus
}
#endif

#endif
