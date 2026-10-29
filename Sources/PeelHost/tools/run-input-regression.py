import pathlib,subprocess,time,hashlib,json,os,signal
r=pathlib.Path(__file__).resolve().parents[1]; e=r/'evidence'/'input-regression';e.mkdir(parents=True,exist_ok=False)
paths=[p for p in (r/'Peel-Host').rglob('*.swift')]+[r/'Tests/InputLifetime/InputLifetimeChecks.swift']
def hashes():return {str(p.relative_to(r)):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
before=hashes();(e/'source-before.json').write_text(json.dumps(before,indent=2)+'\n')
source=(r/'Peel-Host/AgentBridge/PeelAgentWindowControl.swift').read_text();start=source.index('    func cancel(input:');brace=source.index('{',start);end=brace+1;depth=1
while depth:depth+=(source[end]=='{')-(source[end]=='}');end+=1
fixture=(r/'Tests/InputLifetime/InputLifetimeChecks.swift').read_text().replace('/* PRODUCTION_AGENT_CANCEL */',source[start:end]);(e/'GeneratedChecks.swift').write_text(fixture)
files=[r/'Peel-Host/PeelSharedMessages.swift',r/'Peel-Host/PeelStreamDiagnosticsMessages.swift',r/'Peel-Host/PeelHost/PeelPointerInput.swift',r/'Peel-Host/PeelHost/PeelKeyboardEventFactory.swift',r/'Peel-Host/PeelHost/InputSynthesizer.swift',e/'GeneratedChecks.swift']
command=['xcrun','swiftc','-parse-as-library','-swift-version','6','-default-isolation','MainActor','-strict-concurrency=complete','-warnings-as-errors',*[str(p) for p in files],'-o',str(e/'checks')]
(e/'commands.json').write_text(json.dumps([command,[str(e/'checks')]],indent=2)+'\n');start_time=time.monotonic();results=[]
with (e/'run.log').open('w') as log:
 for cmd in [command,[str(e/'checks')]]:
  process=subprocess.Popen(cmd,stdout=log,stderr=subprocess.STDOUT,start_new_session=True);(e/'active-process.json').write_text(json.dumps({'pid':process.pid,'command':cmd})+'\n')
  try:code=process.wait(timeout=max(1,90-(time.monotonic()-start_time)));results.append({'exit_code':code,'command':cmd})
  except subprocess.TimeoutExpired:
   os.killpg(process.pid,signal.SIGTERM)
   try:process.wait(timeout=2)
   except subprocess.TimeoutExpired:os.killpg(process.pid,signal.SIGKILL);process.wait()
   results.append({'timeout':True,'command':cmd});break
  if code!=0:break
after=hashes();(e/'source-after.json').write_text(json.dumps(after,indent=2)+'\n');receipt={'results':results,'elapsed_seconds':time.monotonic()-start_time,'source_unchanged':before==after,'log_sha256':hashlib.sha256((e/'run.log').read_bytes()).hexdigest()};(e/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps(receipt));print((e/'run.log').read_text()[-7000:])
