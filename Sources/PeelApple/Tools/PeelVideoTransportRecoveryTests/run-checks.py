#!/usr/bin/env python3
"""Compile production stream transitions with deterministic transport/clock/scheduler stubs."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / 'Shared/Client/ClientBrowser'

def method(text, name):
    return block(text, '    func ' + name + '(')

def block(text, signature):
    start = text.index(signature)
    brace = text.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]

media = (BASE / 'Media.swift').read_text()
media = media.replace('    private func recordEnqueuedVideoFrame(', '    func recordEnqueuedVideoFrame(')
receive = (BASE / 'Receive.swift').read_text()
connection = (BASE / 'Connection.swift').read_text()
chunks = []
for owner in ('PeelClientBrowser', 'PeelHostSession'):
    source = media.split('extension ' + owner + ' {', 1)[1]
    methods = ['requestSnapshot', 'requestStreamStart', 'resetVideoStreamReadiness',
               'repairStream', 'reconnectForStreamRepair', 'beginPullStream', 'endPullStream',
               'makeVideoRenderer', 'recordEnqueuedVideoFrame']
    body = '\n'.join(method(source, name) for name in methods)
    source = receive.split('extension ' + owner + ' {', 1)[1]
    body += '\n' + '\n'.join(method(source, name) for name in ['startStreamWatchdog', 'stopStreamWatchdog'])
    if owner == 'PeelHostSession':
        for name in ['handleUnexpectedVideoConnectionClosure', 'closeVideoConnection']:
            body += '\n' + method(connection, name)
        # This private production method only depends on the advertised capability
        # and I/O shims supplied by the fixture. Keep its callback intact.
        public_connection = connection.replace('    private func sendVideoStreamHello(', '    func sendVideoStreamHello(')
        # Both overloads: the Debug native-request deferral wrapper and the sender.
        body += '\n' + block(public_connection,
            '    func sendVideoStreamHello(windowId: UInt32, connection: NWConnection, nativeExperimentRequest:')
        body += '\n' + block(public_connection,
            '    func sendVideoStreamHello(windowId: UInt32, connection: NWConnection,\n'
            '                                      streamRequest:')
        body += '\n' + method(source, 'startVideoReceiveLoop')
    chunks.append('extension ' + owner + ' {\n' + body + '\n}')
production = '\n'.join(chunks)
adapted = production.replace('DispatchQueue.main', 'FixtureScheduler.main').replace('Date()', 'FixtureClock.date')
fixture = (ROOT / 'Tools/PeelVideoTransportRecoveryTests/TransportRecoveryChecks.swift').read_text()
dependencies, cases = fixture.split('enum Failure: Error', 1)
unit = dependencies + '\n' + adapted + '\nenum Failure: Error' + cases
# Debug and Release differ in the native stream-request path; both must pass.
variants = [('release', unit, [], True), ('debug', unit, ['-D', 'DEBUG'], True)]
if '--verify-regression' in sys.argv:
    stale_socket = '                      self.videoConnectionsByWindowId[windowId] === connection,\n'
    mutated = adapted.replace(stale_socket, '', 1)
    assert mutated != adapted, 'Mutation debug-stale-socket-request no longer applies; update the runner'
    variants.append(('debug-stale-socket-request',
                     dependencies + '\n' + mutated + '\nenum Failure: Error' + cases, ['-D', 'DEBUG'], False))
unexpected = False
with tempfile.TemporaryDirectory(prefix='peel-transport-recovery-') as scratch:
    for name, source, flags, should_pass in variants:
        path = Path(scratch) / (name + '.swift')
        path.write_text(source)
        binary = Path(scratch) / name
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', *flags, str(path), '-o', str(binary)],
                       check=True, timeout=120)
        result = subprocess.run([str(binary)], timeout=15)
        matched = (result.returncode == 0) == should_pass
        unexpected |= not matched
        print(json.dumps({'variant': name,
                          'productionTransitionsSHA256': hashlib.sha256(production.encode()).hexdigest(),
                          'compiledUnitSHA256': hashlib.sha256(source.encode()).hexdigest(),
                          'exitCode': result.returncode, 'expectedOutcomeMatched': matched}), flush=True)
raise SystemExit(1 if unexpected else 0)
