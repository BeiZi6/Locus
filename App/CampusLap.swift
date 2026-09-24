import CoreLocation

struct CampusPoint {
    var coordinate: CLLocationCoordinate2D
    var speedKmh: Double
}

/// 哈工大一校区操场。控制点是地图上的火星坐标，沿跑道取 100 个点。
enum CampusLap {
    static let pointCount = 100
    static let points: [CampusPoint] = make()
    static let length: Double = {
        let ring = points.map(\.coordinate)
        var total = 0.0
        for index in ring.indices {
            total += Geo.distance(ring[index], ring[(index + 1) % ring.count])
        }
        return total
    }()

    static var slowest: Double { points.map(\.speedKmh).min() ?? 0 }
    static var fastest: Double { points.map(\.speedKmh).max() ?? 0 }

    /// 在软件里沿着体育场跑道点下来的一圈。
    private static let control: [CLLocationCoordinate2D] = [
        .init(latitude: 45.7393328, longitude: 126.6342235),
        .init(latitude: 45.7393390, longitude: 126.6341266),
        .init(latitude: 45.7393356, longitude: 126.6340721),
        .init(latitude: 45.7393092, longitude: 126.6340054),
        .init(latitude: 45.7392902, longitude: 126.6339609),
        .init(latitude: 45.7392456, longitude: 126.6338907),
        .init(latitude: 45.7391826, longitude: 126.6338033),
        .init(latitude: 45.7391178, longitude: 126.6337631),
        .init(latitude: 45.7390385, longitude: 126.6337435),
        .init(latitude: 45.7389907, longitude: 126.6337336),
        .init(latitude: 45.7388281, longitude: 126.6337313),
        .init(latitude: 45.7387567, longitude: 126.6337241),
        .init(latitude: 45.7387109, longitude: 126.6337182),
        .init(latitude: 45.7386505, longitude: 126.6337352),
        .init(latitude: 45.7386152, longitude: 126.6337412),
        .init(latitude: 45.7385720, longitude: 126.6337375),
        .init(latitude: 45.7385055, longitude: 126.6337353),
        .init(latitude: 45.7384264, longitude: 126.6337274),
        .init(latitude: 45.7383233, longitude: 126.6337301),
        .init(latitude: 45.7382533, longitude: 126.6337580),
        .init(latitude: 45.7381127, longitude: 126.6338314),
        .init(latitude: 45.7380762, longitude: 126.6339190),
        .init(latitude: 45.7380362, longitude: 126.6341424),
        .init(latitude: 45.7380321, longitude: 126.6343147),
        .init(latitude: 45.7380977, longitude: 126.6344395),
        .init(latitude: 45.7381815, longitude: 126.6345612),
        .init(latitude: 45.7382490, longitude: 126.6346130),
        .init(latitude: 45.7383146, longitude: 126.6346710),
        .init(latitude: 45.7384118, longitude: 126.6346582),
        .init(latitude: 45.7385022, longitude: 126.6346621),
        .init(latitude: 45.7385706, longitude: 126.6346676),
        .init(latitude: 45.7386531, longitude: 126.6346569),
        .init(latitude: 45.7387492, longitude: 126.6346470),
        .init(latitude: 45.7388887, longitude: 126.6346448),
        .init(latitude: 45.7389541, longitude: 126.6346334),
        .init(latitude: 45.7390012, longitude: 126.6346244),
        .init(latitude: 45.7390337, longitude: 126.6346340),
        .init(latitude: 45.7390944, longitude: 126.6346144),
        .init(latitude: 45.7391957, longitude: 126.6345300),
        .init(latitude: 45.7392905, longitude: 126.6343903),
        .init(latitude: 45.7392905, longitude: 126.6343898),
        .init(latitude: 45.7393325, longitude: 126.6342621),
        .init(latitude: 45.7393398, longitude: 126.6342171),
    ]

    private static func make() -> [CampusPoint] {
        var ring = control
        if ring.count >= 2, Geo.distance(ring[0], ring[ring.count - 1]) < 3 {
            ring.removeLast()
        }
        var cumulative = [0.0]
        for index in ring.indices {
            let next = ring[(index + 1) % ring.count]
            cumulative.append(cumulative[cumulative.count - 1] + Geo.distance(ring[index], next))
        }
        let total = cumulative[cumulative.count - 1]
        guard ring.count >= 2, total > 1 else { return [] }
        let samples = (0..<pointCount).map { index in
            sample(ring, cumulative: cumulative, total: total, distance: total * Double(index) / Double(pointCount))
        }
        var turns = [Double](repeating: 0, count: pointCount)
        for index in samples.indices {
            let incoming = Geo.bearing(samples[(index + pointCount - 1) % pointCount], samples[index])
            let outgoing = Geo.bearing(samples[index], samples[(index + 1) % pointCount])
            var turn = abs(outgoing - incoming)
            if turn > 180 { turn = 360 - turn }
            turns[index] = turn
        }
        let raw = turns.map { turn -> Double in
            let blend = smoothstep(min(1, turn / 8))
            return 8.2 + (11.4 - 8.2) * (1 - blend)
        }
        let window = 2
        let smoothed = samples.indices.map { index -> Double in
            var sum = 0.0
            for offset in -window...window {
                sum += raw[(index + offset + pointCount) % pointCount]
            }
            return sum / Double(window * 2 + 1)
        }
        // 按耗时配平到平均 4'00"/km，弯道仍慢于直道。
        let harmonic = Double(smoothed.count) / smoothed.reduce(0.0) { $0 + 1.0 / $1 }
        let scale = 15.0 / harmonic
        return samples.indices.map { index in
            CampusPoint(coordinate: samples[index], speedKmh: smoothed[index] * scale)
        }
    }

    /// 横向偏移，单位米。慢慢左右飘，最远 3 米，仍在操场内。
    static func stepLane(_ current: Double) -> Double {
        let nudged = min(3.0, max(-3.0, current + Double.random(in: -0.55...0.55)))
        return nudged * 0.96
    }

    /// 速度起伏，单位 km/h。在配速附近小幅来回，平均仍接近 4 分钟。
    static func stepSpeed(_ current: Double) -> Double {
        let nudged = min(1.3, max(-1.3, current + Double.random(in: -0.55...0.55)))
        return nudged * 0.9
    }

    private static func sample(
        _ ring: [CLLocationCoordinate2D],
        cumulative: [Double],
        total: Double,
        distance: Double
    ) -> CLLocationCoordinate2D {
        let target = distance.truncatingRemainder(dividingBy: total)
        var index = 0
        while index < ring.count, cumulative[index + 1] < target {
            index += 1
        }
        let span = cumulative[index + 1] - cumulative[index]
        let fraction = span > 0 ? (target - cumulative[index]) / span : 0
        return Geo.lerp(ring[index], ring[(index + 1) % ring.count], fraction)
    }

    private static func smoothstep(_ value: Double) -> Double {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }
}
