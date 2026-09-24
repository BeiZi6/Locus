import AppKit
import MapKit
import SwiftUI

struct SurveyMap: NSViewRepresentable {
    var pin: CLLocationCoordinate2D?
    var route: [CLLocationCoordinate2D]
    var focusToken: Int
    var fitToken: Int
    var onTap: (CLLocationCoordinate2D) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTap: onTap)
    }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsCompass = true
        map.showsScale = true
        map.mapType = .mutedStandard
        map.setRegion(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 31.2, longitude: 121.5),
                span: MKCoordinateSpan(latitudeDelta: 8, longitudeDelta: 8)
            ),
            animated: false
        )
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.click(_:)))
        map.addGestureRecognizer(click)
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        context.coordinator.onTap = onTap
        map.removeAnnotations(map.annotations.filter { $0 is PinMark })
        map.removeOverlays(map.overlays)
        if let pin {
            map.addAnnotation(PinMark(coordinate: pin))
        }
        if route.count >= 2 {
            map.addOverlay(MKPolyline(coordinates: route, count: route.count))
        }
        if context.coordinator.focusToken != focusToken {
            context.coordinator.focusToken = focusToken
            let center = pin ?? route.first
            if let center {
                map.setRegion(
                    MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)),
                    animated: true
                )
            }
        }
        if context.coordinator.fitToken != fitToken {
            context.coordinator.fitToken = fitToken
            guard route.count >= 2 else { return }
            var rect = MKMapRect.null
            for coordinate in route {
                let point = MKMapPoint(coordinate)
                rect = rect.union(MKMapRect(origin: point, size: MKMapSize(width: 0, height: 0)))
            }
            map.setVisibleMapRect(
                rect,
                edgePadding: NSEdgeInsets(top: 72, left: 72, bottom: 72, right: 72),
                animated: true
            )
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var onTap: (CLLocationCoordinate2D) -> Void
        var focusToken = -1
        var fitToken = -1

        init(onTap: @escaping (CLLocationCoordinate2D) -> Void) {
            self.onTap = onTap
        }

        @objc func click(_ gesture: NSClickGestureRecognizer) {
            guard let map = gesture.view as? MKMapView else { return }
            let point = gesture.location(in: map)
            onTap(map.convert(point, toCoordinateFrom: map))
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard annotation is PinMark else { return nil }
            let ident = "pin"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: ident)
                ?? MKAnnotationView(annotation: annotation, reuseIdentifier: ident)
            view.annotation = annotation
            view.image = MarkerImage.crosshair
            view.centerOffset = NSPoint(x: 0, y: 0)
            return view
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            let renderer = MKPolylineRenderer(overlay: overlay)
            renderer.strokeColor = NSColor(srgbRed: 0.69, green: 0.345, blue: 0.145, alpha: 0.92)
            renderer.lineWidth = 4
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        }
    }
}

final class PinMark: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    init(coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
    }
}

enum MarkerImage {
    static let crosshair: NSImage = {
        let size = NSSize(width: 28, height: 28)
        let image = NSImage(size: size)
        image.lockFocus()
        let ink = NSColor(srgbRed: 0.69, green: 0.345, blue: 0.145, alpha: 1)
        ink.setStroke()
        let bounds = NSRect(x: 1, y: 1, width: 26, height: 26)
        let path = NSBezierPath(ovalIn: bounds)
        path.lineWidth = 2
        path.stroke()
        let vertical = NSBezierPath()
        vertical.move(to: NSPoint(x: 14, y: 5))
        vertical.line(to: NSPoint(x: 14, y: 23))
        vertical.lineWidth = 1.5
        vertical.stroke()
        let horizontal = NSBezierPath()
        horizontal.move(to: NSPoint(x: 5, y: 14))
        horizontal.line(to: NSPoint(x: 23, y: 14))
        horizontal.lineWidth = 1.5
        horizontal.stroke()
        image.unlockFocus()
        return image
    }()
}
