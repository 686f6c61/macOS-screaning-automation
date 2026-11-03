// Acceso a las cadenas localizadas (Resources/<idioma>.lproj/Localizable.strings).
//
// Las claves son el texto en castellano sin tildes. Cada clave debe existir en
// todos los idiomas; lo comprueba `LocalizationCoverageTests`.

import Foundation

/// Atajos para `NSLocalizedString` con el bundle principal.
enum L10n {
    /// Texto localizado de `key`; si falta, devuelve la propia clave.
    static func t(_ key: String) -> String {
        NSLocalizedString(key, bundle: .main, comment: "")
    }

    /// Texto localizado de `key` usado como formato de `String(format:)`.
    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: t(key), arguments: arguments)
    }
}
