import Foundation

public enum ModifierSide: String, Codable, Sendable, CaseIterable {
    case command, option, shift, control

    var symbol: String {
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
    var independentMask: UInt64 {
        switch self {
        case .command: 1 << 20
        case .option: 1 << 19
        case .shift: 1 << 17
        case .control: 1 << 18
        }
    }
}

public enum Shortcut: Codable, Sendable, Equatable {
    case bothSides(ModifierSide)
    case combo(keyCode: UInt16, modifiers: UInt64, display: String)

    public static let `default` = Shortcut.bothSides(.command)

    public var display: String {
        switch self {
        case .bothSides(let side): "\(side.symbol) + \(side.symbol)"
        case .combo(_, _, let display): display
        }
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
        let others = ModifierSide.allCases
            .filter { $0 != side }
            .reduce(UInt64(0)) { $0 | $1.independentMask }
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
