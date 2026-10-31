# macOS build 254: collapsed-notch CPU use

Build 255 adds the [closed menu-bar popover fix](macos-build-255.md). The tests
below verified the notch path; later open/close testing exposed that separate
popover lifecycle issue.

When the notch was collapsed, AppKit hid its hosting view but SwiftUI kept the
dashboard mounted. Live model updates still rebuilt usage rows, formatted
relative timestamps, updated layout and ran meter animations.

Build 254 unmounts the dashboard while collapsed or disabled and mounts it again
on expansion. Models continue receiving updates, so reopening shows current
data. Content remains mounted during the closing fade; the existing transition
identity check prevents an interrupted close from unmounting a reopened notch.

The fix applies to both the integrated Peel Pro Mac app and the standalone
SidePulse presentation. The Mac target's Debug and Release configurations now
use build number 254.

## Validation

Measured on an M4 Mac mini on October 30, 2026, with the notch collapsed and no
active remote stream. CPU percentages use Activity Monitor's convention:
100% represents one CPU core.

| Measurement | Average CPU | Highest interval |
| --- | ---: | ---: |
| Build 253, existing process, 30 seconds | 39.9% | 43.9% over 5 seconds |
| Build 253, fresh launch, 40 seconds | 33.3% | 39.1% over 5 seconds |
| Build 254, 60 seconds | 4.2% | 6.4% over 5 seconds |
| Build 254, after reopening and collapsing, 60 seconds | 6.5% | 10.2% over 5 seconds |
| Build 254, final 60 one-second samples | 4.6% | 19.8% over 1 second |

The final one-second samples were all below 20%. These observations establish
the improvement for this workload; they are not a universal CPU cap or a
streaming performance benchmark.

The signed Release archive/export, installation and normal launch passed.
The expanded dashboard displayed current data. `NotchInteractionSmoke` checks
that hidden model publications do not evaluate the dashboard body, reopening
reads state received while hidden, an interrupted close preserves the reopened
view, and disabling the notch stops hidden updates. The regression is included
in `Sources/SidePulse/scripts/test.sh`.

This source update does not publish a downloadable signed binary or update
other installed devices.
