// SPDX-License-Identifier: GPL-3.0-or-later

#import "ObjCExceptionCatcher.h"

#import <Foundation/Foundation.h>

bool ma2_try_objc(ma2_try_block_t block) {
    @try {
        block();
        return true;
    } @catch (NSException *exception) {
        NSLog(@"[obs-matanyone2] caught Objective-C exception: %@: %@", exception.name,
              exception.reason);
        return false;
    }
}
