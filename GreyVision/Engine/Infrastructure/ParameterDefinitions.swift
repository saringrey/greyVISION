import Foundation

enum ParameterCategory: String, Codable, CaseIterable, Sendable {
    case primary
    case secondary
    case temporal
    case motion
    case color
    case mask
    case advanced
}

enum ParameterUnit: String, Codable, Sendable {
    case normalized
    case percent
    case seconds
    case milliseconds
    case hertz
    case degrees
    case pixels
    case frames
    case decibels
    case count
    case none
}

enum ParameterUIImportance: Int, Codable, Comparable, Sendable {
    case hidden = 0
    case advanced = 1
    case standard = 2
    case primary = 3

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum ParameterMapping: Codable, Equatable, Sendable {
    case linear
    case logarithmic
    case exponential(power: Float)
    case bipolar
    case stepped(step: Float)
    case discrete(values: [Float])
}

struct ParameterDefinition: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var displayName: String
    var defaultValue: Float
    var minimum: Float
    var maximum: Float
    var mapping: ParameterMapping
    var unit: ParameterUnit
    var isModulatable: Bool
    var isAutomatable: Bool
    var importance: ParameterUIImportance
    var category: ParameterCategory

    init(
        id: String,
        displayName: String,
        defaultValue: Float,
        minimum: Float,
        maximum: Float,
        mapping: ParameterMapping = .linear,
        unit: ParameterUnit = .normalized,
        isModulatable: Bool = true,
        isAutomatable: Bool = true,
        importance: ParameterUIImportance = .standard,
        category: ParameterCategory = .primary
    ) {
        self.id = id
        self.displayName = displayName
        self.minimum = min(minimum, maximum)
        self.maximum = max(minimum, maximum)
        self.mapping = mapping
        self.unit = unit
        self.isModulatable = isModulatable
        self.isAutomatable = isAutomatable
        self.importance = importance
        self.category = category
        self.defaultValue = min(max(defaultValue.isFinite ? defaultValue : minimum, self.minimum), self.maximum)
    }

    func clamp(_ value: Float) -> Float {
        min(max(value.isFinite ? value : defaultValue, minimum), maximum)
    }

    /// Converts a UI-normalized value to the effect's real unit/range.
    func value(normalized input: Float) -> Float {
        let normalized = min(max(input.isFinite ? input : 0, 0), 1)
        let span = maximum - minimum
        guard span > 0 else { return minimum }

        switch mapping {
        case .linear:
            return minimum + span * normalized
        case .logarithmic:
            guard minimum > 0, maximum > 0 else { return minimum + span * normalized }
            return exp(log(minimum) + normalized * log(maximum / minimum))
        case let .exponential(power):
            let safePower = max(power.isFinite ? power : 1, 0.0001)
            return minimum + span * pow(normalized, safePower)
        case .bipolar:
            guard minimum < 0, maximum > 0 else { return minimum + span * normalized }
            if normalized < 0.5 {
                return minimum * (1 - normalized * 2)
            }
            return maximum * ((normalized - 0.5) * 2)
        case let .stepped(step):
            let safeStep = max(abs(step.isFinite ? step : span), Float.ulpOfOne)
            return clamp(minimum + round((span * normalized) / safeStep) * safeStep)
        case let .discrete(values):
            let usable = values.filter(\.isFinite)
            guard !usable.isEmpty else { return defaultValue }
            let index = min(Int((normalized * Float(usable.count)).rounded(.down)), usable.count - 1)
            return clamp(usable[index])
        }
    }

    func normalized(value: Float) -> Float {
        let value = clamp(value)
        let span = maximum - minimum
        guard span > 0 else { return 0 }
        switch mapping {
        case .logarithmic where minimum > 0 && maximum > 0:
            return log(value / minimum) / log(maximum / minimum)
        case let .exponential(power):
            return pow((value - minimum) / span, 1 / max(power, 0.0001))
        case .bipolar where minimum < 0 && maximum > 0:
            return value < 0 ? 0.5 * (1 - value / minimum) : 0.5 + 0.5 * value / maximum
        default:
            return (value - minimum) / span
        }
    }
}

struct ParameterState: Codable, Equatable, Sendable {
    var baseValue: Float
    var modulation: Float
    var automation: Float

    init(baseValue: Float = 0, modulation: Float = 0, automation: Float = 0) {
        self.baseValue = baseValue
        self.modulation = modulation
        self.automation = automation
    }

    func effectiveValue(for definition: ParameterDefinition) -> Float {
        definition.clamp(baseValue + (definition.isModulatable ? modulation : 0) +
            (definition.isAutomatable ? automation : 0))
    }
}

struct EffectParameterState: Codable, Equatable, Sendable {
    private(set) var values: [String: ParameterState] = [:]

    subscript(identifier: String) -> ParameterState? {
        get { values[identifier] }
        set { values[identifier] = newValue }
    }

    mutating func setBaseValue(_ value: Float, definition: ParameterDefinition) {
        var state = values[definition.id] ?? ParameterState(baseValue: definition.defaultValue)
        state.baseValue = definition.clamp(value)
        values[definition.id] = state
    }

    func effectiveValue(for definition: ParameterDefinition) -> Float {
        (values[definition.id] ?? ParameterState(baseValue: definition.defaultValue))
            .effectiveValue(for: definition)
    }
}
