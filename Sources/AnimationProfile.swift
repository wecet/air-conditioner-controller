import Foundation

/// Four independent settings composed into the illustration, never device commands.
struct AnimationProfile {
    let mode: Int
    let fan: Int
    let swing: Int
    let sleep: Bool

    var fanDuration: Double { [2.6, 3.4, 2.8, 2.2, 1.6, 1.0][min(5, max(0, fan))] }
    var pulses: Int { fan == 0 ? 2 : (fan >= 4 ? 3 : (fan == 1 ? 1 : 2)) }
    var opacity: Double { sleep ? 0.30 : 0.65 }
    var sweep: Bool { swing == 1 }
    // All five fixed blade positions have distinct airflow angles.
    var fixedAngle: Double {
        switch swing {
        case 2: return -0.55
        case 3: return -0.28
        case 4: return 0
        case 5: return 0.28
        case 6: return 0.55
        default: return 0.12
        }
    }
    func angle(at time: Double) -> Double { sweep ? sin(time * 1.3) * 0.55 : fixedAngle }
    var modeSymbol: String {
        switch mode {
        case 1: return "snowflake"
        case 2: return "drop.fill"
        case 3: return "fan"
        case 4: return "sun.max.fill"
        default: return "sparkles"
        }
    }
}
