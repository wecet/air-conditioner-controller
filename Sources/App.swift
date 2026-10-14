import SwiftUI
import AppKit

enum OperatingMode: String, CaseIterable { case preview = "Preview", production = "Production" }

final class Controller: ObservableObject {
    @Published private(set) var mode: OperatingMode = .preview
    @Published var state: [String: Int] = [:]
    @Published var devices: [Device] = []
    @Published var selected: Device?
    @Published var busy = false
    @Published var connected = false
    @Published var message = ""
    @Published var address = UserDefaults.standard.string(forKey: "discoveryAddress") ?? "255.255.255.255"
    @Published private(set) var offTimer = OffTimer()
    @Published private(set) var countdownNow = Date()
    @Published private(set) var timerNotice = ""
    private var countdownTicker: Timer?
    private let client = GreeClient()
    private let queue = DispatchQueue(label: "gree.network")
    private var timer: Timer?
    init() {
        let production = CommandLine.arguments.contains("--production")
        changeMode(production ? .production : .preview)
        let ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tickOffTimer() }
        countdownTicker = ticker
        RunLoop.main.add(ticker, forMode: .common)
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func changeMode(_ next: OperatingMode) {
        guard !busy else { return }
        cancelOffTimer()
        mode = next; selected = nil; devices = []; connected = false
        // All client access stays serialized with network operations.
        queue.async { self.client.clearSession() }
        if next == .preview {
            state = ["Pow": 1, "Mod": 1, "SetTem": 24, "WdSpd": 1, "SwhSlp": 0, "SwUpDn": 1, "SvSt": 0, "TemSen": 65, "TemUn": 0]
            message = "Preview · simulated AC · no network requests"
        } else {
            state = [:]
            message = "Connect a compatible AC to the same network, then Find AC."
        }
    }
    var canControl: Bool { !busy && (mode == .preview || connected) }
    func scan() {
        guard mode == .production, !busy else { return }
        cancelOffTimer()
        busy = true; connected = false; selected = nil; state = [:]; devices = []
        message = "Looking for a compatible AC…"
        let host = address.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(host, forKey: "discoveryAddress")
        queue.async {
            do {
                let found = try self.client.discover(host: host)
                DispatchQueue.main.async {
                    self.devices = found; self.busy = false
                    if let first = found.first { self.select(first) }
                    else { self.message = "No AC found. Check Wi-Fi setup or enter its IPv4 address." }
                }
            } catch { self.fail(error) }
        }
    }
    func select(_ device: Device) {
        guard mode == .production, !busy else { return }
        cancelOffTimer()
        selected = device; state = [:]; connected = false
        refresh()
    }
    func refresh() {
        guard mode == .production, !busy, let device = selected else { return }
        busy = true
        queue.async {
            do { let status = try self.client.status(device); self.apply(status, device: device) }
            catch { self.fail(error) }
        }
    }
    func set(_ values: [String: Int]) {
        guard canControl else { return }
        if values["Pow"] == 0 { cancelOffTimer() }
        if mode == .preview { state.merge(values) { _, new in new }; return }
        guard let device = selected else { return }
        busy = true
        message = "Sending command…"
        queue.async {
            do {
                try self.client.command(device, values: values)
                let status = try self.client.status(device)
                self.apply(status, device: device)
            } catch { self.fail(error) }
        }
    }
    func startOffTimer(amount: Int, hours: Bool) {
        guard canControl, state["Pow"] == 1, (1...1440).contains(amount) else { return }
        let seconds = Double(amount) * (hours ? 3600 : 60)
        guard seconds <= 86400 else { return }
        offTimer.start(seconds: seconds)
        countdownNow = Date()
        timerNotice = ""
    }
    func cancelOffTimer() {
        offTimer.cancel()
        timerNotice = ""
    }
    private func tickOffTimer() {
        countdownNow = Date()
        guard offTimer.isDue(at: countdownNow), !busy else { return }
        offTimer.cancel()
        if mode == .preview {
            state["Pow"] = 0
            timerNotice = "Timer finished · preview AC switched off"
            return
        }
        guard let device = selected else {
            timerNotice = "Timer failed · no AC selected"
            return
        }
        busy = true
        timerNotice = "Timer finished · switching AC off…"
        queue.async {
            do {
                try self.client.command(device, values: ["Pow": 0])
                let status = try self.client.status(device)
                DispatchQueue.main.async {
                    self.state = status; self.connected = true; self.busy = false
                    self.timerNotice = status["Pow"] == 0 ? "Timer finished · AC confirmed off" : "Timer failed · AC still reports on"
                }
            } catch {
                DispatchQueue.main.async {
                    self.busy = false; self.connected = false
                    self.timerNotice = "Timer failed · off was not confirmed. " + error.localizedDescription
                }
            }
        }
    }
    private func apply(_ status: [String: Int], device: Device) {
        DispatchQueue.main.async { self.state = status; if status["Pow"] == 0 { self.offTimer.cancel() }; self.connected = true; self.busy = false; self.message = "Connected · \(device.host)" }
    }
    private func fail(_ error: Error) {
        DispatchQueue.main.async { self.busy = false; self.connected = false; self.message = error.localizedDescription }
    }
    func toggle(_ key: String) -> Binding<Bool> {
        Binding(get: { self.state[key] == 1 }, set: { self.set([key: $0 ? 1 : 0]) })
    }
}

@main
struct GreeBar: App {
    @StateObject private var controller = Controller()
    var body: some Scene {
        MenuBarExtra {
            Panel(model: controller)
        } label: {
            Image(systemName: "air.conditioner.horizontal")
            if controller.mode == .preview { Text("Demo") }
            else if controller.connected, let temperature = controller.state["SetTem"] { Text("\(temperature)°") }
        }.menuBarExtraStyle(.window)
    }
}

struct Panel: View {
    @ObservedObject var model: Controller
    @State private var temperature = 24.0
    @State private var timerAmount = 30
    @State private var timerHours = false
    private let blue = Color(red: 0.3, green: 0.65, blue: 1)
    var body: some View {
        VStack(spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("GREE · CLIMATE").font(.system(size: 11, weight: .semibold)).tracking(2).foregroundStyle(.white.opacity(0.5))
                    Label(roomLabel, systemImage: "thermometer.medium").font(.system(size: 13))
                }
                Spacer()
                Button { model.set(["Pow": model.state["Pow"] == 1 ? 0 : 1]) } label: {
                    Image(systemName: "power").font(.system(size: 22)).frame(width: 44, height: 44)
                        .background(model.state["Pow"] == 1 ? blue : Color.white.opacity(0.08), in: Circle())
                }.buttonStyle(.plain).disabled(!model.canControl).accessibilityLabel("Toggle AC power")
            }
            Picker("Operating mode", selection: Binding(get: { model.mode }, set: { model.changeMode($0) })) {
                ForEach(OperatingMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).disabled(model.busy)
            illustration.frame(height: 100)
            HStack(alignment: .firstTextBaseline) {
                Text(model.state["SetTem"].map(String.init) ?? "—").font(.system(size: 60, weight: .light, design: .rounded))
                Text("°C").font(.system(size: 18)).foregroundStyle(blue)
                Spacer()
                Toggle("Eco", isOn: model.toggle("SvSt")).toggleStyle(.switch).font(.system(size: 12)).fixedSize().disabled(!available("SvSt"))
            }
            HStack(spacing: 12) {
                temperatureButton("minus", delta: -1)
                Slider(value: $temperature, in: 16...30, step: 1) { editing in
                    if !editing { model.set(["SetTem": Int(temperature), "TemUn": 0]) }
                }.tint(blue).disabled(!available("SetTem"))
                temperatureButton("plus", delta: 1)
            }
            HStack(spacing: 8) {
                control("Mode", icon: "snowflake", key: "Mod", choices: [(0,"Auto"),(1,"Cool"),(2,"Dry"),(3,"Fan"),(4,"Heat")])
                control("Fan", icon: "fan", key: "WdSpd", choices: [(0,"Auto"),(1,"Low"),(2,"Med-low"),(3,"Medium"),(4,"Med-high"),(5,"High")])
                control("Sleep", icon: "moon", key: "SwhSlp", choices: [(0,"Off"),(1,"On")])
                control("Swing", icon: "wind", key: "SwUpDn", choices: [(0,"Default"),(1,"Swing"),(2,"Top"),(3,"Upper"),(4,"Middle"),(5,"Lower"),(6,"Bottom")])
            }
            offTimerPanel
            Text(model.message).font(.system(size: 11)).foregroundStyle(model.mode == .preview || model.connected ? Color.white.opacity(0.6) : Color.orange).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            if model.mode == .production {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("AC IPv4 / broadcast address", text: $model.address).textFieldStyle(.roundedBorder).disabled(model.busy)
                    if model.devices.count > 1 {
                        Picker("Device", selection: Binding(get: { model.selected?.mac ?? "" }, set: { mac in
                            if let device = model.devices.first(where: { $0.mac == mac }) { model.select(device) }
                        })) { ForEach(model.devices) { Text("\($0.name) · \($0.host)").tag($0.mac) } }.disabled(model.busy)
                    }
                    HStack {
                        Button(model.busy ? "Working…" : "Find AC") { model.scan() }
                        Spacer()
                        Button("Refresh") { model.refresh() }.disabled(model.selected == nil)
                    }.disabled(model.busy)
                    Text("Requires a Wi-Fi-equipped Gree AC on this network with AES v1 local control. Pair it in Gree+ / EWPE Smart first. Features vary by model.").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
                }.padding(12).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            }
            HStack {
                Text(model.mode == .preview ? "PREVIEW" : "PRODUCTION").font(.system(size: 9, weight: .bold)).tracking(1.5).foregroundStyle(blue)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }.font(.system(size: 11)).buttonStyle(.plain)
            }
        }.padding(22).frame(width: 380)
            .foregroundStyle(.white).preferredColorScheme(.dark)
            .background(LinearGradient(colors: [Color(red: 0.1, green: 0.20, blue: 0.36), Color(red: 0.035, green: 0.055, blue: 0.10)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .onChange(of: model.state["SetTem"]) { _, value in temperature = Double(value ?? 24) }
    }
    private var offTimerPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Off timer", systemImage: "timer").font(.system(size: 12, weight: .semibold))
                Spacer()
                if let countdown = model.offTimer.countdown(at: model.countdownNow) {
                    Text(countdown).monospacedDigit().font(.system(size: 16, weight: .medium)).foregroundStyle(blue)
                    Button("Cancel") { model.cancelOffTimer() }.font(.system(size: 11))
                }
            }
            if model.offTimer.deadline == nil {
                HStack(spacing: 8) {
                    Text("Off after").font(.system(size: 11))
                    TextField("Amount", value: $timerAmount, format: .number).frame(width: 48).textFieldStyle(.roundedBorder)
                    Picker("Unit", selection: $timerHours) {
                        Text("minutes").tag(false)
                        Text("hours").tag(true)
                    }.labelsHidden().frame(width: 100)
                    Spacer(minLength: 0)
                    Button("Start") { model.startOffTimer(amount: timerAmount, hours: timerHours) }
                        .disabled(!model.canControl || model.state["Pow"] != 1 || timerAmount < 1 || timerAmount > (timerHours ? 24 : 1440))
                }
            }
            if !model.timerNotice.isEmpty {
                Text(model.timerNotice).font(.system(size: 10)).foregroundStyle(model.timerNotice.hasPrefix("Timer failed") ? Color.orange : blue)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.mode == .production {
                Text("App timer · keep this Mac awake and GreeBar running.").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            }
        }.padding(12).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
    private var roomLabel: String {
        if let sensor = model.state["TemSen"], (40...100).contains(sensor) { return "Room \(sensor - 40)°C" }
        return model.busy ? "Connecting…" : "Not connected"
    }
    private func available(_ key: String) -> Bool { model.canControl && model.state[key] != nil }
    private var animationProfile: AnimationProfile {
        AnimationProfile(mode: model.state["Mod"] ?? 0, fan: model.state["WdSpd"] ?? 0,
                         swing: model.state["SwUpDn"] ?? 0, sleep: model.state["SwhSlp"] == 1)
    }
    private var climateColor: Color {
        switch animationProfile.mode {
        case 1: return blue
        case 2: return .mint
        case 3: return Color(red: 0.75, green: 0.87, blue: 0.98)
        case 4: return Color(red: 1, green: 0.30, blue: 0.22)
        default: return .purple
        }
    }
    private var illustration: some View {
        ZStack {
            Ellipse().fill(climateColor.opacity(model.state["Pow"] == 1 ? (animationProfile.sleep ? 0.08 : 0.2) : 0.02)).frame(width: 190, height: 55).blur(radius: 20).offset(y: 15)
            AirflowAnimation(active: model.state["Pow"] == 1 && (model.mode == .preview || model.connected),
                             profile: animationProfile, color: climateColor)
            VStack(spacing: 12) {
                HStack { Spacer(); Text(model.state["SetTem"].map { "\($0)°" } ?? "—").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(climateColor) }
                RoundedRectangle(cornerRadius: 3).fill(.black.opacity(0.5)).frame(height: 5)
            }.padding(10).frame(width: 155).background(LinearGradient(colors: [.white, Color(white: 0.7)], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 12)).shadow(radius: 8, y: 8).offset(y: -15)
        }
    }
    private func temperatureButton(_ icon: String, delta: Int) -> some View {
        Button { model.set(["SetTem": max(16, min(30, (model.state["SetTem"] ?? 24) + delta)), "TemUn": 0]) } label: {
            Image(systemName: icon).frame(width: 30, height: 30).background(.white.opacity(0.06), in: Circle())
        }.buttonStyle(.plain).disabled(!available("SetTem"))
    }
    private func control(_ title: String, icon: String, key: String, choices: [(Int, String)]) -> some View {
        SettingControl(title: title, icon: icon, choices: choices, value: model.state[key],
                       enabled: available(key), color: blue) { model.set([key: $0]) }
    }
}

struct SettingControl: View {
    let title: String
    let icon: String
    let choices: [(Int, String)]
    let value: Int?
    let enabled: Bool
    let color: Color
    let select: (Int) -> Void
    @State private var expanded = false
    @State private var hoveredOption: Int?

    var body: some View {
        Button { expanded.toggle() } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: icon).font(.system(size: 20)).foregroundStyle(color)
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
                }
                Text(title).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
                Text(currentSetting).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.8)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                .background(color.opacity(value == nil ? 0.03 : 0.10), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(value == nil ? 0.08 : 0.25), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).disabled(!enabled)
            .accessibilityLabel(title).accessibilityValue(currentSetting)
            .popover(isPresented: $expanded) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).padding(.horizontal, 8).padding(.bottom, 5)
                    ForEach(choices, id: \.0) { option, label in
                        Button {
                            select(option)
                            expanded = false
                        } label: {
                            HStack {
                                Text(label)
                                Spacer()
                                Image(systemName: "checkmark").opacity(value == option ? 1 : 0)
                            }.padding(8).frame(width: 150)
                                .background(color.opacity(hoveredOption == option ? 0.25 : (value == option ? 0.15 : 0)), in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .onHover { hovering in
                                if hovering { hoveredOption = option }
                                else if hoveredOption == option { hoveredOption = nil }
                            }
                    }
                }.padding(10)
                    .onDisappear { hoveredOption = nil }.preferredColorScheme(.dark)
            }
    }
    private var currentSetting: String {
        guard let value else { return "—" }
        return choices.first { $0.0 == value }?.1 ?? "Other"
    }
}

struct AirflowAnimation: View {
    let active: Bool
    let profile: AnimationProfile
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active || reduceMotion)) { timeline in
            Canvas { context, size in
                guard active else { return }
                let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                drawMode(context: &context, size: size, time: time)
                drawFan(context: &context, size: size, time: time)
                drawSwing(context: &context, size: size, time: time)
                drawSleep(context: &context, size: size, time: time)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }

    // Mode: tinted air with its own particle shape and motion.
    private func drawMode(context: inout GraphicsContext, size: CGSize, time: Double) {
        let pulse = reduceMotion ? 0.7 : 0.65 + sin(time * 1.8) * 0.2
        var iconContext = context
        iconContext.opacity = pulse * (profile.sleep ? 0.45 : 1)
        iconContext.translateBy(x: size.width / 2 - 104, y: 26)
        if profile.mode == 3 && !reduceMotion { iconContext.rotate(by: .radians(time * 2)) }
        iconContext.draw(Image(systemName: profile.modeSymbol).resizable(), in: CGRect(x: -9, y: -9, width: 18, height: 18))
        for index in 0..<4 {
            let phase = reduceMotion ? 0.45 : (time / 3 + Double(index) / 4).truncatingRemainder(dividingBy: 1)
            let x = size.width / 2 + CGFloat(index - 2) * 26 + CGFloat(profile.angle(at: time) * phase * 50)
            let y = 50 + CGFloat(phase) * 42
            var particle = Path()
            switch profile.mode {
            case 1: // Small crystalline sparks.
                particle.move(to: CGPoint(x: x - 3, y: y)); particle.addLine(to: CGPoint(x: x + 3, y: y))
                particle.move(to: CGPoint(x: x, y: y - 3)); particle.addLine(to: CGPoint(x: x, y: y + 3))
            case 2: // Falling moisture droplets.
                particle.addEllipse(in: CGRect(x: x, y: y, width: 2.5, height: 5))
            case 4: // Warm ripples.
                particle.move(to: CGPoint(x: x - 4, y: y))
                particle.addQuadCurve(to: CGPoint(x: x + 4, y: y + 4), control: CGPoint(x: x + 2, y: y - 4))
            case 3: continue // Fan mode keeps the air clean, with the rotating fan badge.
            default: // Auto has floating circular motes.
                particle.addEllipse(in: CGRect(x: x, y: y, width: 3, height: 3))
            }
            context.stroke(particle, with: .color(color.opacity(sin(phase * .pi) * profile.opacity)), lineWidth: 1)
        }
    }

    // Fan: flow speed, density, and stroke weight vary at every level.
    private func drawFan(context: inout GraphicsContext, size: CGSize, time: Double) {
        let automatic = profile.fan == 0 && !reduceMotion ? sin(time * 0.6) * 0.15 : 0
        let flowTime = time / profile.fanDuration + automatic
        let angle = profile.angle(at: time)
        for lane in 0..<7 {
            let spread = CGFloat(lane - 3)
            for pulse in 0..<profile.pulses {
                let phase = reduceMotion ? 0.4 : (flowTime + Double(pulse) / Double(profile.pulses) + Double(lane) * 0.07).truncatingRemainder(dividingBy: 1)
                let progress = CGFloat(phase)
                let x = size.width / 2 + spread * 15 + CGFloat(angle) * progress * 55
                let y: CGFloat = 46 + progress * 44
                var path = Path()
                path.move(to: CGPoint(x: x, y: y))
                path.addQuadCurve(to: CGPoint(x: x + spread * 1.2 + CGFloat(angle) * 10, y: y + 10),
                                  control: CGPoint(x: x + 2, y: y + 5))
                context.stroke(path, with: .color(color.opacity(sin(phase * .pi) * profile.opacity)),
                               style: StrokeStyle(lineWidth: 1 + Double(profile.fan) * 0.12, lineCap: .round))
            }
        }
    }

    // Swing: a visible blade pivots and also steers the combined airflow.
    private func drawSwing(context: inout GraphicsContext, size: CGSize, time: Double) {
        var blade = context
        blade.translateBy(x: size.width / 2, y: 47)
        blade.rotate(by: .radians(profile.angle(at: time) * 0.35))
        var path = Path()
        path.move(to: CGPoint(x: -52, y: 0)); path.addLine(to: CGPoint(x: 52, y: 0))
        blade.stroke(path, with: .color(color.opacity(profile.sleep ? 0.35 : 0.7)),
                     style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }

    // Sleep: independent slow breathing moon/stars plus softer light and airflow.
    private func drawSleep(context: inout GraphicsContext, size: CGSize, time: Double) {
        guard profile.sleep else { return }
        var night = context
        night.opacity = reduceMotion ? 0.65 : 0.6 + sin(time * 0.7) * 0.2
        night.draw(Image(systemName: "moon.stars.fill"), in: CGRect(x: size.width / 2 + 91, y: 16, width: 21, height: 21))
    }
}
