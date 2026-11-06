import Foundation
import Testing
@testable import FotolarkKit

@Suite("Edit recipes")
struct RecipeTests {
    @Test func jsonRoundTripKeepsEveryOperation() throws {
        var a = Adjustments()
        a.exposure = 0.3
        a.temperature = -0.2
        let recipe = EditRecipe()
            .setting(.magicFix(FilterChain(steps: [
                FilterStep(name: "CIVibrance", parameters: ["inputAmount": .number(0.4)]),
                FilterStep(name: "CIToneCurve", parameters: ["inputPoint0": .vector([0, 0.05])]),
            ])))
            .setting(.autoContrast(Levels(black: 0.01, white: 0.9)))
            .setting(.autoColor(ChannelGains(red: 1.1, green: 1, blue: 0.9)))
            .setting(.adjust(a))
            .setting(.orient(Orientation(quarterTurns: 1, mirrored: true)))
            .setting(.straighten(degrees: 2.5))
            .setting(.crop(CropRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6)))
            .setting(.resize(ResizeSpec(width: 1600, height: 1200, dpi: 300)))

        let data = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(EditRecipe.self, from: data)
        #expect(decoded == recipe)
        // Readable on disk: operations are tagged by name.
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""op":"straighten""#))
    }

    @Test func adjustmentsDecodeWithMissingKeys() throws {
        let json = #"{"version":1,"operations":[{"op":"adjust","value":{"exposure":0.5}}]}"#
        let recipe = try JSONDecoder().decode(EditRecipe.self, from: Data(json.utf8))
        #expect(recipe.adjustments.exposure == 0.5)
        #expect(recipe.adjustments.contrast == 0)
    }

    @Test func settingKeepsCanonicalOrderAndOneOfEachKind() {
        let r = EditRecipe()
            .setting(.crop(CropRect(x: 0, y: 0, width: 0.5, height: 0.5)))
            .setting(.adjust({ var a = Adjustments(); a.contrast = 0.2; return a }()))
            .setting(.straighten(degrees: 3))
            .setting(.straighten(degrees: 4))
        #expect(r.operations.map(\.kind) == [.adjust, .straighten, .crop])
        #expect(r.straightenDegrees == 4)
    }

    @Test func identityOperationsAreRemoved() {
        let r = EditRecipe().setting(.straighten(degrees: 3)).setting(.straighten(degrees: 0))
        #expect(r.isEmpty)
        #expect(EditRecipe().settingAdjustments(Adjustments()).isEmpty)
    }

    @Test func orientationGroupLaws() {
        var o = Orientation.identity
        for _ in 0..<4 { o = o.rotated(clockwise: true) }
        #expect(o == .identity)
        #expect(Orientation.identity.flippedHorizontally().flippedHorizontally() == .identity)
        #expect(Orientation.identity.flippedVertically().flippedVertically() == .identity)
        let viaTurns = Orientation.identity.flippedHorizontally().rotated(clockwise: true).rotated(clockwise: true)
        #expect(Orientation.identity.flippedVertically() == viaTurns)
    }

    @Test func cropRectTransformsAreInverses() {
        let c = CropRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        func same(_ a: CropRect, _ b: CropRect) -> Bool {
            abs(a.x - b.x) < 1e-12 && abs(a.y - b.y) < 1e-12
                && abs(a.width - b.width) < 1e-12 && abs(a.height - b.height) < 1e-12
        }
        #expect(same(c.rotatedClockwise().rotatedCounterclockwise(), c))
        #expect(same(c.flippedHorizontally().flippedHorizontally(), c))
        var r = c
        for _ in 0..<4 { r = r.rotatedClockwise() }
        #expect(same(r, c))
    }

    @Test func rotatingSwapsResize() {
        let r = EditRecipe().setting(.resize(ResizeSpec(width: 800, height: 600))).rotated(clockwise: true)
        #expect(r.resize == ResizeSpec(width: 600, height: 800))
    }
}

@Suite("Undo history")
struct HistoryTests {
    @Test func undoRedoAndBranching() {
        var h = EditHistory(initial: EditRecipe())
        let a = EditRecipe().setting(.straighten(degrees: 1))
        let b = a.setting(.straighten(degrees: 2))
        h.commit(a, label: "Straighten")
        h.commit(b, label: "Straighten")
        #expect(h.current == b)
        h.undo()
        #expect(h.current == a)
        #expect(h.canRedo)
        h.redo()
        #expect(h.current == b)
        h.undo()
        h.undo()
        #expect(h.current.isEmpty)
        #expect(!h.canUndo)
        // A new edit after undoing drops the redo branch.
        let c = EditRecipe().rotated(clockwise: true)
        h.commit(c, label: "Rotate")
        #expect(!h.canRedo)
        #expect(h.entries.count == 2)
    }

    @Test func unchangedCommitIsIgnored() {
        var h = EditHistory(initial: EditRecipe())
        let changed = h.commit(EditRecipe(), label: "Nothing")
        #expect(!changed)
        #expect(h.entries.count == 1)
    }

    @Test func jumpToAnyStep() {
        var h = EditHistory(initial: EditRecipe())
        for d in 1...5 { h.commit(EditRecipe().setting(.straighten(degrees: Double(d))), label: "Straighten") }
        h.jump(to: h.entries[2].id)
        #expect(h.current.straightenDegrees == 2)
        #expect(h.canUndo && h.canRedo)
    }
}
