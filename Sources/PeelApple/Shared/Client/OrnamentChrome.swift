//
//  OrnamentChrome.swift
//  Peel
//
//  Created by Zach on 12/24/25.
//

import SwiftUI

private extension View {
    @ViewBuilder
    func backgroundChrome() -> some View {
        #if os(visionOS)
        self.glassBackgroundEffect()
        #else
        self.background(.thinMaterial)
        #endif
    }
}

extension View {
    func ornamentChrome() -> some View {
        modifier(OrnamentChromeModifier())
    }
}

//
//  OrnamentChrome.swift
//  Peel
//
//  Created by Zach on 12/24/25.
//

import SwiftUI

enum OrnamentChromeShape {
    case capsule
    case circle
    case roundedRectangle(cornerRadius: CGFloat = 18)
}

struct OrnamentChromeModifier: ViewModifier {
    let shape: OrnamentChromeShape
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let circleSize: CGFloat

    init(
        shape: OrnamentChromeShape = .capsule,
        horizontalPadding: CGFloat = 12,
        verticalPadding: CGFloat = 8,
        circleSize: CGFloat = 44
    ) {
        self.shape = shape
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.circleSize = circleSize
    }

    func body(content: Content) -> some View {
        switch shape {
        case .capsule:
            content
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .peelGlassBackground(in: Capsule())

        case .circle:
            content
                .frame(width: circleSize, height: circleSize)
                .contentShape(Circle())
                .peelGlassBackground(in: Circle())

        case .roundedRectangle(let cornerRadius):
            content
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .peelGlassBackground(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

private extension View {
    @ViewBuilder
    func peelGlassBackground<S: InsettableShape>(in shape: S) -> some View {
#if os(visionOS)
        self.glassBackgroundEffect(in: shape)
#else
        self.background(.thinMaterial, in: shape)
#endif
    }
}

extension View {
    func ornamentChrome(
        _ shape: OrnamentChromeShape = .capsule,
        horizontalPadding: CGFloat = 12,
        verticalPadding: CGFloat = 8,
        circleSize: CGFloat = 44
    ) -> some View {
        modifier(
            OrnamentChromeModifier(
                shape: shape,
                horizontalPadding: horizontalPadding,
                verticalPadding: verticalPadding,
                circleSize: circleSize
            )
        )
    }
}
