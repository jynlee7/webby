import Foundation
import Testing
@testable import WebbyCore

private let epsilon = 1e-12

private func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) throws -> RGBAColor {
    try RGBAColor(r: r, g: g, b: b, a: a)
}

@Test func hexParsesSixAndEightDigits() throws {
    let black = try RGBAColor(hex: "#000000")
    let opaqueBlack = try color(0, 0, 0, 1)
    #expect(black == opaqueBlack)
    #expect(black.a == 1)

    let orange = try RGBAColor(hex: "#FF8000")
    let expectedOrange = try color(1, 128.0 / 255.0, 0, 1)
    #expect(orange == expectedOrange)

    let translucent = try RGBAColor(hex: "#11223344")
    let expectedTranslucent = try color(17.0 / 255.0, 34.0 / 255.0, 51.0 / 255.0, 68.0 / 255.0)
    #expect(translucent == expectedTranslucent)
}

@Test func hexIsCaseInsensitive() throws {
    let lower = try RGBAColor(hex: "#aBcDeF")
    let upper = try RGBAColor(hex: "#ABCDEF")
    #expect(lower == upper)

    let lowerAlpha = try RGBAColor(hex: "#aBcDeF80")
    let upperAlpha = try RGBAColor(hex: "#ABCDEF80")
    #expect(lowerAlpha == upperAlpha)
}

@Test func hexRejectsShorthandBareAndMalformedValues() {
    #expect(throws: RGBAColorError.invalidHexFormat) { try RGBAColor(hex: "") }
    #expect(throws: RGBAColorError.invalidHexFormat) { try RGBAColor(hex: "FFFFFF") }
    #expect(throws: RGBAColorError.invalidHexFormat) { try RGBAColor(hex: "#FFF") }
    #expect(throws: RGBAColorError.invalidHexFormat) { try RGBAColor(hex: "#FFFFFFF") }
    #expect(throws: RGBAColorError.invalidHexFormat) { try RGBAColor(hex: "#FFFFFF0000") }
    #expect(throws: RGBAColorError.invalidHexFormat) { try RGBAColor(hex: "##FFFFFF") }
    #expect(throws: RGBAColorError.invalidHexDigit("G")) { try RGBAColor(hex: "#GG0000") }
    #expect(throws: RGBAColorError.invalidHexDigit("G")) { try RGBAColor(hex: "#12345G") }
}

@Test func directInitializationValidatesComponents() {
    #expect(throws: RGBAColorError.nonFiniteComponent) {
        try RGBAColor(r: .nan, g: 0, b: 0, a: 1)
    }
    #expect(throws: RGBAColorError.nonFiniteComponent) {
        try RGBAColor(r: 0, g: .infinity, b: 0, a: 1)
    }
    #expect(throws: RGBAColorError.componentOutOfRange) {
        try RGBAColor(r: -0.01, g: 0, b: 0, a: 1)
    }
    #expect(throws: RGBAColorError.componentOutOfRange) {
        try RGBAColor(r: 0, g: 0, b: 1.01, a: 1)
    }
    #expect(throws: RGBAColorError.componentOutOfRange) {
        try RGBAColor(r: 0, g: 0, b: 0, a: 2)
    }
}

@Test func compositingUsesSourceOverAndKeepsAlpha() throws {
    let translucentRed = try color(1, 0, 0, 0.5)
    let opaqueBlue = try color(0, 0, 1, 1)

    let purple = translucentRed.composited(over: opaqueBlue)
    #expect(abs(purple.r - 0.5) < epsilon)
    #expect(abs(purple.g - 0) < epsilon)
    #expect(abs(purple.b - 0.5) < epsilon)
    #expect(abs(purple.a - 1) < epsilon)

    let opaque = try color(0.2, 0.4, 0.6, 1)
    #expect(opaque.composited(over: translucentRed) == opaque)
}

@Test func compositingKeepsPartialDestinationAlpha() throws {
    let translucentWhite = try color(1, 1, 1, 0.5)
    let translucentBlack = try color(0, 0, 0, 0.5)

    let gray = translucentWhite.composited(over: translucentBlack)
    #expect(abs(gray.a - 0.75) < epsilon)
    #expect(abs(gray.r - 2.0 / 3.0) < epsilon)
    #expect(abs(gray.g - 2.0 / 3.0) < epsilon)
    #expect(abs(gray.b - 2.0 / 3.0) < epsilon)
}

@Test func transparentCompositingIsCanonical() throws {
    let canonicalClear = try color(0, 0, 0, 0)
    #expect(RGBAColor.clear.composited(over: .clear) == .clear)
    #expect(RGBAColor.clear.composited(over: .clear) == canonicalClear)

    let opaqueBlue = try color(0, 0, 1, 1)
    #expect(RGBAColor.clear.composited(over: opaqueBlue) == opaqueBlue)
    #expect(opaqueBlue.composited(over: .clear) == opaqueBlue)
}
