// Actualizaciones automáticas con Sparkle.
//
// El feed (`SUFeedURL`) y la clave pública EdDSA (`SUPublicEDKey`) están en
// Info.plist; el workflow de release firma el appcast con la clave privada.

import Combine
import Foundation
import Sparkle

/// Envoltorio de Sparkle para la interfaz: expone si se puede buscar una
/// actualización y la acción de buscarla.
@MainActor
final class AppUpdater: ObservableObject {
    private let updaterController: SPUStandardUpdaterController

    @Published private(set) var canCheckForUpdates = false

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
    }

    /// Busca actualizaciones mostrando la interfaz estándar de Sparkle.
    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}
