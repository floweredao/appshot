import Foundation

public enum ModifierSide: String, Codable, Sendable, CaseIterable {
    case command, option, shift, control

    public var symbol: String {
        switch self {
        case .command: "⌘"
        case .option: "⌥"
        case .shift: "⇧"
        case .control: "⌃"
        }
    }

    // NX_DEVICE*KEYMASK values from IOKit/hidsystem/IOLLEvent.h (left, right).
    var deviceMasks: (left: UInt64, right: UInt64) {
        switch self {
        case .command: (0x08, 0x10)
        case .option: (0x20, 0x40)
        case .shift: (0x02, 0x04)
        case .control: (0x01, 0x2000)
        }
    }

    // NSEvent.ModifierFlags device-independent bits.
    public var independentMask: UInt64 {
        switch self {
        case .command: 1 << 20
        case .option: 1 << 19
        case .shift: 1 << 17
        case .control: 1 << 18
        }
    }

    static let allIndependent = allCases.reduce(UInt64(0)) { $0 | $1.independentMask }

    static func only(in rawFlags: UInt64) -> ModifierSide? {
        let pressed = allCases.filter { rawFlags & $0.independentMask != 0 }
        return pressed.count == 1 ? pressed[0] : nil
    }
}

public enum Shortcut: Codable, Sendable, Equatable {
    case bothSides(ModifierSide)
    case doubleTap(ModifierSide)
    case combo(keyCode: UInt16, modifiers: UInt64, display: String)

    public static let `default` = Shortcut.bothSides(.command)

    public var display: String {
        switch self {
        case .bothSides(let side): "\(side.symbol) + \(side.symbol)"
        case .doubleTap(let side): "\(side.symbol) \(side.symbol)"
        case .combo(_, _, let display): display
        }
    }

    public static func comboDisplay(keyCode: UInt16, modifiers: UInt64, key: String) -> String {
        let order: [ModifierSide] = [.control, .option, .shift, .command]
        let symbols = order.filter { modifiers & $0.independentMask != 0 }.map(\.symbol).joined()
        return symbols + key
    }

    public var knownConflict: String? {
        guard case .combo(let keyCode, let modifiers, _) = self else { return nil }
        let set = modifiers & ModifierSide.allIndependent
        let cmd = ModifierSide.command.independentMask
        let shift = ModifierSide.shift.independentMask
        let ctrl = ModifierSide.control.independentMask
        let opt = ModifierSide.option.independentMask
        let table: [(UInt16, UInt64, String)] = [
            (49, cmd, "Spotlight"),
            (49, cmd | opt, "Finder search"),
            (49, ctrl, "Input source"),
            (49, ctrl | opt, "Input source"),
            (48, cmd, "App switcher"),
            (50, cmd, "Window cycling"),
            (12, cmd, "Quit"),
            (13, cmd, "Close window"),
            (4, cmd, "Hide app"),
            (46, cmd, "Minimize"),
            (8, cmd, "Copy"), (9, cmd, "Paste"), (7, cmd, "Cut"), (6, cmd, "Undo"), (0, cmd, "Select all"),
            (1, cmd, "Save"), (3, cmd, "Find"), (45, cmd, "New"), (31, cmd, "Open"), (35, cmd, "Print"),
            (20, cmd | shift, "Screenshot"), (21, cmd | shift, "Screenshot"), (23, cmd | shift, "Screenshot"),
            (12, cmd | ctrl, "Lock screen"),
            (3, cmd | ctrl, "Full screen"),
            (2, cmd | ctrl, "Look up"),
        ]
        return table.first { $0.0 == keyCode && $0.1 == set }?.2
    }
}

public struct DualModifierDetector: Sendable {
    public let side: ModifierSide
    private var fired = false
    private var poisoned = false

    public init(side: ModifierSide) {
        self.side = side
    }

    public mutating func flagsChanged(_ rawFlags: UInt64) -> Bool {
        let masks = side.deviceMasks
        let left = rawFlags & masks.left != 0
        let right = rawFlags & masks.right != 0
        let others = ModifierSide.allIndependent & ~side.independentMask
        if !left && !right {
            fired = false
            poisoned = false
            return false
        }
        if rawFlags & others != 0 { poisoned = true }
        guard left && right, !fired, !poisoned else { return false }
        fired = true
        return true
    }

    public mutating func keyDown() {
        poisoned = true
    }
}

public struct DoubleTapDetector: Sendable {
    public let side: ModifierSide
    public var interval: TimeInterval
    private var down = false
    private var dirty = false
    private var lastTapEnd: TimeInterval?

    public init(side: ModifierSide, interval: TimeInterval = 0.35) {
        self.side = side
        self.interval = interval
    }

    public mutating func flagsChanged(_ rawFlags: UInt64, at time: TimeInterval) -> Bool {
        let mine = rawFlags & side.independentMask != 0
        let others = rawFlags & (ModifierSide.allIndependent & ~side.independentMask) != 0
        if others {
            dirty = true
            lastTapEnd = nil
        }
        if mine && !down {
            down = true
            if !others { dirty = false }
            return false
        }
        if !mine && down {
            down = false
            defer { dirty = false }
            guard !dirty else {
                lastTapEnd = nil
                return false
            }
            if let last = lastTapEnd, time - last <= interval {
                lastTapEnd = nil
                return true
            }
            lastTapEnd = time
        }
        return false
    }

    public mutating func keyDown() {
        dirty = true
        lastTapEnd = nil
    }
}

public struct ShortcutRecorder: Sendable {
    public enum Outcome: Equatable, Sendable {
        case pending
        case recorded(Shortcut)
        case rejected(String)
    }

    private var dual: [ModifierSide: DualModifierDetector]
    private var taps: [ModifierSide: DoubleTapDetector]

    public init(tapInterval: TimeInterval = 0.4) {
        dual = Dictionary(uniqueKeysWithValues: ModifierSide.allCases.map { ($0, DualModifierDetector(side: $0)) })
        taps = Dictionary(uniqueKeysWithValues: ModifierSide.allCases.map { ($0, DoubleTapDetector(side: $0, interval: tapInterval)) })
    }

    public mutating func flagsChanged(_ rawFlags: UInt64, at time: TimeInterval) -> Outcome {
        for side in ModifierSide.allCases {
            if dual[side]!.flagsChanged(rawFlags) { return .recorded(.bothSides(side)) }
        }
        for side in ModifierSide.allCases {
            if taps[side]!.flagsChanged(rawFlags, at: time) { return .recorded(.doubleTap(side)) }
        }
        return .pending
    }

    public mutating func keyDown(keyCode: UInt16, rawFlags: UInt64, key: String) -> Outcome {
        for side in ModifierSide.allCases {
            dual[side]!.keyDown()
            taps[side]!.keyDown()
        }
        let modifiers = rawFlags & ModifierSide.allIndependent
        let strong = ModifierSide.command.independentMask | ModifierSide.option.independentMask | ModifierSide.control.independentMask
        guard modifiers & strong != 0 else { return .rejected("needs-modifier") }
        return .recorded(.combo(
            keyCode: keyCode, modifiers: modifiers,
            display: Shortcut.comboDisplay(keyCode: keyCode, modifiers: modifiers, key: key)
        ))
    }
}
