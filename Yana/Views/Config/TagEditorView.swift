import SwiftData
import SwiftUI

/// Create or rename/recolor a tag. The built-in Starred tag can be recolored but not renamed.
struct TagEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let tag: Tag?
    @State private var name: String
    @State private var color: Color

    init(tag: Tag?) {
        self.tag = tag
        _name = State(initialValue: tag?.name ?? "")
        _color = State(initialValue: Color(hex: tag?.colorHex) ?? .accentColor)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                    .disabled(tag?.isBuiltIn == true)
                ColorPicker("Color", selection: $color, supportsOpacity: false)
            }
            .navigationTitle(tag == nil ? "New Tag" : "Edit Tag")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    ConfirmCircleButton(isDisabled: name.trimmingCharacters(in: .whitespaces).isEmpty) { save() }
                }
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let tag {
            if !tag.isBuiltIn { tag.name = trimmed }
            tag.colorHex = color.toHex()
        } else {
            let maxOrder = (try? modelContext.fetch(FetchDescriptor<Tag>()))?.map(\.sortOrder).max() ?? 0
            modelContext.insert(Tag(name: trimmed, colorHex: color.toHex(), sortOrder: maxOrder + 1))
        }
        try? modelContext.save()
        dismiss()
    }
}

extension Color {
    init?(hex: String?) {
        guard let hex, hex.hasPrefix("#"), hex.count == 7,
              let value = Int(hex.dropFirst(), radix: 16) else { return nil }
        self = Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    func toHex() -> String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}
