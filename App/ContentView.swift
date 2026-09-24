import AppKit
import CoreLocation
import MapKit
import SwiftUI
import UniformTypeIdentifiers

private enum DeskPane: String, CaseIterable, Identifiable {
    case device = "设备"
    case move = "移动"
    case campus = "乐跑"
    case disguise = "伪装"
    case archive = "记录"
    var id: String { rawValue }
}

struct ContentView: View {
    @StateObject private var bridge = DeviceBridge()
    @State private var store = DeskStore()
    @State private var pane: DeskPane = .move
    @State private var mode: MoveMode = .pin
    @State private var selectedID: String?
    @State private var pin: CLLocationCoordinate2D?
    @State private var route: [CLLocationCoordinate2D] = []
    @State private var speedKmh = 4.5
    @State private var query = ""
    @State private var focusToken = 0
    @State private var fitToken = 0
    @State private var stickBearing: Double?
    @State private var routeCursor = 0
    @State private var playingRoute = false
    @State private var writeOnTap = false
    @State private var favoriteName = ""
    @State private var disguise = true
    @State private var accuracyM = 8.0
    @State private var holdFix = true
    @State private var jitter = true
    @State private var glide = true
    @State private var course = 0.0
    @State private var noiseNorth = 0.0
    @State private var noiseEast = 0.0
    @State private var settled: CLLocationCoordinate2D?
    @State private var gliding = false
    @State private var glideCursor: CLLocationCoordinate2D?
    @State private var glideTarget: CLLocationCoordinate2D?
    @State private var campusRunning = false
    @State private var campusLaps = 0
    @State private var campusSpeeds: [Double] = []
    @State private var campusStamp = Date()
    @State private var campusOnRoute: CLLocationCoordinate2D?
    @State private var laneOffset = 0.0
    @State private var speedJitter = 0.0
    @State private var liveSpeed = CampusLap.points[0].speedKmh
    @State private var stickClock = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()
    @State private var routeClock = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()
    @State private var holdClock = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 332)
            Rectangle().fill(Ink.line).frame(width: 1)
            mapColumn
        }
        .background(Ink.paper)
        .onAppear {
            store = StoreFile.load()
            bridge.start()
        }
        .onDisappear {
            bridge.stop()
            StoreFile.save(store)
        }
        .onReceive(stickClock) { _ in
            guard let bearing = stickBearing, !bridge.busy else { return }
            step(bearing: bearing)
        }
        .onReceive(routeClock) { _ in
            guard !bridge.busy else { return }
            if campusRunning {
                advanceCampus()
                return
            }
            if gliding {
                advanceGlide()
                return
            }
            guard playingRoute else { return }
            advanceRoute()
        }
        .onReceive(holdClock) { _ in
            guard disguise, holdFix, bridge.simulating, !bridge.busy else { return }
            guard stickBearing == nil, !playingRoute, !gliding, !campusRunning else { return }
            guard let base = settled ?? pin, let selectedID else { return }
            let fix = onCampusLap ? base : reported(base)
            Task { await commit(fix, target: selectedID, record: false, moving: false, bearing: course, quiet: true) }
        }
        .onChange(of: mode) { _, newMode in
            if newMode != .stick { stickBearing = nil }
            if newMode != .route { playingRoute = false }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            paneBar
            ScrollView {
                paneBody
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            statusBar
        }
        .background(Ink.sheet)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("LOCUS")
                .font(.custom("Avenir Next", size: 12).weight(.semibold))
                .tracking(2.4)
                .foregroundStyle(Ink.copper)
            Text("定位台")
                .font(.custom("Iowan Old Style", size: 22))
                .foregroundStyle(Ink.ink)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private var paneBar: some View {
        HStack(spacing: 0) {
            ForEach(DeskPane.allCases) { item in
                Button(item.rawValue) { pane = item }
                    .buttonStyle(PaneTab(active: pane == item))
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var paneBody: some View {
        switch pane {
        case .device:
            deviceList
        case .move:
            VStack(alignment: .leading, spacing: 14) {
                modeBar
                coordinateBlock
                if mode == .route { routeEditor }
            }
        case .campus:
            campusPane
        case .disguise:
            disguiseBlock
        case .archive:
            VStack(alignment: .leading, spacing: 18) {
                favorites
                history
            }
        }
    }

    private var deviceList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(bridge.devices.isEmpty ? "没有设备" : "\(bridge.devices.count) 台")
                    .font(.custom("Avenir Next", size: 12))
                    .foregroundStyle(Ink.muted)
                Spacer()
                Button("刷新") { Task { await bridge.refresh() } }
                    .buttonStyle(QuietButton())
            }
            if bridge.devices.isEmpty {
                Text(bridge.warnings.isEmpty ? "用数据线连接手机，解锁并信任这台 Mac。" : bridge.warnings.joined(separator: "\n"))
                    .font(.custom("Avenir Next", size: 12))
                    .foregroundStyle(Ink.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(bridge.devices) { device in
                    Button {
                        selectedID = device.id
                    } label: {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                    .font(.custom("Avenir Next", size: 14).weight(.medium))
                                Text(device.detail)
                                    .font(.custom("Menlo", size: 10))
                                    .foregroundStyle(Ink.muted)
                            }
                            Spacer()
                            Circle()
                                .fill(selectedID == device.id ? Ink.copper : Color.clear)
                                .overlay(Circle().stroke(Ink.line, lineWidth: 1))
                                .frame(width: 10, height: 10)
                        }
                        .padding(.vertical, 7)
                        .padding(.horizontal, 8)
                        .background(selectedID == device.id ? Ink.paper : Color.clear)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Ink.ink)
                }
            }
        }
    }

    private var modeBar: some View {
        HStack(spacing: 0) {
            ForEach(MoveMode.allCases) { item in
                Button(item.rawValue) { mode = item }
                    .buttonStyle(ModeButton(active: mode == item))
            }
        }
    }

    private var coordinateBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(pin.map { Geo.format(Geo.toGPS($0)) } ?? "在地图上点一个位置")
                .font(.custom("Menlo", size: 12))
                .foregroundStyle(Ink.ink)
            HStack(spacing: 8) {
                Text("速度")
                    .font(.custom("Avenir Next", size: 12))
                    .foregroundStyle(Ink.muted)
                Slider(value: $speedKmh, in: 1...40)
                    .tint(Ink.copper)
                Text(String(format: "%.1f km/h", speedKmh))
                    .font(.custom("Menlo", size: 11))
                    .frame(width: 72, alignment: .trailing)
            }
            HStack(spacing: 8) {
                Button(bridge.busy ? "写入中" : "写到设备") { Task { await commitPin() } }
                    .buttonStyle(PrimaryButton())
                    .disabled(pin == nil || selectedID == nil || bridge.busy)
                Button("停止模拟") { Task { await stopSimulation() } }
                    .buttonStyle(QuietButton())
                    .disabled(selectedID == nil || bridge.busy)
            }
            if mode == .pin {
                Toggle("点地图后立即写入", isOn: $writeOnTap)
                    .font(.custom("Avenir Next", size: 12))
                    .tint(Ink.pine)
            }
        }
        .padding(12)
        .background(Ink.paper)
        .overlay(Rectangle().stroke(Ink.line, lineWidth: 1))
    }

    private var disguiseBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("伪装", isOn: $disguise)
                .font(.custom("Avenir Next", size: 13).weight(.medium))
                .tint(Ink.pine)
            if disguise {
                HStack(spacing: 8) {
                    Text("精度")
                        .font(.custom("Avenir Next", size: 12))
                        .foregroundStyle(Ink.muted)
                    Slider(value: $accuracyM, in: 3...40)
                        .tint(Ink.copper)
                    Text(String(format: "±%.0f m", accuracyM))
                        .font(.custom("Menlo", size: 11))
                        .frame(width: 52, alignment: .trailing)
                }
                Toggle("每秒重写，压住 Wi-Fi 和蜂窝把位置拉回去", isOn: $holdFix)
                    .font(.custom("Avenir Next", size: 12))
                    .tint(Ink.pine)
                Toggle("精度范围内轻微晃动", isOn: $jitter)
                    .font(.custom("Avenir Next", size: 12))
                    .tint(Ink.pine)
                Toggle("距离超过 80 米时按当前速度走过去", isOn: $glide)
                    .font(.custom("Avenir Next", size: 12))
                    .tint(Ink.pine)
                Text(String(format: "当前 %.1f km/h · 航向 %.0f°", shownSpeed, course))
                    .font(.custom("Menlo", size: 11))
                    .foregroundStyle(Ink.muted)
                Text("Android 同时写入 gps、network、fused。iOS 只收坐标，靠晃动和每秒重写维持。")
                    .font(.custom("Avenir Next", size: 11))
                    .foregroundStyle(Ink.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.paper)
        .overlay(Rectangle().stroke(Ink.line, lineWidth: 1))
    }

    private var routeEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("路线 · \(route.count) 个点")
            HStack {
                Button(playingRoute ? "暂停" : "沿路线移动") {
                    campusRunning = false
                    if playingRoute {
                        playingRoute = false
                    } else {
                        routeCursor = 0
                        pin = route.first
                        playingRoute = true
                    }
                }
                .buttonStyle(PrimaryButton())
                .disabled(route.count < 2 || selectedID == nil)
                Button("清空") {
                    playingRoute = false
                    campusRunning = false
                    campusSpeeds = []
                    route = []
                }
                .buttonStyle(QuietButton())
            }
            HStack {
                Button("导入 GPX") { importGPX() }.buttonStyle(QuietButton())
                Button("导出 GPX") { exportGPX() }.buttonStyle(QuietButton()).disabled(route.count < 2)
                Button("收藏路线") { saveRoute() }.buttonStyle(QuietButton()).disabled(route.count < 2)
            }
        }
    }

    private var favorites: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("收藏")
            HStack {
                TextField("名称", text: $favoriteName)
                    .textFieldStyle(.plain)
                    .font(.custom("Avenir Next", size: 13))
                    .padding(6)
                    .overlay(Rectangle().stroke(Ink.line, lineWidth: 1))
                Button("记下当前点") { savePin() }
                    .buttonStyle(QuietButton())
                    .disabled(pin == nil)
            }
            if store.favorites.isEmpty && store.routes.isEmpty {
                Text("还没有收藏。")
                    .font(.custom("Avenir Next", size: 12))
                    .foregroundStyle(Ink.muted)
            }
            ForEach(store.favorites) { item in
                Button {
                    pin = item.coordinate
                    focusToken += 1
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name).font(.custom("Avenir Next", size: 13))
                        Text(Geo.format(Geo.toGPS(item.coordinate)))
                            .font(.custom("Menlo", size: 10))
                            .foregroundStyle(Ink.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("删除") { store.favorites.removeAll { $0.id == item.id }; StoreFile.save(store) }
                }
            }
            ForEach(store.routes) { item in
                Button {
                    route = item.points.map(\.coordinate)
                    pin = route.first
                    mode = .route
                    pane = .move
                    focusToken += 1
                } label: {
                    Text("\(item.name) · \(item.points.count) 点")
                        .font(.custom("Avenir Next", size: 13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("最近写入")
            if store.history.isEmpty {
                Text("写入成功后会出现在这里。")
                    .font(.custom("Avenir Next", size: 12))
                    .foregroundStyle(Ink.muted)
            }
            ForEach(store.history.prefix(8)) { item in
                Button {
                    pin = item.coordinate
                    focusToken += 1
                } label: {
                    Text(Geo.format(Geo.toGPS(item.coordinate)))
                        .font(.custom("Menlo", size: 11))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Ink.ink)
            }
        }
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(bridge.status)
                .font(.custom("Avenir Next", size: 12).weight(.medium))
            if let error = bridge.lastError {
                Text(error)
                    .font(.custom("Avenir Next", size: 11))
                    .foregroundStyle(Ink.alert)
                    .lineLimit(4)
            } else if bridge.simulating {
                Text("模拟保持到你点停止，或重启手机。")
                    .font(.custom("Avenir Next", size: 11))
                    .foregroundStyle(Ink.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Ink.paper)
    }

    private var mapColumn: some View {
        ZStack(alignment: .topLeading) {
            SurveyMap(pin: pin, route: mapRoute, focusToken: focusToken, fitToken: fitToken) { coordinate in
                handleTap(coordinate)
            }
            VStack(alignment: .leading, spacing: 8) {
                searchBar
                if let error = bridge.lastError {
                    Text(error)
                        .font(.custom("Avenir Next", size: 12))
                        .foregroundStyle(Ink.sheet)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Ink.alert)
                }
            }
            .padding(14)
            if mode == .stick {
                CompassRose { bearing in
                    stickBearing = bearing
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(22)
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            TextField("搜地点", text: $query)
                .textFieldStyle(.plain)
                .font(.custom("Avenir Next", size: 14))
                .onSubmit { Task { await search() } }
            Button("定位") { Task { await search() } }
                .buttonStyle(PrimaryButton())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 320)
        .background(Ink.sheet)
        .overlay(Rectangle().stroke(Ink.ink.opacity(0.25), lineWidth: 1))
    }

    private var mapRoute: [CLLocationCoordinate2D] {
        if gliding, let glideCursor, let glideTarget {
            return [glideCursor, glideTarget]
        }
        if onCampusLap, let first = route.first {
            return route + [first]
        }
        return route
    }

    private var onCampusLap: Bool {
        campusSpeeds.count == CampusLap.pointCount && route.count == CampusLap.pointCount
    }

    private var shownSpeed: Double {
        if campusRunning { return liveSpeed }
        if gliding || playingRoute || stickBearing != nil { return speedKmh }
        return 0
    }

    private var campusPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("校园乐跑")
            Text("哈工大一校区操场")
                .font(.custom("Iowan Old Style", size: 22))
                .foregroundStyle(Ink.ink)
            Text("绕操场一圈，平均大约 4 分钟 1 公里。弯道稍慢，直道稍快，位置和速度都有轻微起伏。")
                .font(.custom("Avenir Next", size: 12))
                .foregroundStyle(Ink.muted)
                .fixedSize(horizontal: false, vertical: true)
            Text(String(format: "一圈 %.0f 米 · %d 个点", CampusLap.length, CampusLap.pointCount))
                .font(.custom("Menlo", size: 11))
            Text(String(format: "弯道 %.1f km/h · 直道 %.1f km/h", CampusLap.slowest, CampusLap.fastest))
                .font(.custom("Menlo", size: 11))
                .foregroundStyle(Ink.muted)
            Text(pin.map { Geo.format(Geo.toGPS($0)) } ?? "操场北侧起点")
                .font(.custom("Menlo", size: 12))
            Text(String(format: "第 %d 圈 · %.1f km/h · %@", campusLaps + 1, liveSpeed, pace(liveSpeed)))
                .font(.custom("Menlo", size: 11))
                .foregroundStyle(Ink.muted)
            HStack(spacing: 8) {
                Button(campusRunning ? "暂停" : "开始乐跑") { toggleCampus() }
                    .buttonStyle(PrimaryButton())
                    .disabled(selectedID == nil || bridge.busy)
                Button("回到起点") { resetCampusProgress() }
                    .buttonStyle(QuietButton())
            }
            Button("导出 GPX") { exportGPX() }
                .buttonStyle(QuietButton())
                .disabled(route.count < 2)
        }
        .onAppear {
            if campusSpeeds.count != CampusLap.pointCount {
                presentCampusLap(reset: true)
            } else {
                fitToken += 1
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.custom("Avenir Next", size: 11).weight(.semibold))
            .tracking(1.2)
            .foregroundStyle(Ink.muted)
    }

    private func handleTap(_ coordinate: CLLocationCoordinate2D) {
        if pane == .campus || campusRunning { return }
        if mode == .route {
            route.append(coordinate)
            pin = coordinate
            return
        }
        pin = coordinate
        if mode == .pin && writeOnTap {
            Task { await commitPin() }
        }
    }

    private func step(bearing: Double) {
        guard let origin = pin else { return }
        let meters = speedKmh * 1000 / 3600 * 0.4
        let next = Geo.project(origin, bearingDeg: bearing, meters: meters)
        pin = next
        settled = next
        course = bearing
        guard let selectedID else { return }
        let fix = reported(next)
        Task { await commit(fix, target: selectedID, record: false, moving: true, bearing: bearing, quiet: false) }
    }

    private func advanceRoute() {
        guard route.count >= 2, let selectedID, var current = pin ?? route.first else {
            playingRoute = false
            return
        }
        var budget = speedKmh * 1000 / 3600
        while budget > 0 && routeCursor < route.count - 1 {
            let end = route[routeCursor + 1]
            let span = Geo.distance(current, end)
            if span <= 1 {
                routeCursor += 1
                current = end
                continue
            }
            if budget < span {
                current = Geo.project(current, bearingDeg: Geo.bearing(current, end), meters: budget)
                budget = 0
            } else {
                budget -= span
                routeCursor += 1
                current = end
            }
        }
        pin = current
        settled = current
        let travel = routeCursor < route.count - 1 ? Geo.bearing(current, route[routeCursor + 1]) : course
        course = travel
        let finished = routeCursor >= route.count - 1
        if finished { playingRoute = false }
        let fix = onCampusLap ? current : reported(current)
        Task {
            await commit(
                fix,
                target: selectedID,
                record: finished,
                moving: !finished,
                bearing: travel,
                quiet: false
            )
        }
    }

    private func advanceGlide() {
        guard gliding, let glideTarget, var current = glideCursor ?? settled, let selectedID else {
            gliding = false
            return
        }
        let step = speedKmh * 1000 / 3600
        let span = Geo.distance(current, glideTarget)
        let bearing = Geo.bearing(current, glideTarget)
        course = bearing
        if span <= max(step, 1) {
            gliding = false
            pin = glideTarget
            settled = glideTarget
            self.glideCursor = nil
            self.glideTarget = nil
            let fix = reported(glideTarget)
            Task { await commit(fix, target: selectedID, record: true, moving: false, bearing: bearing, quiet: false) }
            return
        }
        current = Geo.project(current, bearingDeg: bearing, meters: step)
        glideCursor = current
        pin = current
        settled = current
        let fix = reported(current)
        Task { await commit(fix, target: selectedID, record: false, moving: true, bearing: bearing, quiet: false) }
    }

    private func commitPin() async {
        guard let destination = pin, let selectedID else { return }
        if disguise && glide, let from = settled, Geo.distance(from, destination) > 80 {
            gliding = true
            glideCursor = from
            glideTarget = destination
            pin = from
            return
        }
        settled = destination
        await commit(reported(destination), target: selectedID, record: true, moving: false, bearing: course, quiet: false)
    }

    private func reported(_ origin: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard disguise, jitter else { return origin }
        noiseNorth += Double.random(in: -0.4...0.4)
        noiseEast += Double.random(in: -0.4...0.4)
        let magnitude = hypot(noiseNorth, noiseEast)
        let cap = accuracyM * 0.45
        if magnitude > cap, magnitude > 0 {
            noiseNorth *= cap / magnitude
            noiseEast *= cap / magnitude
        }
        let north = Geo.project(origin, bearingDeg: 0, meters: noiseNorth)
        return Geo.project(north, bearingDeg: 90, meters: noiseEast)
    }

    private func advanceCampus() {
        guard onCampusLap, let selectedID else {
            campusRunning = false
            return
        }
        var current = campusOnRoute ?? route[min(routeCursor, route.count - 1)]
        let now = Date()
        var timeLeft = min(max(now.timeIntervalSince(campusStamp), 0), 2.5)
        campusStamp = now
        laneOffset = CampusLap.stepLane(laneOffset)
        speedJitter = CampusLap.stepSpeed(speedJitter)
        var hops = 0
        while timeLeft > 0.0001, hops < route.count * 4 {
            hops += 1
            let nextIndex = (routeCursor + 1) % route.count
            let end = route[nextIndex]
            let span = Geo.distance(current, end)
            let metersPerSecond = max(2.5, (campusSpeeds[routeCursor] + speedJitter) / 3.6)
            if span < 0.4 {
                if nextIndex == 0 { campusLaps += 1 }
                routeCursor = nextIndex
                current = end
                continue
            }
            let need = span / metersPerSecond
            if need > timeLeft {
                current = Geo.lerp(current, end, (metersPerSecond * timeLeft) / span)
                timeLeft = 0
            } else {
                timeLeft -= need
                if nextIndex == 0 { campusLaps += 1 }
                routeCursor = nextIndex
                current = end
            }
        }
        campusOnRoute = current
        let bearing = campusBearing(from: current)
        course = bearing
        liveSpeed = max(10, campusSpeeds[routeCursor] + speedJitter)
        let shaken = Geo.project(current, bearingDeg: bearing + 90, meters: laneOffset)
        pin = shaken
        settled = shaken
        Task {
            await commit(
                shaken,
                target: selectedID,
                record: false,
                moving: true,
                bearing: bearing,
                quiet: true,
                speedOverride: liveSpeed
            )
        }
    }

    private func presentCampusLap(reset: Bool) {
        let lap = CampusLap.points
        route = lap.map(\.coordinate)
        campusSpeeds = lap.map(\.speedKmh)
        if reset || pin == nil {
            routeCursor = 0
            campusLaps = 0
            laneOffset = 0
            speedJitter = 0
            campusOnRoute = route.first
            pin = route.first
            settled = route.first
            liveSpeed = lap.first?.speedKmh ?? 0
            if route.count >= 2 {
                course = Geo.bearing(route[0], route[1])
            }
        }
        fitToken += 1
    }

    private func toggleCampus() {
        if campusSpeeds.count != CampusLap.pointCount {
            presentCampusLap(reset: true)
        }
        playingRoute = false
        gliding = false
        stickBearing = nil
        if campusRunning {
            campusRunning = false
            return
        }
        campusRunning = true
        campusStamp = Date()
        guard let selectedID, let current = pin ?? route.first else { return }
        let bearing = campusBearing(from: current)
        course = bearing
        liveSpeed = campusSpeeds[min(routeCursor, max(campusSpeeds.count - 1, 0))]
        Task {
            await commit(
                current,
                target: selectedID,
                record: false,
                moving: true,
                bearing: bearing,
                quiet: false,
                speedOverride: liveSpeed
            )
        }
    }

    private func resetCampusProgress() {
        guard onCampusLap else {
            presentCampusLap(reset: true)
            return
        }
        routeCursor = 0
        campusLaps = 0
        laneOffset = 0
        speedJitter = 0
        campusOnRoute = route.first
        pin = route.first
        settled = route.first
        liveSpeed = campusSpeeds.first ?? 0
        campusStamp = Date()
        if route.count >= 2 {
            course = Geo.bearing(route[0], route[1])
        }
        guard campusRunning, let selectedID, let pin else { return }
        Task {
            await commit(
                pin,
                target: selectedID,
                record: false,
                moving: true,
                bearing: course,
                quiet: false,
                speedOverride: liveSpeed
            )
        }
    }

    private func campusBearing(from current: CLLocationCoordinate2D) -> Double {
        guard route.count >= 2 else { return course }
        let next = route[(routeCursor + 1) % route.count]
        if Geo.distance(current, next) < 0.5 {
            return Geo.bearing(current, route[(routeCursor + 2) % route.count])
        }
        return Geo.bearing(current, next)
    }

    private func pace(_ kmh: Double) -> String {
        guard kmh > 0.1 else { return "—'/km" }
        let seconds = Int((3600 / kmh).rounded())
        return String(format: "%d'%02d\"/km", seconds / 60, seconds % 60)
    }

    private func commit(
        _ coordinate: CLLocationCoordinate2D,
        target: String,
        record: Bool,
        moving: Bool,
        bearing: Double,
        quiet: Bool,
        speedOverride: Double? = nil
    ) async {
        let speed: Double
        if let speedOverride {
            speed = speedOverride / 3.6
        } else if moving {
            speed = speedKmh / 3.6
        } else {
            speed = disguise && jitter ? 0.3 : 0
        }
        let ok = await bridge.apply(
            target: target,
            coordinate: Geo.toGPS(coordinate),
            accuracy: disguise ? accuracyM : 5,
            speed: speed,
            bearing: bearing,
            altitude: 28 + accuracyM * 0.15,
            quiet: quiet
        )
        guard ok, record else { return }
        let item = SavedPin(
            id: UUID(),
            name: Geo.format(Geo.toGPS(coordinate)),
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            savedAt: Date()
        )
        store.history.insert(item, at: 0)
        if store.history.count > 30 { store.history.removeLast(store.history.count - 30) }
        StoreFile.save(store)
    }

    private func stopSimulation() async {
        playingRoute = false
        campusRunning = false
        stickBearing = nil
        gliding = false
        glideCursor = nil
        glideTarget = nil
        guard let selectedID else { return }
        await bridge.clear(target: selectedID)
    }

    private func savePin() {
        guard let pin else { return }
        let name = favoriteName.trimmingCharacters(in: .whitespacesAndNewlines)
        store.favorites.insert(
            SavedPin(
                id: UUID(),
                name: name.isEmpty ? Geo.format(Geo.toGPS(pin)) : name,
                latitude: pin.latitude,
                longitude: pin.longitude,
                savedAt: Date()
            ),
            at: 0
        )
        favoriteName = ""
        StoreFile.save(store)
    }

    private func saveRoute() {
        let points = route.enumerated().map { index, coordinate in
            SavedPin(id: UUID(), name: "\(index + 1)", latitude: coordinate.latitude, longitude: coordinate.longitude, savedAt: Date())
        }
        let name = favoriteName.trimmingCharacters(in: .whitespacesAndNewlines)
        store.routes.insert(SavedRoute(id: UUID(), name: name.isEmpty ? "路线 \(store.routes.count + 1)" : name, points: points), at: 0)
        favoriteName = ""
        StoreFile.save(store)
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        let response = try? await MKLocalSearch(request: request).start()
        guard let item = response?.mapItems.first else {
            bridge.lastError = "没有找到这个地点"
            return
        }
        pin = item.placemark.coordinate
        focusToken += 1
        bridge.lastError = nil
    }

    private func importGPX() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.xml]
        panel.allowsOtherFileTypes = true
        panel.message = "选择 GPX 路线"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            campusRunning = false
            campusSpeeds = []
            route = try GPXFile.read(url: url)
            pin = route.first
            mode = .route
            focusToken += 1
        } catch {
            bridge.lastError = "这个 GPX 里没有坐标"
        }
    }

    private func exportGPX() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.xml]
        panel.nameFieldStringValue = "route.gpx"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let points = onCampusLap && !route.isEmpty ? route + [route[0]] : route
            try GPXFile.write(points, to: url)
        } catch {
            bridge.lastError = error.localizedDescription
        }
    }
}

struct CompassRose: View {
    var onBearing: (Double?) -> Void

    var body: some View {
        VStack(spacing: 4) {
            hold("北", 0)
            HStack(spacing: 4) {
                hold("西", 270)
                Circle().fill(Ink.copper).frame(width: 8, height: 8).frame(width: 44, height: 44)
                hold("东", 90)
            }
            hold("南", 180)
        }
        .padding(10)
        .background(Ink.sheet.opacity(0.94))
        .overlay(Rectangle().stroke(Ink.ink.opacity(0.2), lineWidth: 1))
    }

    private func hold(_ title: String, _ bearing: Double) -> some View {
        Text(title)
            .font(.custom("Avenir Next", size: 12).weight(.medium))
            .frame(width: 44, height: 36)
            .background(Ink.paper)
            .overlay(Rectangle().stroke(Ink.line, lineWidth: 1))
            .onLongPressGesture(minimumDuration: 0.05, maximumDistance: 30, pressing: { pressing in
                onBearing(pressing ? bearing : nil)
            }, perform: {})
    }
}

struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryLabel(configuration: configuration)
    }

    private struct PrimaryLabel: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.custom("Avenir Next", size: 13).weight(.semibold))
                .foregroundStyle(isEnabled ? Ink.sheet : Ink.muted)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(isEnabled ? (configuration.isPressed ? Ink.ink.opacity(0.8) : Ink.ink) : Ink.line)
        }
    }
}

struct QuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuietLabel(configuration: configuration)
    }

    private struct QuietLabel: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.custom("Avenir Next", size: 12).weight(.medium))
                .foregroundStyle(isEnabled ? Ink.ink : Ink.muted)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(configuration.isPressed && isEnabled ? Ink.paper : Color.clear)
                .overlay(Rectangle().stroke(isEnabled ? Ink.line : Ink.line.opacity(0.4), lineWidth: 1))
        }
    }
}

struct PaneTab: ButtonStyle {
    var active: Bool

    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 6) {
            configuration.label
                .font(.custom("Avenir Next", size: 13).weight(active ? .semibold : .medium))
                .foregroundStyle(active ? Ink.ink : Ink.muted)
            Rectangle()
                .fill(active ? Ink.copper : Color.clear)
                .frame(height: 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .background(configuration.isPressed ? Ink.paper.opacity(0.6) : Color.clear)
    }
}

struct ModeButton: ButtonStyle {
    var active: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.custom("Avenir Next", size: 13).weight(.medium))
            .foregroundStyle(active ? Ink.sheet : Ink.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(active ? Ink.ink : (configuration.isPressed ? Ink.paper : Color.clear))
            .overlay(Rectangle().stroke(Ink.ink.opacity(0.35), lineWidth: 1))
    }
}

enum StoreFile {
    static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Locus", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("store.json")
    }

    static func load() -> DeskStore {
        guard let data = try? Data(contentsOf: url) else { return DeskStore() }
        return (try? JSONDecoder().decode(DeskStore.self, from: data)) ?? DeskStore()
    }

    static func save(_ store: DeskStore) {
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? data.write(to: url)
    }
}
