import Foundation
import Darwin

@main
struct NativeBridgeFixture {
    static func main() throws {
        let server = PeelLocalAgentServer(
            configuration: .init(socketURL: URL(fileURLWithPath: CommandLine.arguments[1])),
            handlerQueue: DispatchQueue(label: "peel.fixture.handler")
        ) { request, completion in
            if request.method == .notify {
                completion(.failure(.init(code: "unsupported", message: "Notifications unavailable.")))
            } else {
                completion(.success(.object([
                    "method": .string(request.method.rawValue),
                    "params": .object(request.params)
                ])))
            }
        }
        try server.start()
        print("READY")
        fflush(stdout)
        _ = readLine()
        try server.stop()
    }
}
