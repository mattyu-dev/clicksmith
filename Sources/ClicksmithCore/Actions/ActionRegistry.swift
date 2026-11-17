import Foundation

/// All actions Clicksmith knows. Source of truth for menu.json, `csx list` and the palette.
public final class ActionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var byID: [String: any PowerAction] = [:]
    private var order: [String] = []

    public init(_ actions: [any PowerAction] = []) { actions.forEach(register) }

    /// Registry with every built-in action.
    public static func standard() -> ActionRegistry { ActionRegistry(BuiltInActions.all()) }

    public func register(_ action: any PowerAction) {
        lock.withLock {
            let id = action.descriptor.id
            precondition(byID[id] == nil, "duplicate action id \(id)")
            byID[id] = action; order.append(id)
        }
    }

    public func action(_ id: String) -> (any PowerAction)? { lock.withLock { byID[id] } }

    public var all: [any PowerAction] { lock.withLock { order.compactMap { byID[$0] } } }
    public var descriptors: [ActionDescriptor] { all.map(\.descriptor) }

    /// Build the Finder menu from descriptors + settings.
    public func menuModel(settings: ClicksmithSettings, paths: SharedPaths = .standard) -> MenuModel {
        let env = MenuEnvironment(settings: settings, paths: paths)
        // Resolve dynamic menus first; hidden ones drop out.
        let visible: [ActionDescriptor] = all.compactMap { a in
            var d = a.descriptor
            guard settings.isVisible(d) else { return nil }
            switch a.dynamicMenu(env) {
            case .standard: break
            case .hidden: return nil
            case .variants(let v): d.variants = v; if v.isEmpty { return nil }
            case .title(let t): d.title = t
            case .entry(let t, let o): d.title = t; d.entryOptions = o
            }
            return d
        }
        var nodes: [MenuNode] = []
        let groups = ActionGroup.allCases.filter { g in visible.contains { $0.group == g } }
        for g in groups {
            let own = visible.filter { $0.group == g }.map(Self.node)
            let grouped = g != .app && settings.groupSubmenus && own.count > 1
            var entries: [MenuNode] = []
            for node in own {
                // "New File ▸ New File ▸ …" reads badly: lift the children up one level.
                // Only inside the group submenu, so ungrouped menus keep "New File ▸".
                if grouped, case let .submenu(title, _, kids) = node, title == g.title {
                    entries += kids
                    entries.append(.separator)
                } else {
                    entries.append(node)
                }
            }
            while case .separator? = entries.last { entries.removeLast() }
            if g == .app {
                nodes.append(.separator); nodes += entries
            } else if grouped {
                nodes.append(.submenu(title: g.title, symbol: g.symbol, children: entries))
            } else {
                nodes += entries
            }
        }
        return MenuModel(rootTitle: settings.menuTitle, flatten: settings.flattenMenu, items: nodes)
    }

    static func node(_ d: ActionDescriptor) -> MenuNode {
        func entry(_ title: String, _ symbol: String?, _ options: [String: String], _ exts: Set<String>) -> MenuAction {
            MenuAction(actionID: d.id, title: title, symbol: symbol, contexts: d.contexts, extensions: exts,
                       minCount: d.minCount, maxCount: d.maxCount, options: options)
        }
        guard !d.variants.isEmpty else { return .action(entry(d.title, d.symbol, d.entryOptions, d.extensions)) }
        // One choice only (e.g. Copy To with no favourites): a direct "Copy To…" item, not a one-item submenu.
        if d.variants.count == 1, let v = d.variants.first {
            let title = v.title.hasSuffix("…") ? d.title + "…" : d.title
            return .action(entry(title, d.symbol, v.options, v.extensions.isEmpty ? d.extensions : v.extensions))
        }
        let kids = d.variants.map { v in MenuNode.action(entry(v.title, v.symbol, v.options, v.extensions.isEmpty ? d.extensions : v.extensions)) }
        return .submenu(title: d.title, symbol: d.symbol, children: kids)
    }
}
