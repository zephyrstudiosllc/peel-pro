//
//  ProcessScope.swift
//  Kill Switch
//
//  Created by Zach on 4/16/26.
//


//
//  ProcessScope.swift
//  Kill Switch
//

import Foundation

enum ProcessScope: String, CaseIterable, Identifiable {
    case appsOnly = "Apps Only"
    case everything = "Everything"

    var id: String { rawValue }
}