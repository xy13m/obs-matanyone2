// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// Bootstrap placeholder. The Elgato 4K X capture benchmark (input, capture,
// dropped and matte rates plus latencies) is added together with the matting
// pipeline.
FileHandle.standardError.write(
    Data("matanyone2-benchmark: not implemented in this bootstrap build\n".utf8))
exit(2)
