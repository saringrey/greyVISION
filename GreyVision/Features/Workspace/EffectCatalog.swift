import Foundation

/// Discovery metadata only. Render identity and saved parameters always use
/// the original effect, including variants hidden behind a family card.
enum EffectCatalog {
    struct Shelf {
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
    static var shelves: [Shelf] {
        [
            Shelf(id: "color", label: "COLOR", effects: canonicalEffects(WorkspaceAdjustableEffect.colorCategoryEffects)),
            Shelf(id: "time", label: "TIME", effects: canonicalEffects(WorkspaceAdjustableEffect.timeCategoryEffects)),
            Shelf(id: "motion", label: "MOTION", effects: canonicalEffects(WorkspaceAdjustableEffect.motionCategoryEffects)),
            Shelf(id: "decay", label: "DECAY", effects: canonicalEffects(WorkspaceAdjustableEffect.decayCategoryEffects)),
            Shelf(id: "signal", label: "SIGNAL", effects: canonicalEffects(WorkspaceAdjustableEffect.signalCategoryEffects)),
            Shelf(id: "optics", label: "OPTICS", effects: canonicalEffects(WorkspaceAdjustableEffect.opticsCategoryEffects)),
            Shelf(id: "form", label: "FORM", effects: canonicalEffects(WorkspaceAdjustableEffect.formCategoryEffects)),
            Shelf(id: "shaders", label: "SHADERS", effects: canonicalEffects(WorkspaceAdjustableEffect.shaderCategoryEffects)),
            Shelf(id: "audio", label: "AUDIO", effects: canonicalEffects(WorkspaceAdjustableEffect.audioCategoryEffects)),
            Shelf(id: "scope", label: "SCOPE", effects: canonicalEffects(WorkspaceAdjustableEffect.scopeCategoryEffects))
        ]
    }

    static func effects(in shelfID: String) -> [WorkspaceAdjustableEffect] {
        shelves.first { $0.id == shelfID }?.effects ?? []
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

    /// Restrict incumbent radial groups to the same curated shelf and append
    /// new entries in bounded groups so a new effect never becomes rail-only.
    static func radialSubcategories(title: String, effects: [WorkspaceAdjustableEffect]) -> [GVRadialSubcategory] {
        let available = Set(effects)
        var seen = Set<WorkspaceAdjustableEffect>()
        var groups = (WorkspaceAdjustableEffect.curatedRadialSubcategories(for: title) ?? []).compactMap { group -> GVRadialSubcategory? in
            let members = group.effects.flatMap(variants).filter { available.contains($0) && seen.insert($0).inserted }
            guard !members.isEmpty else { return nil }
            return GVRadialSubcategory(title: group.title, hue: group.hue, glyph: group.glyph, effects: members)
        }
        let remaining = effects.filter { seen.insert($0).inserted }
        guard !groups.isEmpty || remaining.count > 8 else { return [] }
        for start in stride(from: 0, to: remaining.count, by: 6) {
            groups.append(GVRadialSubcategory(
                title: start == 0 ? "MORE" : "MORE \(start / 6 + 1)",
                hue: .sand,
                glyph: .frame,
                effects: Array(remaining[start ..< min(start + 6, remaining.count)])
            ))
        }
        // Push-through contract: one gesture across 2-6 large wedges.
        // Curated groups stay as-is; only overflow beyond 6 wedges merges
        // the smallest groups into bounded MORE chunks of 6.
        if groups.count > 6 {
            let ranked = groups.indices.sorted { groups[$0].effects.count > groups[$1].effects.count }
            var keepCount = 5
            while keepCount > 0 {
                let overflowCount = ranked.dropFirst(keepCount).reduce(0) { $0 + groups[$1].effects.count }
                if keepCount + (overflowCount + 5) / 6 <= 6 { break }
                keepCount -= 1
            }
            let kept = Set(ranked.prefix(keepCount))
            let overflow = ranked.dropFirst(keepCount).sorted().flatMap { groups[$0].effects }
            var capped = groups.indices.filter { kept.contains($0) }.map { groups[$0] }
            var moreIndex = 0
            for start in stride(from: 0, to: overflow.count, by: 6) {
                moreIndex += 1
                capped.append(GVRadialSubcategory(
                    title: moreIndex == 1 ? "MORE" : "MORE \(moreIndex)",
                    hue: .sand,
                    glyph: .frame,
                    effects: Array(overflow[start ..< min(start + 6, overflow.count)])
                ))
            }
            groups = capped
        }
        return groups
    }
}
