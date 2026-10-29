#!/usr/bin/env python3
"""Compile real Host policy/controller/input/server, substituting only OS windows,
capture destination, focus and event posting. No screen, input, TCC or live settings.
"""
from pathlib import Path
import subprocess
import re
import tempfile

root = Path(__file__).resolve().parents[3]
host = root / 'Sources/PeelHost/Peel-Host'
stubs = (root / 'Sources/PeelHost/Tests/InputLifetime/InputLifetimeChecks.swift').read_text().split('@main')[0]
network = (host / 'PeelHost/HostNetworkServer.swift').read_text()
def declaration(source, marker):
    start = source.index(marker); brace = source.index('{', start); end = brace + 1; depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}'); end += 1
    return source[start:end]
stubs += '\n' + declaration(network, 'nonisolated struct PeelControlSession') + '\n'
stubs += '\n@_silgen_name("CGWindowListCreateImage")' + (host / 'PeelHost/WindowEnumerator.swift').read_text().split('@_silgen_name("CGWindowListCreateImage")')[1]
host_source = (host / 'PeelHost/PeelHost.swift').read_text()
methods = '\n'.join(declaration(host_source, 'private func ' + name + '(').replace('private func', 'func', 1)
    for name in ['clearManualAgentAuthorization', 'handleManualAgentProof', 'manualAgentTargetPolicyAllows'])
fixture = Path(__file__).with_name('Checks.swift').read_text().replace('/* HOST_MANUAL_METHODS */', methods)
# The mobile-only handler must be owned by the real session, not a legacy
# browser extension. Enumerate balanced extension scopes before compiling it.
client_source = (root / 'Sources/PeelApple/Shared/Client/ClientBrowser/LifecycleStreams.swift').read_text()
manual_marker = 'func receiveManualAgentControlChallenge('
handlers = {}
for match in re.finditer(r'extension (PeelClientBrowser|PeelHostSession) \{', client_source):
    block = declaration(client_source[match.start():], match.group(0))
    count = block.count(manual_marker)
    if count:
        assert count == 1 and match.group(1) not in handlers, 'manual handler is duplicated in an owner scope'
        handlers[match.group(1)] = declaration(block, manual_marker)
assert set(handlers) == {'PeelClientBrowser', 'PeelHostSession'}, 'manual handler missing or misplaced'
assert 'lastHandledManualAgentControlChallengeRequestID' not in handlers['PeelClientBrowser']
assert 'browser?.pairingStore.psk' in handlers['PeelHostSession']
mobile = handlers['PeelHostSession'].replace('#if os(iOS) || os(visionOS)', '').replace('#endif', '')
# Only the platform's local permission getter is substituted for this macOS run;
# all connection identity, pair ID, freshness, replay and HMAC routing stays real.
mobile = mobile.replace('PeelManualAgentControl.isOptedIn', 'manualPermission')
fixture = fixture.replace('/* CLIENT_BROWSER_MANUAL_METHOD */', handlers['PeelClientBrowser'])
fixture = fixture.replace('/* CLIENT_SESSION_MANUAL_METHOD */', mobile)

with tempfile.TemporaryDirectory(prefix='peel-agent-window-control-') as folder:
    folder = Path(folder); (folder / 'Stubs.swift').write_text(stubs)
    (folder / 'Checks.swift').write_text(fixture)
    executable = folder / 'checks'
    sources = [host / p for p in [
        'PeelSharedMessages.swift', 'PeelStreamDiagnosticsMessages.swift',
        'PeelHost/PeelPointerInput.swift', 'PeelHost/PeelKeyboardEventFactory.swift',
        'PeelHost/InputSynthesizer.swift', 'PeelHost/PeelReceiverDiagnostics.swift',
        'AgentBridge/PeelLocalAgentServer.swift', 'AgentBridge/PeelAgentTargetSnapshot.swift', 'AgentBridge/PeelAgentPresentationPolicy.swift',
        'AgentBridge/PeelAgentControlPolicy.swift', 'AgentBridge/PeelAgentWindowControl.swift']]
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6', '-default-isolation', 'MainActor',
        '-strict-concurrency=complete', '-warnings-as-errors', *map(str, sources), str(folder / 'Stubs.swift'),
        str(folder / 'Checks.swift'), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
