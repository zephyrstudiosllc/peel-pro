//
//  ForceQuitBadge.swift
//  Kill Switch
//
//  Created by Zach on 4/16/26.
//


//
//  ForceQuitBadge.swift
//  Kill Switch
//

import SwiftUI

struct ForceQuitBadge: View {
    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        Image(systemName: "xmark")
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.red)
            )
            .scaleEffect(pulseScale)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 0.75)
                    .repeatForever(autoreverses: true)
                ) {
                    pulseScale = 1.1
                }
            }
    }
}
