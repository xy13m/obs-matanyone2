// SPDX-License-Identifier: GPL-3.0-or-later

#ifndef MATANYONE2_BRIDGE_H
#define MATANYONE2_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void *ma2_context_t;

/* Loads the six compiled Core ML models from models_directory, which must
 * contain manifest.json. Returns NULL when loading fails. Loading takes
 * seconds on the first run while the Neural Engine specializes the models. */
ma2_context_t ma2_create(const char *models_directory);
void ma2_destroy(ma2_context_t context);

/* Working resolution the models were exported at, in pixels. */
int32_t ma2_working_width(ma2_context_t context);
int32_t ma2_working_height(ma2_context_t context);

#ifdef __cplusplus
}
#endif

#endif
