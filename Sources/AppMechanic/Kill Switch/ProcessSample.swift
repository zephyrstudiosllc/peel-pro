//
//  ProcessSample.swift
//  Kill Switch
//
//  Created by Zach on 4/16/26.
//


//
//  ProcessSample.swift
//  Kill Switch
//

import Foundation
import Darwin

struct ProcessSample: Identifiable, Hashable {
    let pid: pid_t
    let cpu: Double
    let memoryMB: Double
    let uptimeText: String
    let processType: String
    let command: String
    let appName: String
    let bundleIdentifier: String?
    let bundleURLPath: String?
    let executablePath: String?
    /// Kernel-reported process launch time, encoded as microseconds since the Unix epoch.
    /// A PID can be reused by an identical app, so bundle/path identity alone is not enough
    /// for an action that can terminate the process.
    let processStartTime: UInt64?

    var id: pid_t { pid }
}
