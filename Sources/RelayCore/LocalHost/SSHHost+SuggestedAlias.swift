import Foundation

extension SSHHost {
    /// "Iddo’s MacBook Pro" → "iddos-macbook-pro", made unique. Pure;
    /// unit-tested.
    public static func suggestedAlias(forComputerName computerName: String, taken: Set<String>) -> String {
        var slug = ""
        for scalar in computerName.lowercased().unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                slug.unicodeScalars.append(scalar)
            } else if scalar == " " || scalar == "-" || scalar == "_" || scalar == "." {
                if !slug.isEmpty, slug.last != "-" { slug.append("-") }
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.isEmpty { slug = "this-mac" }
        var candidate = slug
        var number = 2
        while taken.contains(candidate) {
            candidate = "\(slug)-\(number)"
            number += 1
        }
        return candidate
    }
}
