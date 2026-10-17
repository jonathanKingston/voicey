/// Bounded traversal for AX observations. Containers must never hide their focused textbox.
public enum FocusedTextInputSearch {
  public static func find<Node>(
    in root: Node,
    maxDepth: Int = 20,
    nodeLimit: Int = 250,
    role: (Node) -> String?,
    isFocused: (Node) -> Bool,
    children: (Node) -> [Node]
  ) -> Node? {
    var remaining = nodeLimit
    func visit(_ node: Node, depth: Int) -> Node? {
      guard depth < maxDepth, remaining > 0 else { return nil }
      remaining -= 1
      let textRoles = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
      if let nodeRole = role(node), textRoles.contains(nodeRole), isFocused(node) { return node }
      for child in children(node) {
        if let found = visit(child, depth: depth + 1) { return found }
        if remaining == 0 { break }
      }
      return nil
    }
    return visit(root, depth: 0)
  }
}
