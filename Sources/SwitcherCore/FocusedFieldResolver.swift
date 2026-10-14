import Foundation

/// Resolve browser wrappers without treating a whole page as an editable field.
/// Traversal uses only focus/role metadata. Ambiguous or oversized trees fail closed.
public enum FocusedFieldResolver {
    public static func resolve<Node>(
        _ root: Node,
        same: (Node, Node) -> Bool,
        editable: (Node) -> Bool,
        focused: (Node) -> Bool,
        focusChild: (Node) -> Node?,
        children: (Node) -> [Node],
        limit: Int = 256
    ) -> Node? {
        guard limit > 0 else { return nil }
        if editable(root) { return root }
        var chain = [root]
        var current = root
        while let next = focusChild(current) {
            guard chain.count < limit, !chain.contains(where: { same($0, next) }) else { break }
            if editable(next) { return next }
            chain.append(next)
            current = next
        }
        var pending = [root]
        var visited: [Node] = []
        var result: Node?
        while let node = pending.popLast() {
            if visited.contains(where: { same($0, node) }) { continue }
            guard visited.count < limit else { return nil }
            visited.append(node)
            if editable(node), focused(node) {
                if let result, !same(result, node) { return nil }
                result = node
            }
            let descendants = children(node)
            guard descendants.count <= limit, pending.count + descendants.count <= limit else { return nil }
            pending.append(contentsOf: descendants)
        }
        return result
    }
}
