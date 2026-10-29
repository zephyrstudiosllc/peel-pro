import Foundation

@main
enum AgentPresentationRouteStateChecks {
    static func main() {
        claimIsExclusiveAndCompletionIsIdentityBound()
        providersAreBoundedAndLifecycleOrdered()
        completedClaimsPermitRepeatedRequests()
        print("AgentPresentationRouteStateChecks: passed")
    }

    private static func claimIsExclusiveAndCompletionIsIdentityBound() {
        var state = IPadAgentPresentationRouteState<String, String>()

        precondition(state.claim("request-a"))
        precondition(!state.claim("request-b"))
        precondition(!state.complete("request-b"))
        precondition(state.claimedRequestID == "request-a")
        precondition(state.complete("request-a"))
        precondition(state.claimedRequestID == nil)
    }

    private static func providersAreBoundedAndLifecycleOrdered() {
        var state = IPadAgentPresentationRouteState<String, String>(
            maximumActiveProviders: 2
        )

        precondition(state.registerProvider("main"))
        precondition(state.registerProvider("peeled-a"))
        precondition(!state.registerProvider("peeled-b"))
        precondition(state.selectedProviderID == "peeled-a")

        precondition(state.registerProvider("main"))
        precondition(state.selectedProviderID == "main")

        state.unregisterProvider("main")
        precondition(state.selectedProviderID == "peeled-a")
        state.unregisterProvider("peeled-a")
        precondition(state.selectedProviderID == nil)
    }

    private static func completedClaimsPermitRepeatedRequests() {
        var state = IPadAgentPresentationRouteState<Int, UUID>()

        for requestID in 0..<64 {
            precondition(state.claim(requestID))
            precondition(state.complete(requestID))
        }

        precondition(state.claim(64))
    }
}
