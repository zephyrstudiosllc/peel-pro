//
//  iPadAgentPresentationRouteState.swift
//  Peel-iPad
//

import Foundation

/// Small synchronous state machine used by the main-actor iPad router.
///
/// Main-actor isolation makes claiming atomic with respect to scene callbacks.
/// The state permits one in-flight request and bounds provider retention even if
/// SwiftUI delivers an unbalanced scene lifecycle callback.
struct IPadAgentPresentationRouteState<ClaimID: Equatable, ProviderID: Hashable> {
    private(set) var claimedRequestID: ClaimID?
    private(set) var activeProviderIDs: [ProviderID] = []

    let maximumActiveProviders: Int

    init(maximumActiveProviders: Int = 16) {
        precondition(maximumActiveProviders > 0)
        self.maximumActiveProviders = maximumActiveProviders
    }

    var selectedProviderID: ProviderID? {
        activeProviderIDs.last
    }

    @discardableResult
    mutating func registerProvider(_ providerID: ProviderID) -> Bool {
        if let existingIndex = activeProviderIDs.firstIndex(of: providerID) {
            activeProviderIDs.remove(at: existingIndex)
            activeProviderIDs.append(providerID)
            return true
        }

        guard activeProviderIDs.count < maximumActiveProviders else {
            return false
        }

        activeProviderIDs.append(providerID)
        return true
    }

    mutating func unregisterProvider(_ providerID: ProviderID) {
        activeProviderIDs.removeAll { $0 == providerID }
    }

    @discardableResult
    mutating func claim(_ requestID: ClaimID) -> Bool {
        guard claimedRequestID == nil else {
            return false
        }

        claimedRequestID = requestID
        return true
    }

    @discardableResult
    mutating func complete(_ requestID: ClaimID) -> Bool {
        guard claimedRequestID == requestID else {
            return false
        }

        claimedRequestID = nil
        return true
    }
}
