import CoreLocation
import Foundation
import SwiftUI

enum Ink {
    static let paper = Color(red: 0.910, green: 0.882, blue: 0.824)
    static let sheet = Color(red: 0.965, green: 0.949, blue: 0.910)
    static let ink = Color(red: 0.110, green: 0.098, blue: 0.082)
    static let muted = Color(red: 0.396, green: 0.353, blue: 0.298)
    static let line = Color(red: 0.110, green: 0.098, blue: 0.082).opacity(0.14)
    static let copper = Color(red: 0.690, green: 0.345, blue: 0.145)
    static let pine = Color(red: 0.118, green: 0.365, blue: 0.310)
    static let alert = Color(red: 0.580, green: 0.200, blue: 0.145)
}

enum MoveMode: String, CaseIterable, Identifiable {
    case pin = "定点"
    case stick = "摇杆"
    case route = "路线"
    var id: String { rawValue }
}

struct DeviceItem: Identifiable, Equatable {
    var id: String
    var kind: String
    var name: String
    var detail: String
}

struct SavedPin: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var latitude: Double
    var longitude: Double
    var savedAt: Date

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct SavedRoute: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var points: [SavedPin]
}

struct DeskStore: Codable {
    var favorites: [SavedPin] = []
    var routes: [SavedRoute] = []
    var history: [SavedPin] = []
}

enum Geo {
    static let earth = 6_371_000.0

    static func project(
        _ origin: CLLocationCoordinate2D,
        bearingDeg: Double,
        meters: Double
    ) -> CLLocationCoordinate2D {
        let delta = meters / earth
        let theta = bearingDeg * .pi / 180
        let phi1 = origin.latitude * .pi / 180
        let lam1 = origin.longitude * .pi / 180
        let phi2 = asin(sin(phi1) * cos(delta) + cos(phi1) * sin(delta) * cos(theta))
        let lam2 = lam1 + atan2(
            sin(theta) * sin(delta) * cos(phi1),
            cos(delta) - sin(phi1) * sin(phi2)
        )
        var lon = lam2 * 180 / .pi
        lon = (lon + 540).truncatingRemainder(dividingBy: 360) - 180
        return CLLocationCoordinate2D(latitude: phi2 * 180 / .pi, longitude: lon)
    }

    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let phi1 = a.latitude * .pi / 180
        let phi2 = b.latitude * .pi / 180
        let dlam = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dlam) * cos(phi2)
        let x = cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(dlam)
        var deg = atan2(y, x) * 180 / .pi
        if deg < 0 { deg += 360 }
        return deg
    }

    static func format(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude)
    }

    static func lerp(
        _ a: CLLocationCoordinate2D,
        _ b: CLLocationCoordinate2D,
        _ fraction: Double
    ) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: a.latitude + (b.latitude - a.latitude) * fraction,
            longitude: a.longitude + (b.longitude - a.longitude) * fraction
        )
    }

    /// 国内底图是火星坐标。手机定位和 GPX 用 WGS-84。
    static func toGPS(_ map: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard inMainland(map) else { return map }
        return gcjToWGS(map)
    }

    static func toMap(_ gps: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard inMainland(gps) else { return gps }
        return wgsToGCJ(gps)
    }

    private static func inMainland(_ c: CLLocationCoordinate2D) -> Bool {
        let lat = c.latitude
        let lon = c.longitude
        if lat < 0.8293 || lat > 55.8271 || lon < 72.004 || lon > 137.8347 { return false }
        if (21.8...25.4).contains(lat), (119.9...122.1).contains(lon) { return false }
        if (22.15...22.57).contains(lat), (113.82...114.45).contains(lon) { return false }
        if (22.07...22.22).contains(lat), (113.52...113.65).contains(lon) { return false }
        return true
    }

    private static func wgsToGCJ(_ wgs: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let lat = wgs.latitude
        let lon = wgs.longitude
        var dLat = transformLatitude(lon - 105.0, lat - 35.0)
        var dLon = transformLongitude(lon - 105.0, lat - 35.0)
        let radLat = lat / 180.0 * .pi
        var magic = sin(radLat)
        magic = 1 - 0.00669342162296594323 * magic * magic
        let sqrtMagic = sqrt(magic)
        dLat = (dLat * 180.0) / ((6_378_245.0 * (1 - 0.00669342162296594323)) / (magic * sqrtMagic) * .pi)
        dLon = (dLon * 180.0) / (6_378_245.0 / sqrtMagic * cos(radLat) * .pi)
        return CLLocationCoordinate2D(latitude: lat + dLat, longitude: lon + dLon)
    }

    private static func gcjToWGS(_ gcj: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        var lat = gcj.latitude
        var lon = gcj.longitude
        for _ in 0..<8 {
            let got = wgsToGCJ(CLLocationCoordinate2D(latitude: lat, longitude: lon))
            lat += gcj.latitude - got.latitude
            lon += gcj.longitude - got.longitude
        }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private static func transformLatitude(_ x: Double, _ y: Double) -> Double {
        var ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(y * .pi) + 40.0 * sin(y / 3.0 * .pi)) * 2.0 / 3.0
        ret += (160.0 * sin(y / 12.0 * .pi) + 320 * sin(y * .pi / 30.0)) * 2.0 / 3.0
        return ret
    }

    private static func transformLongitude(_ x: Double, _ y: Double) -> Double {
        var ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(x * .pi) + 40.0 * sin(x / 3.0 * .pi)) * 2.0 / 3.0
        ret += (150.0 * sin(x / 12.0 * .pi) + 300.0 * sin(x / 30.0 * .pi)) * 2.0 / 3.0
        return ret
    }
}

enum GPXFile {
    static func read(url: URL) throws -> [CLLocationCoordinate2D] {
        let data = try Data(contentsOf: url)
        let parser = XMLParser(data: data)
        let delegate = GPXDelegate()
        parser.delegate = delegate
        guard parser.parse() else {
            throw parser.parserError ?? CocoaError(.fileReadCorruptFile)
        }
        if delegate.points.isEmpty {
            throw CocoaError(.fileReadCorruptFile)
        }
        return delegate.points.map(Geo.toMap)
    }

    static func write(_ points: [CLLocationCoordinate2D], to url: URL) throws {
        var body = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Locus">
          <trk><name>Locus</name><trkseg>

        """
        for point in points {
            let gps = Geo.toGPS(point)
            body += String(format: "    <trkpt lat=\"%.7f\" lon=\"%.7f\"></trkpt>\n", gps.latitude, gps.longitude)
        }
        body += "  </trkseg></trk>\n</gpx>\n"
        try body.data(using: .utf8)?.write(to: url)
    }
}

private final class GPXDelegate: NSObject, XMLParserDelegate {
    var points: [CLLocationCoordinate2D] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName == "trkpt" || elementName == "wpt" || elementName == "rtept" else { return }
        guard let lat = attributeDict["lat"].flatMap(Double.init),
              let lon = attributeDict["lon"].flatMap(Double.init) else { return }
        points.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
    }
}
