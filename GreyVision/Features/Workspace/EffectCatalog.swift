import Foundation

/// Discovery metadata only. Render identity and saved parameters always use
/// the original effect, including variants hidden behind a family card.
enum EffectCatalog {
    struct Shelf: Sendable {
        let id: String
        let label: String
        let effects: [WorkspaceAdjustableEffect]
    }

    struct Control {
        let label: String
        let keyPath: WritableKeyPath<CameraEffectParameters, Double>
        let defaultValue: Double
        let range: ClosedRange<Double> = 0 ... 1
    }

    /// Built once per effect, on the main actor.
    ///
    /// The deck asks for this on every body pass and the answer never changes
    /// for a given effect, so it was rebuilding an array of four key paths,
    /// zipping it against three label strings, and reading five defaults out
    /// of a fresh parameter struct on each render. `Control` holds a writable
    /// key path, which is not `Sendable`, so the table is main-actor
    /// confined — which is also the only place that reads it.
    ///
    /// `nonisolated(unsafe)` rather than main-actor confined because the
    /// broadcast control catalogue also reads this, off the main actor. It is
    /// safe to share: the table is derived purely from a frozen enum's switch,
    /// is written exactly once during its initialisation, and is read-only
    /// after that. `Control` is not `Sendable` only because it carries a
    /// writable key path, which cannot be mutated through the `let` that holds
    /// it.
    private nonisolated(unsafe) static let controlTable: [WorkspaceAdjustableEffect: [Control]] = {
        let paths: [WritableKeyPath<CameraEffectParameters, Double>] =
            [\.primary, \.secondary, \.tertiary, \.blend]
        var table: [WorkspaceAdjustableEffect: [Control]] = [:]
        table.reserveCapacity(WorkspaceAdjustableEffect.allCases.count)
        for effect in WorkspaceAdjustableEffect.allCases {
            let labels = Array(effect.parameterLabels.prefix(3)) + ["BLEND"]
            let defaults = effect.defaultCameraParameters
            table[effect] = zip(labels, paths).map {
                Control(label: $0.0, keyPath: $0.1, defaultValue: defaults[keyPath: $0.1])
            }
        }
        return table
    }()

    nonisolated(unsafe) static func controls(for effect: WorkspaceAdjustableEffect) -> [Control] {
        controlTable[effect] ?? []
    }

    static let variantGroups: [[WorkspaceAdjustableEffect]] = [
        [.kaleidoscope, .kaleido6],
        [.flowField, .curlWarp],
        [.liquidMosh, .opticalFlowLiquid]
    ]

    static func canonical(_ effect: WorkspaceAdjustableEffect) -> WorkspaceAdjustableEffect {
        variantGroups.first { $0.contains(effect) }?.first ?? effect
    }

    static func variants(for effect: WorkspaceAdjustableEffect) -> [WorkspaceAdjustableEffect] {
        variantGroups.first { $0.contains(effect) } ?? [effect]
    }

    static func canonicalEffects(_ effects: [WorkspaceAdjustableEffect]) -> [WorkspaceAdjustableEffect] {
        var seen = Set<WorkspaceAdjustableEffect>()
        return effects.map(canonical).filter { seen.insert($0).inserted }
    }

    /// These are the phone's existing visible shelves. The desktop consumes
    /// the same arrays instead of reconstructing an older category taxonomy.
    ///
    /// Built exactly once. The browser asks for this on every body pass — and
    /// `isShelf` asks for a *single* shelf, which used to rebuild all fourteen
    /// (each running `canonicalEffects`: a `Set`, a `map` and a `filter`).
    /// Fourteen of those per body pass meant hundreds of throwaway
    /// allocations per redraw for a list that can never change at runtime.
    ///
    /// Safe to share across actors because it is `Sendable` and derived purely
    /// from frozen `static let` category lists — written once during
    /// initialisation, read-only afterwards.
    static let shelves: [Shelf] = [
        Shelf(id: "color", label: "TONAL", effects: canonicalEffects(WorkspaceAdjustableEffect.colorCategoryEffects)),
        Shelf(id: "datamosh", label: "DATAMOSH", effects: canonicalEffects(WorkspaceAdjustableEffect.datamoshCategoryEffects)),
        Shelf(id: "sort", label: "SORT", effects: canonicalEffects(WorkspaceAdjustableEffect.sortCategoryEffects)),
        Shelf(id: "time", label: "HISTORY", effects: canonicalEffects(WorkspaceAdjustableEffect.timeCategoryEffects)),
        Shelf(id: "motion", label: "MOTION", effects: canonicalEffects(WorkspaceAdjustableEffect.motionCategoryEffects)),
        Shelf(id: "decay", label: "DECAY", effects: canonicalEffects(WorkspaceAdjustableEffect.decayCategoryEffects)),
        Shelf(id: "signal", label: "ANALOG", effects: canonicalEffects(WorkspaceAdjustableEffect.signalCategoryEffects)),
        Shelf(id: "optics", label: "LENS", effects: canonicalEffects(WorkspaceAdjustableEffect.opticsCategoryEffects)),
        Shelf(id: "form", label: "GEOMETRY", effects: canonicalEffects(WorkspaceAdjustableEffect.formCategoryEffects)),
        Shelf(id: "shaders", label: "GENERATIVE", effects: canonicalEffects(WorkspaceAdjustableEffect.shaderCategoryEffects)),
        Shelf(id: "audio", label: "SPECTRUM", effects: canonicalEffects(WorkspaceAdjustableEffect.audioCategoryEffects)),
        Shelf(id: "scope", label: "INSTRUMENTS", effects: canonicalEffects(WorkspaceAdjustableEffect.scopeCategoryEffects)),
        Shelf(id: "experimental", label: "SOLVERS", effects: canonicalEffects(WorkspaceAdjustableEffect.experimentalCategoryEffects)),
        Shelf(id: "developer", label: "RESEARCH", effects: canonicalEffects(WorkspaceAdjustableEffect.developerCategoryEffects))
    ]

    /// Shelf id to effect list, for the single-shelf lookups that dominated
    /// the old hot path. Avoids a linear scan plus a rebuild on every call.
    private static let shelfIndex: [String: [WorkspaceAdjustableEffect]] = {
        var index: [String: [WorkspaceAdjustableEffect]] = [:]
        index.reserveCapacity(shelves.count)
        for shelf in shelves { index[shelf.id] = shelf.effects }
        return index
    }()

    static func effects(in shelfID: String) -> [WorkspaceAdjustableEffect] {
        shelfIndex[shelfID] ?? []
    }

    static func aliases(for effect: WorkspaceAdjustableEffect) -> [String] {
        switch effect {
        case .objectSort: ["OBJECT SORT"]
        case .depthSort: ["DEPTH SORT"]
        case .depthFeedback: ["DEPTH FEEDBACK"]
        case .pointCloudSmear: ["POINT CLOUD SMEAR", "POINT-CLOUD SMEAR"]
        case .bokeh: ["BOKEH"]
        case .opticalFlowLiquid: ["OPTICAL-FLOW LIQUID", "OPTICAL FLOW LIQUID"]
        default: []
        }
    }

    /// Search returns one result per family, retaining the matching variant
    /// so an old name opens precisely the algorithm the operator requested.
    static func search(_ query: String) -> [WorkspaceAdjustableEffect] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let matches = WorkspaceAdjustableEffect.allCases.filter { effect in
            ([effect.label, effect.detail, effect.rawValue] + aliases(for: effect))
                .contains { $0.localizedCaseInsensitiveContains(trimmed) }
        }
        // Prefer an exact label/rawValue hit so a canonical name does not
        // resolve to its sibling variant first in allCases order
        // (e.g. "kaleidoscope" matching "KALEIDOSCOPE 6" before "KALEIDOSCOPE").
        let ranked = matches.sorted { lhs, rhs in
            let lhsExact = lhs.label.caseInsensitiveCompare(trimmed) == .orderedSame
                || lhs.rawValue.caseInsensitiveCompare(trimmed) == .orderedSame
            let rhsExact = rhs.label.caseInsensitiveCompare(trimmed) == .orderedSame
                || rhs.rawValue.caseInsensitiveCompare(trimmed) == .orderedSame
            if lhsExact != rhsExact { return lhsExact && !rhsExact }
            return WorkspaceAdjustableEffect.allCases.firstIndex(of: lhs)! < WorkspaceAdjustableEffect.allCases.firstIndex(of: rhs)!
        }
        var seen = Set<WorkspaceAdjustableEffect>()
        return ranked.filter { seen.insert(canonical($0)).inserted }
    }
}
