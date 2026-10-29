#!/usr/bin/env python3
"""Exercise real observer installation/handlers with synthetic audio-session events.
This never opens an audio device or requests microphone access. --source-root
can select an older Apple checkout for an expected-failing regression run.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--source-root', type=Path, default=root)
args = parser.parse_args()

def method(source, signature):
    start = source.index(signature)
    opening = source.index('{', start)
    depth = 1
    i = opening + 1
    while depth:
        if source[i] == '{': depth += 1
        elif source[i] == '}': depth -= 1
        i += 1
    return source[start:i]

parts = [Path(__file__).with_name('TestDoubles.swift').read_text()]
for name, field, sink in [('PeelAudioPlaybackOwner', 'playbackGeneration', 'onFailure'), ('PeelVoiceAudioOwner', 'generation', 'failureSink')]:
    source = (args.source_root / 'Shared/Client/Audio' / (name + '.swift')).read_text()
    functions = '\n'.join(method(source, signature) for signature in [
        'private func installObservers()',
        'private func handleInterruption(rawType:',
        'private func handleRouteChange(rawReason:'
    ])
    parts.append(f'''
@MainActor private final class {name} {{
    private let audioSession = AVAudioSession()
    private let observers = ObserverBag()
    private var {field} = UUID()
    private var {sink}: ((Failure) -> Void)?
    private(set) var isStarted = true
    init() {{ installObservers() }}
    private func tearDown(reportDeactivationFailure: Bool) {{
        {field} = UUID()
        observers.removeAll()
        isStarted = false
    }}
    func restart() {{ tearDown(reportDeactivationFailure: false); isStarted = true; installObservers() }}
    func emit(_ name: Notification.Name, value: UInt, key: String) {{
        NotificationCenter.default.post(name: name, object: audioSession, userInfo: [key: NSNumber(value: value)])
    }}
    func finish() {{ tearDown(reportDeactivationFailure: false) }}
    {functions}
}}
''')
parts.append(Path(__file__).with_name('Checks.swift').read_text())
with tempfile.TemporaryDirectory(prefix='peel-audio-lifecycle-') as output:
    path = Path(output)
    swift = path / 'main.swift'
    swift.write_text('\n'.join(parts))
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', str(swift), '-o', str(path / 'checks')], check=True)
    subprocess.run([str(path / 'checks')], check=True)
