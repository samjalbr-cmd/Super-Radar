import Foundation

/// One radar-derived storm cell from the Iowa Environmental Mesonet attribute
/// table — the same feed the web dashboard draws its tracks from.
struct StormCell {
    let lat: Double
    let lon: Double
    /// Direction the cell is coming FROM, in degrees. Verified against two volume
    /// scans five minutes apart: measured displacement matched the reciprocal of
    /// this field to within 18 degrees, and the field itself to 162.
    let drct: Double
    let speedKt: Double
    let maxDbz: Double
    let hailInches: Double
    let posh: Double
    let tvs: Bool
    let meso: Bool
    let observed: Date

    /// Heading the cell is travelling towards.
    var heading: Double { (drct + 180).truncatingRemainder(dividingBy: 360) }

    /// Worth drawing at all. Mirrors `stormNotable` in the web app.
    var notable: Bool {
        if tvs || meso { return true }
        return maxDbz >= 50 || posh >= 40 || hailInches >= 0.75
    }
}

/// How close a cell will pass, and when.
struct Approach {
    let cell: StormCell
    /// Minutes until closest approach, counted from the cell's observation time
    /// so the number keeps falling between data refreshes.
    let minutes: Double
    /// Perpendicular miss distance in nautical miles.
    let missNm: Double

    var missMiles: Int { Int((missNm * 1.15078).rounded()) }
    var arrival: Date { Date().addingTimeInterval(max(0, minutes) * 60) }

    var headline: String {
        if cell.tvs { return "TORNADO SIGNATURE" }
        if cell.meso { return "ROTATING CELL" }
        if cell.hailInches >= 1 || cell.posh >= 50 { return "SEVERE CELL" }
        return "STORM"
    }

    var detail: String {
        var bits: [String] = []
        if cell.hailInches >= 0.25 {
            bits.append(String(format: "%.2f\" hail", cell.hailInches))
        } else if cell.posh >= 30 {
            bits.append("\(Int(cell.posh))% hail")
        }
        if cell.maxDbz > 0 { bits.append("\(Int(cell.maxDbz)) dBZ") }
        bits.append("\(Int((cell.speedKt * 1.15078).rounded())) mph")
        return bits.joined(separator: " · ")
    }
}

enum StormArrival {
    /// Nothing further out than this is worth projecting in a straight line.
    static let horizonMinutes: Double = 90
    /// How near a pass counts as "coming here".
    static let corridorNm: Double = 12

    /// Along-track and perpendicular distance from a cell to a point, in nautical
    /// miles. Flat-earth is accurate enough over the ~100 nm that matters.
    static func approach(cell: StormCell, lat: Double, lon: Double) -> (along: Double, off: Double) {
        let midLat = ((cell.lat + lat) / 2) * .pi / 180
        let dx = (lon - cell.lon) * 60 * cos(midLat)   // east, nm
        let dy = (lat - cell.lat) * 60                 // north, nm
        let r = cell.heading * .pi / 180
        let ux = sin(r), uy = cos(r)
        return (along: dx * ux + dy * uy, off: abs(dx * uy - dy * ux))
    }

    /// The soonest credible arrival at a point, or nil.
    static func soonest(cells: [StormCell], lat: Double, lon: Double, now: Date = Date()) -> Approach? {
        var best: Approach?
        for cell in cells where cell.speedKt >= 5 && cell.notable {
            let a = approach(cell: cell, lat: lat, lon: lon)
            guard a.along > 0, a.off <= corridorNm else { continue }
            let elapsed = now.timeIntervalSince(cell.observed) / 60
            let minutes = (a.along / cell.speedKt) * 60 - elapsed
            guard minutes > -5, minutes <= horizonMinutes else { continue }
            if best == nil || minutes < best!.minutes {
                best = Approach(cell: cell, minutes: minutes, missNm: a.off)
            }
        }
        return best
    }
}
