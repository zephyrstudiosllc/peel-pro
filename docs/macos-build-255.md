# macOS build 255: closed menu-bar popovers

Build 254 fixed the collapsed notch, but a menu-bar popover that had been opened
and closed still retained its mounted SwiftUI dashboard. Live usage rows,
relative timestamps, animated meters and resource rows continued updating after
the popover disappeared.

On the same M4 Mac mini, build 254 averaged 5.8% CPU before opening the menu.
Opening and closing just the menu-bar popover raised the following ten one-second
samples to an average of 39.2%, with a 42.7% peak. The notch stayed collapsed and
the main window stayed minimized throughout this reproduction.

Build 255 mounts popover content before measuring and showing it, then unmounts
the SwiftUI tree when the popover closes. Models remain alive and reopening reads
their current values. Both the integrated Peel Pro menu and standalone SidePulse
menu use this lifecycle. The previous notch fix is unchanged.

`NotchInteractionSmoke` now exercises an actual `NSPopover`: initial inactivity,
nonzero presentation size, suppression of model-driven body evaluation after
closing, current values on reopening, and an immediate close/reopen cycle.
The existing notch lifecycle checks also pass.

The signed Release archive/export and upgrade-identity checks passed. Build 255
was installed over SSH on both Macs and launched with its normal GUI. Each menu
opened at its expected size and closed twice, leaving the notch visibly
collapsed and the main window minimized. Matching executable hashes and valid
signatures were verified on both running installations.

Measured on October 30, 2026, after those menu cycles:

| Mac | Average CPU | Highest one-second interval | Samples |
| --- | ---: | ---: | ---: |
| M4 Mac mini | 4.8% | 12.9% | 60 |
| MacBook Pro | 4.8% | 13.8% | 60 |

All 60 one-second intervals on each Mac were below 20%. Previous app bundles
were retained locally for rollback. This source update does not publish a
downloadable binary release.

CPU percentages use the Activity Monitor convention: 100% is one CPU core.
These measurements concern idle UI with no active remote stream, not a universal
CPU cap or a streaming benchmark.
