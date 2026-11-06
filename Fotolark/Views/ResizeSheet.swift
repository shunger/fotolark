import FotolarkKit
import SwiftUI

/// Choose the exported size by pixels, percent or print size.
struct ResizeSheet: View {
    @Bindable var editor: PhotoEditor
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable, Identifiable {
        case pixels = "Pixels", percent = "Percent", print = "Print size"
        var id: String { rawValue }
    }

    enum PrintUnit: String, CaseIterable, Identifiable {
        case inches = "inches", centimeters = "cm"
        var id: String { rawValue }
        var perInch: Double { self == .inches ? 1 : 2.54 }
    }

    @State private var mode: Mode = .pixels
    @State private var width = 0
    @State private var height = 0
    @State private var lockAspect = true
    @State private var percent = 100.0
    @AppStorage("resize.printUnit") private var unit: PrintUnit = .inches
    @AppStorage("resize.dpi") private var dpi = 300.0
    @State private var printWidth = 0.0
    @State private var printHeight = 0.0

    private var base: PixelSize { editor.editedSize }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Resize").font(.title2.weight(.semibold))
            Text("Sets the size of exported copies. The photo is now \(base.description) px.")
                .foregroundStyle(.secondary)

            Picker("Resize by", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Form {
                switch mode {
                case .pixels:
                    TextField("Width", value: widthBinding, format: .number)
                    TextField("Height", value: heightBinding, format: .number)
                    Toggle("Keep proportions", isOn: $lockAspect)
                case .percent:
                    TextField("Percent", value: percentBinding, format: .number)
                case .print:
                    Picker("Units", selection: $unit) {
                        ForEach(PrintUnit.allCases) { Text($0.rawValue).tag($0) }
                    }
                    TextField("Width", value: printWidthBinding, format: .number.precision(.fractionLength(0...2)))
                    TextField("Height", value: printHeightBinding, format: .number.precision(.fractionLength(0...2)))
                    TextField("Pixels per inch", value: dpiBinding, format: .number)
                }
                LabeledContent("New size", value: "\(width) × \(height) px")
            }
            .formStyle(.columns)

            if width > base.width || height > base.height {
                Label("Enlarging a photo can make it look soft.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Original size") {
                    editor.setResize(nil)
                    dismiss()
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Resize") {
                    editor.setResize(ResizeSpec(width: width, height: height, dpi: mode == .print ? dpi : nil))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(width < 1 || height < 1 || width > 30000 || height > 30000)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear(perform: load)
        .onChange(of: unit) { updatePrintFromPixels() }
        .onChange(of: mode) { updatePrintFromPixels() }
    }

    private var aspect: Double { base.aspectRatio }

    private func load() {
        let current = editor.recipe.resize
        width = current?.width ?? base.width
        height = current?.height ?? base.height
        if let d = current?.dpi { dpi = d; mode = .print }
        percent = (Double(width) / Double(max(base.width, 1)) * 100).rounded()
        updatePrintFromPixels()
    }

    private func updatePrintFromPixels() {
        printWidth = (Double(width) / dpi * unit.perInch * 100).rounded() / 100
        printHeight = (Double(height) / dpi * unit.perInch * 100).rounded() / 100
    }

    private var widthBinding: Binding<Int> {
        Binding(get: { width }, set: { w in
            width = max(w, 0)
            if lockAspect { height = max(1, Int((Double(width) / aspect).rounded())) }
        })
    }

    private var heightBinding: Binding<Int> {
        Binding(get: { height }, set: { h in
            height = max(h, 0)
            if lockAspect { width = max(1, Int((Double(height) * aspect).rounded())) }
        })
    }

    private var percentBinding: Binding<Double> {
        Binding(get: { percent }, set: { p in
            percent = max(p, 1)
            width = max(1, Int((Double(base.width) * percent / 100).rounded()))
            height = max(1, Int((Double(base.height) * percent / 100).rounded()))
        })
    }

    // Print sizes always keep the photo's proportions.
    private var printWidthBinding: Binding<Double> {
        Binding(get: { printWidth }, set: { w in
            printWidth = max(w, 0)
            width = max(1, Int((printWidth / unit.perInch * dpi).rounded()))
            height = max(1, Int((Double(width) / aspect).rounded()))
            printHeight = (Double(height) / dpi * unit.perInch * 100).rounded() / 100
        })
    }

    private var printHeightBinding: Binding<Double> {
        Binding(get: { printHeight }, set: { h in
            printHeight = max(h, 0)
            height = max(1, Int((printHeight / unit.perInch * dpi).rounded()))
            width = max(1, Int((Double(height) * aspect).rounded()))
            printWidth = (Double(width) / dpi * unit.perInch * 100).rounded() / 100
        })
    }

    private var dpiBinding: Binding<Double> {
        Binding(get: { dpi }, set: { d in
            dpi = min(max(d, 1), 2400)
            width = max(1, Int((printWidth / unit.perInch * dpi).rounded()))
            height = max(1, Int((Double(width) / aspect).rounded()))
        })
    }
}
