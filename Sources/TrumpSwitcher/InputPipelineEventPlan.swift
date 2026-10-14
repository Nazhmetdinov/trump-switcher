/// Pure event plans for the owned fixture only. No CGEvent creation or posting.
/// The repeat case is deliberately fixed: l/k/z followed by one Space press,
/// one repeat down and its single release. It is not two separate Space presses.
enum InputPipelineEventPlan {
    struct Event: Equatable {
        let code: UInt16
        let down: Bool
        let autorepeat: Int64
    }

    struct Plan {
        let groups: [[Event]]
        var events: [Event] { groups.flatMap { $0 } }
        var keyDownCount: Int { events.filter(\.down).count }
        var keyUpCount: Int { events.filter { !$0.down }.count }
        var repeatCount: Int { events.filter { $0.down && $0.autorepeat == 1 }.count }
    }

    static func make(codes: [UInt16], repeatFinalSpace: Bool) -> Plan? {
        guard !repeatFinalSpace || codes == [37, 40, 6, 49] else { return nil }
        let groups = codes.enumerated().map { index, code -> [Event] in
            let down = Event(code: code, down: true, autorepeat: 0)
            let up = Event(code: code, down: false, autorepeat: 0)
            return repeatFinalSpace && index == 3
                ? [down, Event(code: code, down: true, autorepeat: 1), up] : [down, up]
        }
        return Plan(groups: groups)
    }
}
