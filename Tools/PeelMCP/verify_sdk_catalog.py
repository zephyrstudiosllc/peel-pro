#!/usr/bin/env python3
"""Opt-in protocol check using official mcp==2.2.0; never contacts a real Host.

Run with: uv run --with mcp==2.2.0 Tools/PeelMCP/verify_sdk_catalog.py
SDK API reference: https://py.sdk.modelcontextprotocol.io/client/
This is outside unittest discovery so the runtime adapter stays dependency-free.
"""
import asyncio
import importlib.metadata
import json
from pathlib import Path
import sys
import tempfile

from mcp import Client, StdioServerParameters

EXPECTED_TOOLS = {
    "peel_list_devices", "peel_list_windows", "peel_list_apps", "peel_launch_app",
    "peel_present_window", "peel_notify", "peel_get_stream_diagnostics",
}

async def verify():
    adapter = Path(__file__).with_name("peel_mcp_server.py").resolve()
    with tempfile.TemporaryDirectory(prefix="peel-mcp-catalog-") as directory:
        absent_socket = str(Path(directory) / "no-host.sock")
        process = StdioServerParameters(
            command=sys.executable, args=[str(adapter), "--socket", absent_socket])
        async with Client(process, read_timeout_seconds=15) as client:
            tools = await client.list_tools()
            prompts = await client.list_prompts()
            resources = await client.list_resources()
            names = {tool.name for tool in tools.tools}
            assert names == EXPECTED_TOOLS, names
            assert [prompt.name for prompt in prompts.prompts] == ["show_me_this_app"]
            assert [str(resource.uri) for resource in resources.resources] == ["peel://workflow/show-me-this-app"]
            for resource in resources.resources:
                assert (await client.read_resource(resource.uri)).contents
            return {
                "sdk": "mcp " + importlib.metadata.version("mcp"),
                "protocol": client.protocol_version,
                "server": client.server_info.model_dump() if client.server_info else None,
                "tools": sorted(names),
                "staticResourceRead": True,
                "liveHostConnected": False,
                "toolCalls": 0,
            }

if __name__ == "__main__":
    print(json.dumps(asyncio.run(verify()), indent=2))
