#!/usr/bin/env python3
"""Compile actual production transforms against deterministic clocks; no network or UI."""
from pathlib import Path
import argparse, hashlib, json, subprocess, tempfile, time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SCHEMA = ROOT / 'Sources/PeelHost/Peel-Host/PeelStreamDiagnosticsMessages.swift'
HELPER = ROOT / 'Integration/PeelRemoteMacReceiverDiagnostics.swift'
SOURCES = [SCHEMA, HELPER,
    ROOT / 'Sources/PeelHost/Peel-Host/AgentBridge/PeelLocalAgentServer.swift',
    ROOT / 'Sources/PeelHost/Peel-Host/PeelHost/PeelReceiverDiagnostics.swift', HERE / 'Checks.swift']
MUTANTS = {
    'fps-includes-dropped-frames': ('Double(totalDelta - droppedDelta) / duration', 'Double(totalDelta) / duration'),
    'flush-keeps-av-generation': ('generation = UUID(); observation = nil\n        clearTiming(now: uptime())', 'observation = nil\n        clearTiming(now: uptime())'),
    'wrong-source-pts-delta-sign': ('relative = (now - anchor.at) - (pts - anchor.pts)', 'relative = (now - anchor.at) + (pts - anchor.pts)'),
    'expired-ring-samples-retained': ('$0.at <= now && $0.at > now - 5', '$0.at <= now'),
    'zero-drift-allowance': ('span.map { $0 * 1000 * 0.0001 }', 'span.map { _ in 0 }'),
    'flush-allows-old-frame-token': ('frame.generation == generation,', 'frame.generation == frame.generation,'),
    'missing-pts-keeps-old-segment': ('sourcePTSMissingFrames + 1)\n            sourceSegment &+= 1; sourceAnchor = nil; lastSource = nil', 'sourcePTSMissingFrames + 1)'),
}

def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--no-mutants', action='store_true')
    parser.add_argument('--receipt', type=Path); parser.add_argument('--schema-only', action='store_true'); args = parser.parse_args()
    assert SCHEMA.read_bytes() == (ROOT / 'Sources/PeelApple/Shared/All/PeelStreamDiagnosticsMessages.swift').read_bytes()
    if args.schema_only:
        sources = [SCHEMA, HERE / 'SchemaChecks.swift']
        before = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
        results = []
        with tempfile.TemporaryDirectory(prefix='peel-mac-timing-schema-') as temporary:
            for version in ('5', '6'):
                binary = Path(temporary) / ('checks-' + version)
                argv = ['xcrun', 'swiftc', '-parse-as-library', '-swift-version', version,
                    '-default-isolation', 'MainActor', '-strict-concurrency=complete', '-warnings-as-errors',
                    *map(str, sources), '-o', str(binary)]
                compiled = subprocess.run(argv, capture_output=True, text=True, timeout=30)
                assert compiled.returncode == 0, compiled.stderr
                run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
                assert run.returncode == 0, run.stderr
                results.append({'swiftVersion': version, 'compileExit': 0, 'runExit': 0, 'stdout': run.stdout.strip()})
                print(run.stdout.strip())
        assert before == {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
        if args.receipt: args.receipt.write_text(json.dumps({'scope': 'Targeted schema correction only', 'sourcesSHA256': before, 'sourceDrift': False, 'results': results}, indent=2) + '\n')
        return
    before = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES}
    results = []
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix='peel-mac-timing-') as temp:
        scratch = Path(temp)
        def run(name, source, expect_pass, version='6'):
            helper = scratch / (name + '.swift'); helper.write_text(source)
            binary = scratch / (name + '-checks')
            argv = ['xcrun', 'swiftc', '-parse-as-library', '-swift-version', version,
                '-default-isolation', 'MainActor', '-strict-concurrency=complete', '-warnings-as-errors',
                *map(str, [SCHEMA, helper, *SOURCES[2:]]), '-o', str(binary)]
            compiled = subprocess.run(argv, capture_output=True, text=True, timeout=90)
            if compiled.returncode != 0:
                raise RuntimeError(name + ' compile failed (not a valid semantic mutant):\n' + compiled.stderr)
            executed = subprocess.run([str(binary)], capture_output=True, text=True, timeout=20)
            passed = executed.returncode == 0
            assert passed == expect_pass, name + ': unexpected outcome\n' + executed.stdout + executed.stderr
            results.append({'name': name, 'swiftVersion': version, 'compileExit': compiled.returncode,
                'runExit': executed.returncode, 'expectedPass': expect_pass,
                'output': executed.stdout.strip() if passed else executed.stderr.splitlines()[0]})
            print(name + ': ' + ('PASS' if passed else 'REJECTED (expected)'))
        production = HELPER.read_text()
        run('production-swift6', production, True)
        run('production-swift5', production, True, '5')
        if not args.no_mutants:
            for name, (old, new) in MUTANTS.items():
                assert old in production, (name, 'missing mutation anchor')
                run(name, production.replace(old, new), False)
    after = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES}
    assert before == after, 'Production/test files changed during run'
    receipt = {'elapsedSeconds': time.monotonic() - started, 'sourcesSHA256': before,
        'sourceDrift': False, 'results': results, 'scope': 'Deterministic production transforms only; no native AV/display/network/device proof'}
    if args.receipt: args.receipt.write_text(json.dumps(receipt, indent=2) + '\n')
if __name__ == '__main__': main()
