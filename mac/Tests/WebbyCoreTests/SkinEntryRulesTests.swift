import Foundation
import Testing
@testable import WebbyCore

private func classify(_ path: String) -> SkinEntryDisposition {
    SkinEntryRules.classify(path)
}

private func isRejected(_ path: String) -> Bool {
    if case .rejected = classify(path) {
        return true
    }
    return false
}

private func isWarning(_ path: String) -> Bool {
    if case .warning = classify(path) {
        return true
    }
    return false
}

private func isSkipped(_ path: String) -> Bool {
    classify(path) == .skipped
}

@Test func acceptedRootEntries() {
    #expect(classify("skin.json") == .accepted(SkinEntry(path: "skin.json")))
    #expect(classify("preview.png") == .accepted(SkinEntry(path: "preview.png")))
    #expect(classify("preview@2x.png") == .accepted(SkinEntry(path: "preview@2x.png")))
}

@Test func acceptedStaticImagesCoverEveryElementAndSuffixOrder() {
    let suffixes: [(suffix: String, appearance: SkinAppearance?, scale: SkinScale)] = [
        ("", nil, .one),
        ("~dark", .dark, .one),
        ("@2x", nil, .two),
        ("~dark@2x", .dark, .two),
    ]

    for element in SkinImageElement.allCases {
        for variant in suffixes {
            let path = "images/\(element.rawValue)\(variant.suffix).png"
            let asset = SkinAsset.image(
                element: element,
                appearance: variant.appearance,
                scale: variant.scale
            )
            #expect(
                classify(path) == .accepted(SkinEntry(path: path, asset: asset))
            )
        }
    }
}

@Test func acceptedOrbFramesCoverStatesBoundsAndSuffixes() {
    let suffixes: [(suffix: String, appearance: SkinAppearance?, scale: SkinScale)] = [
        ("", nil, .one),
        ("~dark", .dark, .one),
        ("@2x", nil, .two),
        ("~dark@2x", .dark, .two),
    ]

    for state in SkinOrbState.Known.allCases {
        for frame in [0, 1, 23, 59] {
            for variant in suffixes {
                let path = "images/orb-\(state.rawValue)-\(frame)\(variant.suffix).png"
                let asset = SkinAsset.orb(
                    state: state,
                    frame: frame,
                    appearance: variant.appearance,
                    scale: variant.scale
                )
                #expect(
                    classify(path) == .accepted(SkinEntry(path: path, asset: asset))
                )
            }
        }
    }
}

@Test func acceptedSoundsCoverEveryEventAndExtension() {
    for event in SkinSoundEvent.Known.allCases {
        for extensionName in ["wav", "aif", "aiff", "caf"] {
            let path = "sounds/\(event.rawValue).\(extensionName)"
            let asset = SkinAsset.sound(event: .known(event))
            #expect(
                classify(path) == .accepted(SkinEntry(path: path, asset: asset))
            )
        }
    }
}

@Test func rejectedStructuralPaths() {
    let paths = [
        "",
        "/etc/passwd",
        "/images/note-body.png",
        "C:/evil.png",
        "c:evil.png",
        "C:\\evil.png",
        "../evil.png",
        "images/../evil.png",
        "images/..",
        "images\\note-body.png",
        "images/note-body.png\0",
        "\0skin.json",
    ]

    for path in paths {
        #expect(isRejected(path), "expected rejection for \(path.debugDescription)")
    }
}

@Test func rejectedNestedArchivesFontsAndExecutables() {
    let paths = [
        "skin.zip",
        "skin.webbyskin",
        "images/note-body.png.zip",
        "sounds/note-create.wav.tar.gz",
        "FOO.ZIP",
        "fonts/MyFont.ttf",
        "images/font.OTF",
        "font.woff2",
        "tools/run.sh",
        "image.dylib",
        "helper.exe",
        "module.wasm",
    ]

    for path in paths {
        #expect(isRejected(path), "expected rejection for \(path)")
    }
}

@Test func rejectedUppercaseAcceptedNames() {
    let paths = [
        "SKIN.JSON",
        "Skin.json",
        "Preview.png",
        "PREVIEW@2X.PNG",
        "IMAGES/note-body.png",
        "images/Note-Body.png",
        "images/note-body@2X.png",
        "images/orb-IDLE-0.png",
        "SOUNDS/note-create.wav",
        "sounds/Note-Create.wav",
        "sounds/note-create.WAV",
    ]

    for path in paths {
        #expect(isRejected(path), "expected rejection for \(path)")
    }
}

@Test func rejectedMalformedSuffixesAndScales() {
    let paths = [
        "images/note-body@2x~dark.png",
        "images/note-body@1x.png",
        "images/note-body@3x.png",
        "images/note-body@4x.png",
        "images/note-body~light.png",
        "images/orb-idle-0@2x~dark.png",
        "images/orb-idle-0@3x.png",
    ]

    for path in paths {
        #expect(isRejected(path), "expected rejection for \(path)")
    }
}

@Test func rejectedStaticFrames() {
    let paths = [
        "images/note-body-0.png",
        "images/note-body-12.png",
        "images/icon-close-59.png",
        "images/decoration-1~dark@2x.png",
    ]

    for path in paths {
        #expect(isRejected(path), "expected rejection for \(path)")
    }
}

@Test func rejectedOrbFramesAndNames() {
    let paths = [
        "images/orb-idle.png",
        "images/orb-idle-60.png",
        "images/orb-idle-99.png",
        "images/orb-idle-00.png",
        "images/orb-idle-01.png",
        "images/orb-idle-x.png",
        "images/orb-idle-0-1.png",
        "images/orb-unknown-0.png",
        "images/orb-0.png",
        "images/orb.png",
    ]

    for path in paths {
        #expect(isRejected(path), "expected rejection for \(path)")
    }
}

@Test func rejectedUnknownElementsAndSoundEvents() {
    let paths = [
        "images/unknown.png",
        "images/note.png",
        "images/unknown~dark@2x.png",
        "images/unknown-0.png",
        "sounds/note-open.wav",
        "sounds/unknown.aiff",
        "sounds/.wav",
    ]

    for path in paths {
        #expect(isRejected(path), "expected rejection for \(path)")
    }
}

@Test func harmlessUnknownFilesAreWarnings() {
    let paths = [
        "README.md",
        "foo.png",
        "preview@3x.png",
        "images/readme.txt",
        "images/unknown.jpg",
        "sounds/readme.txt",
        "sounds/note-create.mp3",
        "extras/notes.json",
    ]

    for path in paths {
        #expect(isWarning(path), "expected warning for \(path)")
    }
}

@Test func macMetadataIsSkippedSilently() {
    let paths = [
        ".DS_Store",
        "images/.DS_Store",
        "sounds/.DS_Store",
        "__MACOSX",
        "__MACOSX/",
        "__MACOSX/._note-body.png",
        "__MACOSX/images/note-body.png",
    ]

    for path in paths {
        #expect(isSkipped(path), "expected skip for \(path)")
    }
}

@Test func safetyRejectionWinsUnderMacMetadata() {
    let paths = [
        "__MACOSX/../evil.png",
        "__MACOSX/nested.zip",
        "__MACOSX/font.ttf",
        "__MACOSX/run.sh",
    ]

    for path in paths {
        #expect(isRejected(path), "expected rejection for \(path)")
    }
}
