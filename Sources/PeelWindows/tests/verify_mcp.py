"""Native stdio catalog verification; no desktop tool is dispatched."""
import json
import pathlib
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parents[1]
requests = [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "Peel catalog verification", "version": "1"}}},
    {"jsonrpc": "2.0", "method": "notifications/initialized"},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
    {"jsonrpc": "2.0", "id": 3, "method": "resources/read", "params": {"uri": "peel://windows/workflow"}},
    {"jsonrpc": "2.0", "id": 4, "method": "prompts/get", "params": {"name": "show_app"}},
    {"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "peel_launch_app", "arguments": {"targetId": "local", "path": "never-forward-this"}}},
]
dll = root / "src/Peel.Windows.Mcp/bin/Release/net10.0-windows10.0.19041.0/Peel.Windows.Mcp.dll"
result = subprocess.run([sys.argv[1] if len(sys.argv) > 1 else "dotnet", str(dll)],
    input="".join(json.dumps(r) + "\n" for r in requests), text=True, capture_output=True, timeout=15, check=True)
replies = [json.loads(line) for line in result.stdout.splitlines()]
assert len(replies) == 5
assert replies[0]["result"]["protocolVersion"] == "2025-11-25"
tools = {t["name"]: t for t in replies[1]["result"]["tools"]}
assert len(tools) == 9
assert all(t["inputSchema"]["additionalProperties"] is False for t in tools.values())
# Local inspect/control match the Mac route's names, bounds and annotations; only control is destructive.
inspect, control = tools["peel_inspect_window"], tools["peel_control_window"]
assert inspect["annotations"] == {"readOnlyHint": True, "destructiveHint": False, "openWorldHint": False}
assert control["annotations"] == {"readOnlyHint": False, "destructiveHint": True, "idempotentHint": False, "openWorldHint": True}
assert set(inspect["inputSchema"]["required"]) == set(inspect["inputSchema"]["properties"]) == {"targetId", "windowId", "windowToken"}
assert set(control["inputSchema"]["required"]) == {"targetId", "windowId", "windowToken", "inspectionId", "action"}
assert control["inputSchema"]["properties"]["targetId"]["enum"] == ["local"]
assert control["inputSchema"]["properties"]["modifiers"]["items"]["enum"] == ["command", "option", "control", "shift"]
assert control["inputSchema"]["properties"]["text"]["maxLength"] == 512
assert all(t["annotations"]["destructiveHint"] is False for name, t in tools.items() if name != "peel_control_window")
assert replies[2]["result"]["contents"][0]["mimeType"] == "text/plain"
assert replies[3]["result"]["messages"][0]["role"] == "user"
assert replies[4]["error"]["code"] == -32602
print("PASS native MCP stdio: version negotiation, nine schemas incl. Mac-aligned local inspect/control, resource, prompt, and rejected arbitrary path; no desktop action dispatched.")
