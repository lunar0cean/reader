import SwiftUI
import UIKit

/// Reader and notebook use the same precise colour/width controls.
struct InkStyleEditor: View {
    @Binding var color: String
    @Binding var width: Double
    var prefix: String

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Circle().fill(Color(uiColor: UIColor(notebookHex: color))).frame(width: 20, height: 20)
                Text(color.uppercased()).font(.caption.monospaced())
                Spacer()
                Text("\(width.formatted(.number.precision(.fractionLength(1)))) pt").font(.caption.monospacedDigit())
            }
            slider("笔宽", value: $width, range: 0.5...64, step: 0.1, tint: .primary)
            slider("R", value: channel(16), range: 0...255, step: 1, tint: .red)
            slider("G", value: channel(8), range: 0...255, step: 1, tint: .green)
            slider("B", value: channel(0), range: 0...255, step: 1, tint: .blue)
        }.padding(.horizontal, 18).padding(.vertical, 14).accessibilityIdentifier("\(prefix)-ink-style")
    }
    private func slider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, tint: Color) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.caption).frame(width: 32, alignment: .leading)
            Slider(value: value, in: range, step: step).tint(tint).accessibilityLabel("\(prefix)\(label)")
            Text(label == "笔宽" ? value.wrappedValue.formatted(.number.precision(.fractionLength(1))) : "\(Int(value.wrappedValue))")
                .font(.caption.monospacedDigit()).frame(width: 36, alignment: .trailing)
        }
    }
    private func channel(_ shift: UInt32) -> Binding<Double> {
        Binding(get: { Double(((UInt32(color.dropFirst(), radix: 16) ?? 0x202124) >> shift) & 255) }, set: { value in
            let rgb = UInt32(color.dropFirst(), radix: 16) ?? 0x202124
            let byte = UInt32(max(0, min(255, value.rounded())))
            color = String(format: "#%06X", (rgb & ~(255 << shift)) | (byte << shift))
        })
    }
}
