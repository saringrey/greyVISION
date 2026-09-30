import AppIntents
import Foundation
import SwiftUI

/// The one place an App Intent turns into an edit.
///
/// ## Why a bus and not a direct call
///
/// An intent can run when the workspace is not on screen — from Spotlight, from
/// a Shortcut, from the Action button while the app is in the background, or
/// after the user swipes the app away and the system relaunches it into the
/// boot sequence. So an intent cannot reach into the composition the way a
/// button can: `EffectEditingSession` lives inside `WorkspaceView`, and the
/// view may not exist.
///
/// The bridge is the seam. An intent posts a command and returns; the
/// workspace, if it is mounted, picks the command up and performs it. If it is
/// not mounted, the command stays pending and the workspace consumes it the
/// moment it appears. Nothing is lost and nothing is called on a dead view.
@MainActor
final class GVIntentBridge: ObservableObject {
    static let shared = GVIntentBridge()

    /// The command waiting to be carried out, if any. Set by an intent, taken
    /// by the workspace.
    @Published private(set) var pendingCommand: GVIntentCommand?

    private init() {}

    func post(_ command: GVIntentCommand) {
        pendingCommand = command
    }

    /// Called by the workspace once it has acted on a command.
    func consume() -> GVIntentCommand? {
        defer { pendingCommand = nil }
        return pendingCommand
    }

    /// Whether a command is waiting. The workspace observes `pendingCommand`
    /// directly; this exists for the intents' own status text.
    var hasPendingCommand: Bool { pendingCommand != nil }

    /// Drops anything queued. For tests: two cases posting into the same
    /// singleton would otherwise leak a command into whichever test ran next.
    func dismissForTesting() {
        pendingCommand = nil
    }
}

/// Everything an intent can ask the composition to do.
///
/// A closed enum on purpose. An intent is a scripting surface, and a scripting
/// surface with a string payload is a scripting surface whose payload is
/// parsed at runtime by code nobody remembers writing.
enum GVIntentCommand: Equatable, Sendable {
    case captureStill
    case toggleRecording
    case undo
    case redo
    case toggleStackArmed
    case soloFocused
    case removeFocused
    case toggleBypass
    case armAudio
    case nextShelf
    case selectEffect(named: String)

    /// Short human description, used as the intent's spoken result so a
    /// Shortcut run says what actually happened.
    var outcomeDescription: String {
        switch self {
        case .captureStill: "Captured a still"
        case .toggleRecording: "Toggled recording"
        case .undo: "Undid the last edit"
        case .redo: "Redid the last edit"
        case .toggleStackArmed: "Toggled add mode"
        case .soloFocused: "Soloed the focused effect"
        case .removeFocused: "Removed the focused effect"
        case .toggleBypass: "Toggled the global bypass"
        case .armAudio: "Toggled audio reactivity"
        case .nextShelf: "Moved to the next effect shelf"
        case let .selectEffect(name): "Selected \(name)"
        }
    }
}

// MARK: - Intents

@available(iOS 16.0, *)
struct UndoEditIntent: AppIntent {
    static let title: LocalizedStringResource = "Undo Last Edit"
    static let description = IntentDescription("Steps the effect composition back one edit.")
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        GVIntentBridge.shared.post(.undo)
        return .result(dialog: IntentDialog(stringLiteral: GVIntentCommand.undo.outcomeDescription))
    }
}

@available(iOS 16.0, *)
struct RedoEditIntent: AppIntent {
    static let title: LocalizedStringResource = "Redo Last Edit"
    static let description = IntentDescription("Steps the effect composition forward one edit.")
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        GVIntentBridge.shared.post(.redo)
        return .result(dialog: IntentDialog(stringLiteral: GVIntentCommand.redo.outcomeDescription))
    }
}

@available(iOS 16.0, *)
struct ToggleStackArmedIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Add Mode"
    static let description = IntentDescription(
        "Turns stacking on or off, so the next effect you pick joins the composition instead of replacing it."
    )
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        GVIntentBridge.shared.post(.toggleStackArmed)
        return .result(dialog: IntentDialog(stringLiteral: GVIntentCommand.toggleStackArmed.outcomeDescription))
    }
}

@available(iOS 16.0, *)
struct SoloFocusedEffectIntent: AppIntent {
    static let title: LocalizedStringResource = "Solo Focused Effect"
    static let description = IntentDescription("Turns off everything except the effect you are editing.")
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        GVIntentBridge.shared.post(.soloFocused)
        return .result(dialog: IntentDialog(stringLiteral: GVIntentCommand.soloFocused.outcomeDescription))
    }
}

@available(iOS 16.0, *)
struct RemoveFocusedEffectIntent: AppIntent {
    static let title: LocalizedStringResource = "Remove Focused Effect"
    static let description = IntentDescription("Takes the effect you are editing out of the composition.")
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        GVIntentBridge.shared.post(.removeFocused)
        return .result(dialog: IntentDialog(stringLiteral: GVIntentCommand.removeFocused.outcomeDescription))
    }
}

@available(iOS 16.0, *)
struct ToggleBypassIntent: AppIntent {
    static let title: LocalizedStringResource = "Bypass All Effects"
    static let description = IntentDescription(
        "Compares the clean camera image against the processed one without editing your composition."
    )
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        GVIntentBridge.shared.post(.toggleBypass)
        return .result(dialog: IntentDialog(stringLiteral: GVIntentCommand.toggleBypass.outcomeDescription))
    }
}

@available(iOS 16.0, *)
struct ToggleAudioReactiveIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Audio Reactivity"
    static let description = IntentDescription(
        "Turns the microphone-driven effects on or off, and reports the current state."
    )
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        GVIntentBridge.shared.post(.armAudio)
        return .result(dialog: IntentDialog(stringLiteral: GVIntentCommand.armAudio.outcomeDescription))
    }
}

@available(iOS 16.0, *)
struct NextShelfIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Effect Shelf"
    static let description = IntentDescription("Moves the effect browser to the next family.")
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        GVIntentBridge.shared.post(.nextShelf)
        return .result(dialog: IntentDialog(stringLiteral: GVIntentCommand.nextShelf.outcomeDescription))
    }
}

@available(iOS 16.0, *)
struct SelectEffectIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Active Effect"
    static let description = IntentDescription("Selects a visual effect by name, for example datamosh or kaleidoscope.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Effect Name")
    var effectName: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let command = GVIntentCommand.selectEffect(named: effectName)
        GVIntentBridge.shared.post(command)
        return .result(dialog: IntentDialog(stringLiteral: command.outcomeDescription))
    }
}

// MARK: - App entity

/// Effects as an `AppEntity`, so Shortcuts can offer "set effect to…" as a
/// typed list instead of a string the user has to get right. The catalogue is
/// the same one the dock browses, which means a Shortcut can name an effect
/// this build does not have and the list simply will not offer it.
@available(iOS 16.0, *)
struct GVEffectEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Visual Effect")
    static let defaultQuery = GVEffectQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "grey//VISION effect")
    }
}

@available(iOS 16.0, *)
struct GVEffectQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [GVEffectEntity] {
        all.filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [GVEffectEntity] {
        all
    }

    private var all: [GVEffectEntity] {
        EffectCatalog.shelves.flatMap(\.effects).map {
            GVEffectEntity(id: $0.rawValue, name: $0.label)
        }
    }
}

@available(iOS 16.0, *)
struct SelectEffectEntityIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Active Visual Effect"
    static let description = IntentDescription("Selects one of grey//VISION's visual effects.")
    static var parameterSummary: some ParameterSummary {
        Summary("Set effect to \(\.$effect)")
    }

    @Parameter(title: "Effect")
    var effect: GVEffectEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let command = GVIntentCommand.selectEffect(named: effect.name)
        GVIntentBridge.shared.post(command)
        return .result(dialog: IntentDialog(stringLiteral: command.outcomeDescription))
    }
}
