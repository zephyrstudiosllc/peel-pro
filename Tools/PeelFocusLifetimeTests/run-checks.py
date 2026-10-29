#!/usr/bin/env python3
"""Exercise exact production focus transitions with deterministic I/O scheduling."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
HOST = ROOT / 'Sources/PeelHost/Peel-Host/PeelHost'
APPLE = ROOT / 'Sources/PeelApple/Shared/Client/ClientBrowser'

def method(text, name):
    text = text.replace('private func ', 'func ')
    start = text.index('    func ' + name)
    brace = text.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]

host = (HOST / 'PeelHost.swift').read_text()
network = (HOST / 'HostNetworkServer.swift').read_text()
receive = (APPLE / 'Receive.swift').read_text()
chunks = ['extension PeelHost {\n' + '\n'.join(method(host, name) for name in (
    'noteClientActiveWindow(', 'isCurrentFocusRequest(', 'handleClientActiveWindow(', 'logRejectedClientFocusLine(',
    'sendWindowFocusState(', 'confirmWindowReadyForInput(', 'ensureWindowIsFrontmostBeforeInput(')) + '\n}']
chunks += ['extension HostNetworkServer {\n' + '\n'.join(method(network, name) for name in (
    'sendJSONLine<', 'sendLine(')) + '\n}']
route = host.split('            case "clientActiveWindow":\n', 1)[1].split('\n            case ', 1)[0]
chunks += ['extension PeelHost { func routeFocus(_ data: Data, generation: UInt64?) throws {\nlet decoder = JSONDecoder()\nlet line = String(decoding: data, as: UTF8.self)\n' + route + '\n}}']
for owner in ('PeelClientBrowser', 'PeelHostSession'):
    section = receive.split('extension ' + owner + ' {', 1)[1]
    arm = section.split('            case "windowFocusState":\n', 1)[1].split('\n            case ', 1)[0]
    chunks += ['extension ' + owner + ' { func receiveFocus(_ data: Data, sourceConnection: NWConnection?) throws {\n' + arm + '\n}}']
production = '\n'.join(chunks)
adapted = production.replace('DispatchQueue.main', 'FixtureScheduler.main')
fixture = (Path(__file__).parent / 'FocusLifetimeChecks.swift').read_text()
before, after = fixture.split('// PRODUCTION_METHODS', 1)
unit = before + '\n' + adapted + '\n' + after
with tempfile.TemporaryDirectory(prefix='peel-focus-lifetime-') as scratch:
    source = Path(scratch) / 'Checks.swift'
    binary = Path(scratch) / 'checks'
    source.write_text(unit)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', str(source), '-o', str(binary)], check=True, timeout=60)
    result = subprocess.run([str(binary)], timeout=15)
    print(json.dumps({'productionMethodsSHA256': hashlib.sha256(production.encode()).hexdigest(),
                      'compiledUnitSHA256': hashlib.sha256(unit.encode()).hexdigest(),
                      'exitCode': result.returncode}))
    raise SystemExit(result.returncode)
