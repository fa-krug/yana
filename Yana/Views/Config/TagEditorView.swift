import SwiftData
import SwiftUI

/// Create or rename/recolor a tag. The built-in Starred tag can be recolored but not renamed.
struct TagEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let tag: Tag?
    @State private var name: String
    @State private var color: Color

    /// nil tag = creating a new tag, presented as a sheet with explicit Cancel/confirm.
    private var isCreating: Bool { tag == nil }

    /// A new tag can only be committed once it has a non-empty name.
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(tag: Tag?) {
        self.tag = tag
        _name = State(initialValue: tag?.name ?? "")
        _color = State(initialValue: Color(hex: tag?.colorHex) ?? .accentColor)
    }

    var body: some View {
        Form {
            TextField("Name", text: $name)
                .disabled(tag?.isBuiltIn == true)
            ColorPicker("Color", selection: $color, supportsOpacity: false)
        }
        .navigationTitle(isCreating ? "New Tag" : "Edit Tag")
        // Create flow: explicit Cancel/confirm in a sheet. Edit flow: auto-save on dismiss.
        .modifier(EditorSaveBehavior(
            isCreating: isCreating,
            canSave: canSave,
            onSave: { save(); dismiss() },
            onCancel: { dismiss() },
            onDisappearSave: save
        ))
    }

    /// Auto-save on exit. An empty name discards the edit: a new tag is never inserted,
    /// and an existing tag keeps its current values.
    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let tag {
            if !tag.isBuiltIn { tag.name = trimmed }
            tag.colorHex = color.toHex()
        } else {
            let maxOrder = (try? modelContext.fetch(FetchDescriptor<Tag>()))?.map(\.sortOrder).max() ?? 0
            modelContext.insert(Tag(name: trimmed, colorHex: color.toHex(), sortOrder: maxOrder + 1))
        }
        try? modelContext.save()
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
