#!/usr/bin/env python3
"""Compile the exact production coordinators with event/display-link test doubles.
No UIKit device, network, application launch, or native input posting is used.
Pass --source an older PeeledWindowView.swift to demonstrate regressions.
"""
import argparse
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--source', type=pathlib.Path, default=root / 'Peel/PeeledWindowView.swift')
parser.add_argument('--ipad-source', type=pathlib.Path, default=root / 'Peel-iPad/iPadPeeledWindowView.swift')
args = parser.parse_args()
source = args.source.read_text()

def declaration(text, marker):
    start = text.index(marker)
    opening = text.index('{', start)
    depth = 1
    i = opening + 1
    while depth:
        if text[i] == '{': depth += 1
        elif text[i] == '}': depth -= 1
        i += 1
    return text[start:i]

event = declaration(source, 'private enum IndirectPointerEvent')
if 'case dragCancelled' not in event:
    event = event[:-1] + '\ncase dragCancelled\n}'
parts = [event]
for outer, name in [('IndirectPointerCapture', 'PointerCoordinator'), ('IndirectScrollCapture', 'ScrollCoordinator')]:
    parent = declaration(source, f'private struct {outer}:')
    coordinator = declaration(parent, 'final class Coordinator:')
    coordinator = coordinator.replace('final class Coordinator:', f'private final class {name}:', 1)
    # Historical source lacks teardown APIs. No-op shims let the same behavior
    # assertions run and fail instead of merely detecting missing declarations.
    if 'func setActive(' not in coordinator:
        coordinator = coordinator[:-1] + '\nfunc setActive(_ active: Bool) {}\nfunc invalidate() {}\n}'
    if 'func updateTarget(' not in coordinator:
        callback = 'onEvent: @escaping (IndirectPointerEvent) -> Void' if name == 'PointerCoordinator' else 'onScroll: @escaping (CGFloat, CGFloat) -> Void'
        coordinator = coordinator[:-1] + '\nfunc updateTarget(windowId: UInt32, isActive: Bool, ' + callback + ') {}\n}'
    parts.append(coordinator)

ipad_source = args.ipad_source.read_text()
ipad_parent = declaration(ipad_source, 'private struct IndirectScrollCapture:')
ipad_coordinator = declaration(ipad_parent, 'final class Coordinator:')
ipad_coordinator = ipad_coordinator.replace('final class Coordinator:', 'private final class ScrollCoordinator:', 1)
if 'func setActive(' not in ipad_coordinator:
    ipad_coordinator = ipad_coordinator[:-1] + '\nfunc setActive(_ active: Bool) {}\nfunc invalidate() {}\n}'

if 'func updateTarget(' not in ipad_coordinator:
    ipad_coordinator = ipad_coordinator[:-1] + '\nfunc updateTarget(windowId: UInt32, isActive: Bool, onScroll: @escaping (CGFloat, CGFloat) -> Void) {}\n}'

for label, coordinators in [('Vision pointer and scroll', parts), ('iPad scroll', parts[:-1] + [ipad_coordinator])]:
    with tempfile.TemporaryDirectory(prefix='peel-pointer-lifecycle-') as output:
        path = pathlib.Path(output)
        swift = path / 'main.swift'
        swift.write_text((pathlib.Path(__file__).with_name('TestDoubles.swift')).read_text() + '\n' + '\n'.join(coordinators) + '\n' + (pathlib.Path(__file__).with_name('Checks.swift')).read_text())
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', str(swift), '-o', str(path / 'checks')], check=True)
        print(label, flush=True)
        subprocess.run([str(path / 'checks')], check=True)
