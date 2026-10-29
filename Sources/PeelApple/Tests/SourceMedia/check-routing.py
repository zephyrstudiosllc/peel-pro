#!/usr/bin/env python3
"""Static routing checks over the actual Apple source-media sources.

Asserts that replies are routed only by the per-host session receive loop
behind its control-connection guard, that window controls bind to their own
session without the selected-session fallback, and that the receiver never
reaches for its own audio output, media session or system volume.
--source-root can select another Apple checkout for a negative control.
"""
import argparse
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--source-root', type=Path, default=root)
args = parser.parse_args()
src = args.source_root

failures = []

def expect(condition, name):
    if not condition:
        failures.append(name)
        print('FAIL:', name)

def read(relative):
    return (src / relative).read_text()

def block(source, signature):
    start = source.index(signature)
    opening = source.index('{', start)
    depth, i = 1, opening + 1
    while depth:
        depth += {'{': 1, '}': -1}.get(source[i], 0)
        i += 1
    return source[start:i]

def case_body(source, label):
    start = source.index(f'case "{label}":')
    end = source.index('case ', start + 6)
    return source[start:end]

receive = read('Shared/Client/ClientBrowser/Receive.swift')
session_part = receive[receive.index('extension PeelHostSession {'):]
browser_part = receive[:receive.index('extension PeelHostSession {')]
for label in ('sourceMediaAck', 'sourceVolumeState'):
    expect(f'case "{label}"' not in browser_part, f'{label} is not routed by the browser-level loop')
    expect(f'case "{label}"' in session_part, f'{label} is routed by the session loop')
    if f'case "{label}"' in session_part:
        body = case_body(session_part, label)
        expect('PeelSourceMediaProtocol.maximumLineBytes' in body, f'{label} is size-bounded')
        expect('self.connection === sourceConnection' in body, f'{label} is fenced to the source connection')
        expect('self.sourceMediaController.receive(msg, sourceConnection: sourceConnection)' in body,
               f'{label} goes to the owning session controller')
        expect('selectedSession' not in body and 'browser' not in body, f'{label} never consults the browser')

session = read('Shared/Client/ClientBrowser/PeelHostSession.swift')
connection_setter = block(session, 'var connection: NWConnection?')
expect('advanceSourceMediaControlEpoch()' in connection_setter, 'a new control connection advances the epoch')
ready_setter = block(session, '@Published var isConnectionReady')
expect('advanceSourceMediaControlEpoch()' in ready_setter, 'losing readiness advances the epoch')
for setter in ('@Published var videoReadyWindowIds', 'var desiredPullWindowIds'):
    expect('sourceMediaStreamsDidEnd(oldValue.subtracting(' in block(session, setter),
           f'{setter} reports ended streams')
expect('lazy var sourceMediaController = PeelSourceMediaController(session: self)' in session,
       'one controller per session')

controller = read('Shared/Client/PeelSourceMediaController.swift')
controls = read('Shared/Client/PeelSourceMediaControlsView.swift')
forbidden = ['selectedSession', 'selectedHostKey', 'AVAudioSession', 'MPRemoteCommandCenter', 'MPVolumeView',
             'MPMusicPlayerController', 'MediaPlayer', 'setActiveWindow', 'requestHostFocus',
             'sendJSONMessage', 'audioController', 'systemAudio']
for name, text in (('controller', controller), ('controls view', controls)):
    for token in forbidden:
        expect(token not in text, f'{name} does not use {token}')

route = block(controller, 'private func currentRoute(windowId: UInt32)')
for needle in ('session.isConnectionReady', 'session.isClientVisible', 'session.activePairingID',
               'pairedPeer(forPairingID:', 'isStreaming(windowId: windowId)', 'session.sourceMediaControlEpoch'):
    expect(needle in route, f'route requires {needle}')
streaming = block(controller, 'private func isStreaming(windowId: UInt32)')
expect('desiredPullWindowIds' in streaming and 'videoReadyWindowIds' in streaming, 'route requires an active stream')
admitted = block(controller, 'private func admittedEpoch(')
expect('session.connection === sourceConnection' in admitted and 'ledgerConnection === sourceConnection' in admitted,
       'replies must come from the request connection')
send = block(controller, 'private func send<Message: Encodable>')
expect('session?.connection === connection' in send, 'requests go only to the captured current connection')
expect(re.search(r'static let selected: PeelSourceVolumeScope\? = \.systemOutput', controller),
       'volume targets the source system output')
flush = block(controller, 'private func flushQueuedVolumeChange(windowId: UInt32)')
for needle in ('route.binding == change.binding', 'route.connection === connection',
               'change.binding.epoch == ledgerEpoch'):
    expect(needle in flush, f'queued change runs only on its exact target ({needle})')
apply_body = block(controller, 'private func apply(_ resolution:')
expect(apply_body.count('queuedVolumeChanges[windowId] = nil') >= 3, 'refusals and closed streams cancel queued changes')
expire_body = block(controller, 'private func expire(requestId: String)')
expect('queuedVolumeChanges[windowId] = nil' in expire_body, 'timeouts cancel queued changes')
ended = block(controller, 'func streamsDidEnd(')
expect('ledger.removeAll(windowId: windowId)' in ended and 'queuedVolumeChanges[windowId] = nil' in ended,
       'an ended stream cancels pending and queued work')
expect('feedbackBubble' not in controls and controls.count('.popover(isPresented: mediaFeedbackPresented)') == 3,
       'media feedback uses a system-placed popover in every non-panel style')

for path, name in (('Peel/PeeledWindowView.swift', 'Vision window'),
                   ('Peel-iPad/iPadPeeledWindowView.swift', 'iOS window')):
    text = read(path)
    owner = block(text, 'private var sourceMediaOwnerSession: PeelHostSession?')
    expect('selectedSession' not in owner and 'runtimeSession' not in owner, f'{name} owner has no fallback')
    uses = [m.start() for m in re.finditer(r'PeelSourceMediaControls\(', text)]
    expect(len(uses) >= 1, f'{name} shows source controls')
    for start in uses:
        call = text[start:text.index(')', text.index('canInteract', start)) + 1]
        expect('session: sourceMediaOwnerSession' in call, f'{name} passes its owner session')
        expect('windowId: presentedWindow.windowId' in call, f'{name} passes the presented window')

ipad = read('Peel-iPad/iPadPeeledWindowView.swift')
gate = block(ipad, 'private var sourceMediaInputAllowed: Bool')
for needle in ('workspaceAllowsInput', 'workspaceIsVisible', 'workspaceInputAdmission()'):
    expect(needle in gate, f'iOS controls honor {needle}')

settings = read('Shared/Client/SettingsView.swift')
for key in ('showVolumeKey', 'showMediaControlsKey'):
    expect(re.search(rf'@AppStorage\(PeelSourceControlsVisibility\.{key}\) private var \w+: Bool = true', settings),
           f'{key} defaults to true in Settings')
for key in ('showVolumeKey', 'showMediaControlsKey'):
    expect(re.search(rf'@AppStorage\(PeelSourceControlsVisibility\.{key}\) private var \w+ = true', controls),
           f'{key} defaults to true in the controls')

hello = read('Shared/Client/ClientBrowser/Connection.swift')
expect('capabilities.insert(PeelSourceMediaProtocol.mediaKeysCapability)' in hello, 'client advertises media keys')
expect('if PeelSourceVolumeScopeSelection.selected != nil {' in hello, 'volume is advertised only with a scope')

if failures:
    print(f'{len(failures)} routing check(s) failed')
    sys.exit(1)
print('check-routing: all checks passed')
