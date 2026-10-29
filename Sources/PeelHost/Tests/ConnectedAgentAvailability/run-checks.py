#!/usr/bin/env python3
"""Compile actual Host admission/session predicates and notification delivery.

Only dispatch side effects, pairing storage, and network I/O are stubbed. This
does not launch apps, open sockets, read pairing keys, or contact a device.
"""
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
host = (root / "Peel-Host/PeelHost/PeelHost.swift").read_text()
server = (root / "Peel-Host/AgentBridge/PeelLocalAgentServer.swift").read_text()
wire = (root / "Peel-Host/PeelSharedMessages.swift").read_text()
network = (root / "Peel-Host/PeelHost/HostNetworkServer.swift").read_text()


def declaration(source, marker):
    start = source.index(marker)
    brace = source.index("{", start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


admission = host[host.index("    private func handleLocalAgentRequest("):
                 host.index("        if request.method == .getStreamDiagnostics {")]
# Stop at the actual dispatch boundary, after all production admission guards.
admission = admission.replace("private func", "func", 1) + """
        completion(.success(.string("dispatch reached")))
    }
"""
predicates = "\n".join(declaration(host, "private func " + name + "(").replace("private func", "func", 1)
                       for name in ["agentPresentationPolicyAllows", "agentTargetPolicyAllows"])
notification = declaration(host, "private lazy var notificationDelivery")
notification = notification.replace("private lazy var", "lazy var", 1)
types = server[server.index("nonisolated enum PeelLocalAgentJSONValue"):
               server.index("nonisolated enum PeelLocalAgentServerError")]
types += "\n" + declaration(network, "nonisolated struct PeelControlSession")
types += "\n" + declaration(wire, "enum PeelCapability:")
for name in ["PeelAgentNotificationMessage", "PeelAgentNotificationResultMessage"]:
    types += "\n" + declaration(wire, "nonisolated struct " + name + ":")
types += "\nnonisolated enum PeelLocalAgentServer { typealias Completion = @Sendable (PeelLocalAgentHandlerResult) -> Void }\n"

fixture = (root / "Tests/ConnectedAgentAvailability/AvailabilityChecks.swift").read_text()
fixture = fixture.replace("/* PRODUCTION_TYPES */", types)
fixture = fixture.replace("/* PRODUCTION_HOST_BOUNDARIES */", "\n".join([admission, predicates, notification]))
with tempfile.TemporaryDirectory(prefix="peel-connected-agent-availability-") as directory:
    temporary = pathlib.Path(directory)
    source = temporary / "Checks.swift"
    source.write_text(fixture)
    for mode in ["Release", "Debug"]:
        executable = temporary / mode
        command = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
                   "-default-isolation", "MainActor", "-strict-concurrency=complete", "-warnings-as-errors"]
        if mode == "Debug":
            command += ["-D", "DEBUG"]
        command += [str(source), str(root / "Peel-Host/AgentBridge/PeelConnectedAgentAvailability.swift"),
                    str(root / "Peel-Host/AgentBridge/PeelAgentTargetSnapshot.swift"),
                    str(root / "Peel-Host/AgentBridge/PeelAgentNotificationDelivery.swift"), "-o", str(executable)]
        subprocess.run(command, check=True)
        for arguments in [[], ["--peel-agent-preview"]]:
            subprocess.run([str(executable), *arguments], check=True)
            print(f"PASS {mode} {'explicit preview flag' if arguments else 'default'}", flush=True)
