# obs-matanyone2

An OBS Studio effect filter for Apple Silicon that removes the background
behind a person while keeping their office chair, microphone and boom arm in
the picture. It runs the MatAnyone 2 video matting model on the Neural Engine
through Core ML.

The filter is seeded once with everything that should stay visible (the
person plus the props) and then lets MatAnyone 2 track that set frame by
frame. There is no per-frame comparison against a clean plate and no
hard-coded geometry. The OBS render loop stays at 60 fps regardless of how
fast the matte is produced.

## Requirements

- Apple Silicon Mac. Development and measurements were done on a Mac mini
  with an M4 Pro.
- macOS 26 or newer.
- The current stable Xcode (26.x) with its command line tools. `swift`,
  `clang-format` and `swift-format` all come from the Xcode toolchain.
- OBS Studio 32.2.x installed at `/Applications/OBS.app`. The build fetches
  the libobs headers for the exact installed version.
- [`uv`](https://docs.astral.sh/uv/) for the model export. The setup script
  installs it with Homebrew when it is missing.
- Roughly 10 GB of free disk for the Python environment, the upstream
  checkout and the exported models on the first run.

## Install

Quit OBS and run:

```sh
scripts/setup-plugin.sh
```

The script is idempotent. It fetches the OBS headers matching the installed
OBS version, resolves the pinned Swift dependencies, exports and compiles the
Core ML models on the first run, builds and signs the plugin bundle, and
installs it as `~/Library/Application Support/obs-studio/plugins/obs-matanyone2-matting.plugin`.
The first run downloads the upstream MatAnyone2 source and weights and takes
much longer than later runs.

The stages can be run one at a time:

```sh
scripts/fetch-obs-sdk.sh
swift package resolve
scripts/export-models.sh
scripts/build-plugin.sh
scripts/install-plugin.sh
```

`scripts/export-models.sh` takes the working resolution from
`MA2_WORKING_WIDTH` and `MA2_WORKING_HEIGHT` (default 512 by 288). Both must be
multiples of 16. `scripts/build-plugin.sh` reads the same variables to pick
which exported model set goes into the bundle.

In OBS, add **MatAnyone 2 Matting** as an effect filter on the camera source.
If an **Apply LUT** filter converts S-Log3 to Rec.709, place it before this
filter so the matte is computed on the graded image. Put an image or video
source below the camera in the scene for the new background.

## Calibration

Calibration teaches the filter what the room looks like without you and
which objects should stay. It takes three button presses and about a
minute. Everything is stored on disk, so after an OBS restart the filter
seeds itself as soon as it sees you.

1. **Capture clean plate.** Press the button, then get out of the frame and
   take the chair, the microphone and the boom arm with you. After the
   countdown the filter averages a few frames of the empty room.
2. **Capture props plate.** Put the chair, microphone and boom arm back
   exactly where they are during calls, step out of the frame again and
   press the button. The difference between the two plates, cleaned up with
   morphology and a minimum region size, becomes the props mask. The status
   line reports how many separate regions were found; expect one per prop
   (a chair and a microphone on a boom arm usually give two or three).
3. **Seed tracker now.** Sit down and press the button. The person mask from
   Apple's Vision framework is combined with the props mask and handed to
   MatAnyone 2 as the initial target. From this point on the model tracks
   the union of you and the props.

Capture again after moving the camera, changing the lens or the framing, or
rearranging the room. A lighting change after calibration does not need a
recapture: the plates are only used to derive the props mask, never compared
against live frames.

If the chair is not in its props-plate position when you seed, the seed
covers a strip of background next to it and that strip stays visible. Put
the props back before seeding, or use **Re-seed now** after moving them.

### Re-seeding

The tracker's memory drifts over long sessions, and props sometimes move.
Two mechanisms refresh it without reloading the models:

- **Re-seed now** clears the memory and seeds again with the person from
  Vision plus the props where the tracker currently sees them. Use it when
  the boom arm or the chair moved, or when the matte has drifted.
- **Periodic re-seed interval** does the same automatically every N seconds
  (0 turns it off). It repairs drift in the person (a lost hand or hair
  after fast motion) while keeping the props wherever they are now.

What re-seeding cannot do: recover a prop the tracker has already lost, or
remove background that has already leaked into the matte. In both cases the
new seed is taken from the current output, so the mistake is carried over.
Press **Seed tracker now** with the props in their calibrated positions to
start from the calibration mask again.

The seed frame stays in the tracker's permanent memory. A prop that leaves
the frame and comes back to roughly the same place is usually picked up
again; one that comes back somewhere else needs a re-seed.

## Status and overlay

The top of the properties panel shows a read-only status line: the current
phase, the countdown, the matte rate, inference time, the matte's age (or the
added latency in aligned mode) and the last error. It refreshes while the
panel is open.

During calibration the same information is drawn as a band across the top of
the filter output so you can calibrate without looking at the panel. The
band is part of the video, so anything consuming the virtual camera sees it
too; turn **Show calibration overlay in output** off if that matters, or
**Overlay always visible** on to keep the status line in the picture while
tracking.

Every state change writes a line prefixed `[obs-matanyone2]` to the OBS log,
and a timing line follows every 120 predictions.

The five calibration actions are also hotkeys on the camera source
(Settings > Hotkeys, under the source's name), so they can be pressed
without the panel or triggered through obs-websocket.

## Settings

### Calibration

| Setting | Default | What it does |
|---|---|---|
| Capture clean plate | button | Countdown, then average frames of the empty room. |
| Capture props plate | button | Countdown, then average frames with the props in place. |
| Seed tracker now | button | Person from Vision plus the calibrated props mask. |
| Re-seed now | button | Person from Vision plus the props as the tracker sees them now. |
| Clear calibration | button | Delete the plates and the mask from disk; stop tracking. |
| Countdown | 3 s | Delay between pressing a capture button and the capture. |
| Plate averaging frames | 16 | Frames averaged per plate to reduce sensor noise. |
| Props difference threshold | 16 | Per-pixel difference (0 to 255) that counts as a prop. Raise it when background noise appears in the mask, lower it when parts of a prop are missing. |
| Minimum props region size | 64 px | Regions smaller than this many working-resolution pixels are discarded. |
| Periodic re-seed interval | 0 s | Automatic re-seed every N seconds; 0 is off. |

### Output quality

| Setting | Default | What it does |
|---|---|---|
| Edge refinement | Joint bilateral upsampling | How the 512x288 matte is upscaled to the frame. Joint bilateral upsampling and the guided filter use the full-resolution image to sharpen edges on the GPU. See the measurements below. |
| Edge feather / erode | 0 px | Negative values shrink the matte by that many working-resolution pixels; positive values soften the edge by that radius. |
| Temporal alpha smoothing | 0 | Weight of the previous matte blended into the new one. Reduces flicker, adds lag to fast motion. |
| Frame/matte alignment | Lowest latency | Lowest latency composites the newest frame with the newest matte. Aligned keeps recent frames on the GPU and composites each frame with its own matte; the output then follows the matte rate and the added latency is shown in the status line. |

### Performance

| Setting | Default | What it does |
|---|---|---|
| Compute units | CPU + Neural Engine | Where Core ML runs the models. Changing it reloads the models; calibration is kept. |
| Inference throttle | 0 fps | Maximum matte rate; 0 is unlimited. |
| Downscale on GPU before staging | on | Shrink the frame to the working resolution on the GPU and copy only that to the CPU. Off stages the full frame and downscales on the CPU; kept for comparison. |
| Remove tiny specks | on | Drop isolated islands smaller than a few dozen pixels from the matte. |

### Diagnostics

| Setting | Default | What it does |
|---|---|---|
| Show calibration overlay in output | on | Draw countdowns, steps and errors on the video. |
| Overlay always visible | off | Also show the status line while tracking. |
| Matte preview | Off | Show the matte as grey, or composite over a checkerboard, to judge edges. |
| Verbose logging | off | One log line per prediction instead of every 120. |

## Performance

Measured on a Mac mini M4 Pro, macOS 27.0, Xcode 26.6, CPU + Neural Engine,
release build, with the Core ML integration test (`swift test -c release
--filter CoreMLEngineIntegrationTests`, synthetic frames, twelve tracking
steps after the seed):

| Working resolution | Seed (10 warm-up steps) | Tracking step p50 | Verdict |
|---|---|---|---|
| 512x288 | 161 ms | 14.2 ms | default |
| 768x432 | 541 ms | 33.2 ms | below the 30 fps target; export it with `MA2_WORKING_WIDTH=768 MA2_WORKING_HEIGHT=432` if you want to try it |

The step time is the engine alone. In the plugin, preprocessing, the speck
filter, quantisation and queueing add about 1 ms at 512x288. With the camera
on (1080p60 into OBS, person plus chair and microphone seeded) the filter
ran at 55 to 57 matte fps with inference p50 16.6 ms and p95 21 ms, and OBS
reported 7 to 8 ms average render time per frame at 1080p60. The camera
benchmark (`scripts/run-benchmark.sh`, see below) saw 30 fps input from the
capture card and matched it: 29.6 matte fps, inference p50 22.9 ms, footprint
flat at 380 MB over 60 s.

Edge refinement was measured in OBS with obs-websocket's `GetStats` over 20 s
per mode (render time is the whole OBS frame, so the passes themselves are
within the noise):

| Edge refinement | Average render time | Skipped frames / 20 s | Edges |
|---|---|---|---|
| None | 7.8 to 8.3 ms | 0 to 1 | steps of the 512x288 grid visible on diagonal edges |
| Joint bilateral upsampling | 6.6 ms | 1 | cleanest; follows the microphone arm and cable |
| Guided filter | 7.8 ms | 1 | grey halos with the original radius 8 / eps 0.001; retuned to radius 4, eps 0.01 and limited to the band where the matte is uncertain, which removed the halos in an offline replay of the same frame |

Bilateral is therefore the default. The aligned mode adds about 69 ms
(four frames at 60 fps) with no change in render time or skipped frames.

## Benchmark

Quit OBS so the benchmark can own the capture card, then:

```sh
scripts/run-benchmark.sh                                   # 60 s, 512x288, CPU + ANE
scripts/run-benchmark.sh --models .build/models/768x432/MatAnyone
scripts/run-benchmark.sh --compute-units cpu_gpu --duration 30
scripts/run-benchmark.sh --capture-only                    # capture path only
```

On the first run macOS asks for camera access for your terminal. The tool
captures 1920x1080 at 60 fps, downscales each frame to the working resolution,
feeds the same worker the plugin uses, seeds with the person alone (or with a
plugin calibration directory passed as `--calibration`), and prints input,
dropped and matte rates, inference percentiles and end-to-end latency every
two seconds, then a summary. Sit in frame and move for the numbers to mean
anything. An input rate near 30 fps with the camera off is the capture card's
placeholder signal, not a plugin limit; a live source near 50 fps means the
camera is in PAL/50p.

## Troubleshooting

- **"No person detected" when seeding.** Vision did not find anyone covering
  at least 1 % of the frame. Sit in frame, facing the camera, and press Seed
  again. With the camera off (the capture card shows "NO SIGNAL") this is the
  expected result.
- **Props plate found 0 regions.** The props do not differ from the clean
  plate by more than the threshold, or the regions are smaller than the
  minimum size. Lower the threshold, or check that the props were out of the
  frame for the clean plate and in place for the props plate.
- **A prop disappears after a while.** Press Re-seed now (props stay where
  they are) or Seed tracker now (props back in calibrated positions). Enable
  the periodic re-seed if it keeps happening.
- **Background leaks in next to the chair.** The chair was not in its
  calibrated position at seed time. Put it back and press Seed tracker now.
- **The filter passes the video through unchanged.** It does that whenever
  it is not tracking: look at the status line. "Loading MatAnyone 2 models"
  takes a few seconds after OBS starts; the first load after an export takes
  longer while the Neural Engine specialises the models.
- **The plugin is not listed.** Check the OBS log for `[obs-matanyone2]`. A
  missing models directory is reported there; run `scripts/export-models.sh`
  and `scripts/build-plugin.sh` again.
- **The properties panel jumps while dragging a slider.** The status line
  refreshes twice a second during calibration and every two seconds while
  tracking; wait for the countdown to finish before adjusting sliders.

## Manual test checklist

Run with the camera on, in the usual seating position. Record the result of
each item in this table.

| Scenario | Expected | Result |
|---|---|---|
| Lean left and right, forward and back | Person and chair stay complete | not run yet (camera had no signal during development) |
| Turn the head and the torso | No holes in hair or shoulders | not run yet |
| Stand up and sit down | Person tracked while standing; chair stays | not run yet |
| Rotate the chair | Chair stays visible through the rotation | not run yet |
| Move the boom arm across the frame | Microphone and arm stay visible | not run yet |
| Prop leaves the frame and returns to the same place | Picked up again without re-seed | not run yet |
| Prop returns to a different place | Needs Re-seed now; recovered after it | not run yet |
| Change the lighting after calibration | No holes, no background leak | not run yet |
| Restart OBS with calibration on disk | Auto-seeds when the person is in frame | verified: phase goes to "Waiting for a person" and seeds on detection |
| Switch compute units while tracking | Models reload, calibration kept | verified without a person: reload and return to "Waiting for a person" |
| Edge refinement none / bilateral / guided | Compare edges and render time | measured (see Performance): bilateral cleanest, default; guided retuned |
| Aligned mode | Status shows added latency; no halo on fast motion | status shows +69 ms, render time unchanged; fast-motion halo check not run yet |

What was verified end to end without a person: the calibration flow
(countdown, plate averaging, props mask extraction, persistence), seeding
through Vision, the status line and the overlay, all settings, and tracking
on the real models with a synthetic moving object (integration test).

## Development

```sh
swift build
swift test                      # unit tests; no OBS, camera or Neural Engine needed
swift test -c release --filter CoreMLEngineIntegrationTests   # real models, when exported
swift run FrameRingTests        # C++ tests for the alignment ring
scripts/check-format.sh         # clang-format and swift-format, read-only
scripts/check-format.sh --fix   # rewrite files in place
scripts/obsctl.py status        # drive the filter over obs-websocket during manual tests
```

The unit tests run without OBS, a camera or the Neural Engine, so they also
run in GitHub Actions on a macOS runner. The Core ML integration test loads
the exported models when they exist and is skipped otherwise.

MatAnyone2Kit comes from a fork at <https://github.com/xy13m/MatAnyone2Kit>
(branch `obs-matanyone2`), pinned by revision in `Package.swift`. The fork
adds a memory-only reset to the engine, marks the kit's static state for
Swift 6 callers, and lets the export script take the working resolution from
the environment.

## Licensing

The plugin source code is GPL-3.0-or-later (see `LICENSE`). The MatAnyone 2
weights are under the NTU S-Lab License 1.0 and are non-commercial only. They
are never committed to this repository; the export script downloads them on
your machine. See `NOTICE.md` for the details.
