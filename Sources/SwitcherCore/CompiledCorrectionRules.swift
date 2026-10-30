/// Immutable index of user-authored rules, rebuilt only when settings change.
/// Exact spelling/case and first-valid-entry precedence match the linear path.
public struct CompiledCorrectionRules {
    private let rules: [String: CorrectionRule]
    public init(_ values: [CorrectionRule]) {
        var index: [String: CorrectionRule] = [:]
        for rule in values where rule.valid && index[rule.input] == nil {
            index[rule.input] = rule
        }
        rules = index
    }
    public func rule(for input: String) -> CorrectionRule? { rules[input] }
}
