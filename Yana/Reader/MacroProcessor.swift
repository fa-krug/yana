import Foundation

enum MacroProcessorError: Error, Sendable {
    case emptyMacroDelimiter
}

/// Replaces `[[macro]]` tokens in a template with values from a dictionary. Unknown macros
/// are left as-is. Ported from NetNewsWire's RSCore MacroProcessor.
enum MacroProcessor {
    static func renderedText(
        withTemplate template: String,
        substitutions: [String: String],
        macroStart: String = "[[",
        macroEnd: String = "]]"
    ) throws -> String {
        if macroStart.isEmpty || macroEnd.isEmpty {
            throw MacroProcessorError.emptyMacroDelimiter
        }

        var result = String()
        var index = template.startIndex

        while true {
            guard let startRange = template[index...].range(of: macroStart) else { break }
            result.append(contentsOf: template[index..<startRange.lowerBound])

            guard let endRange = template[startRange.upperBound...].range(of: macroEnd) else {
                index = startRange.lowerBound
                break
            }

            let key = String(template[startRange.upperBound..<endRange.lowerBound])
            result.append(substitutions[key] ?? "\(macroStart)\(key)\(macroEnd)")
            index = endRange.upperBound
        }

        result.append(contentsOf: template[index...])
        return result
    }
}
