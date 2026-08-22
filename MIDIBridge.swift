import CoreMIDI
import Foundation

/// Publishes the current track's key and tempo as MIDI on a virtual source
/// named "Spot-a-oke".
///
/// Plugins have no external API, and the AU/VST host protocol has no concept of
/// musical key — but any automatable plugin parameter can be MIDI-learned in
/// Logic's Controller Assignments. A control change per track change is therefore
/// the one channel that reaches something like Topline Vocal Suite's key setting.
@MainActor
final class MIDIBridge {

    static let shared = MIDIBridge()

    /// Learn these in Logic: Controller Assignments → Learn Mode, touch the
    /// plugin parameter, then let the app send on the next track change.
    static let keyCC: UInt8 = 20      // root note, C…B
    static let modeCC: UInt8 = 21     // 0 = major, 127 = minor
    static let tempoCC: UInt8 = 22    // see logicTempo* below

    /// Logic's Tempo parameter spans 5–990 BPM, and a controller assignment maps
    /// the whole CC range onto it. The Value Minimum/Maximum fields that would
    /// narrow that are greyed out for Global > Tempo, so the encoding has to
    /// match Logic's range rather than a nominal musical one — otherwise 130 BPM
    /// arrives as 501.
    static let logicTempoMin = 5.0
    static let logicTempoMax = 990.0

    static func tempoCCValue(for bpm: Double) -> UInt8 {
        let span = logicTempoMax - logicTempoMin
        let scaled = ((bpm - logicTempoMin) / span * 127).rounded()
        return UInt8(min(127, max(0, scaled)))
    }

    /// Fixed identity for the virtual endpoint ("SPOK" as ASCII).
    ///
    /// CoreMIDI assigns a random unique ID to a virtual source unless told
    /// otherwise, and hosts key their controller assignments off that ID — so
    /// every rebuild looks like a different MIDI interface and Logic drops the
    /// mappings. Pinning it keeps the device identical across rebuilds.
    private static let endpointID: Int32 = 0x53504F4B

    static let enabledKey = "midiBridgeEnabled"
    static let clockKey = "midiClockEnabled"

    private var client = MIDIClientRef()
    private var source = MIDIEndpointRef()
    private var ready = false
    private var clockTimer: DispatchSourceTimer?

    private var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }
    private var clockEnabled: Bool { UserDefaults.standard.bool(forKey: Self.clockKey) }

    func start() {
        guard !ready else { return }
        guard MIDIClientCreate("Spot-a-oke" as CFString, nil, nil, &client) == noErr,
              MIDISourceCreate(client, "Spot-a-oke" as CFString, &source) == noErr else { return }

        // Claim a stable identity. kMIDIIDNotUnique means a previous instance is
        // still holding it, which is harmless — the endpoint still works, it just
        // keeps the ID CoreMIDI picked.
        MIDIObjectSetIntegerProperty(source, kMIDIPropertyUniqueID, Self.endpointID)
        MIDIObjectSetStringProperty(source, kMIDIPropertyManufacturer, "Spot-a-oke" as CFString)
        MIDIObjectSetStringProperty(source, kMIDIPropertyModel, "Spot-a-oke" as CFString)

        ready = true
    }

    /// Called on every track change once key and tempo are known.
    func publish(_ analysis: TrackAnalysis?) {
        guard ready, isEnabled else { return }

        if let key = analysis?.key, let coded = Self.encode(key: key) {
            // Spread 12 roots across 0–127 so each lands on a distinct step of a
            // 12-position parameter once Logic scales the CC to its range.
            send(cc: Self.keyCC, value: UInt8((Double(coded.root) * 127.0 / 11.0).rounded()))
            send(cc: Self.modeCC, value: coded.minor ? 127 : 0)
        }

        if let tempo = analysis?.tempo, tempo > 0 {
            send(cc: Self.tempoCC, value: Self.tempoCCValue(for: tempo))
        }

        setClock(bpm: analysis?.tempo)
    }

    /// Sends the current values on demand, so a DAW sitting in MIDI-learn mode
    /// has something to bind to without waiting for the next track change.
    ///
    /// Falls back to mid-range values when nothing is playing — you should be
    /// able to set the mapping up before starting a song.
    func sendForLearn(_ analysis: TrackAnalysis?, control: LearnTarget) {
        guard ready, isEnabled else { return }

        let cc: UInt8
        let settled: UInt8

        switch control {
        case .key:
            cc = Self.keyCC
            if let key = analysis?.key, let coded = Self.encode(key: key) {
                settled = UInt8((Double(coded.root) * 127.0 / 11.0).rounded())
            } else {
                settled = 64
            }
        case .mode:
            cc = Self.modeCC
            if let key = analysis?.key, let coded = Self.encode(key: key) {
                settled = coded.minor ? 127 : 0
            } else {
                settled = 127
            }
        case .tempo:
            cc = Self.tempoCC
            if let tempo = analysis?.tempo, tempo > 0 {
                settled = Self.tempoCCValue(for: tempo)
            } else {
                settled = 64
            }
        }

        // A host in learn mode is waiting for a control to *move*. One lone
        // message often isn't enough to recognise — a hardware knob emits a
        // stream. Sweep the range, then settle on the real value.
        let sweep: [UInt8] = [0, 21, 42, 64, 85, 106, 127, settled]
        let endpoint = source

        for (step, value) in sweep.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.04) {
                Self.transmit([0xB0, cc, min(127, value)], from: endpoint)
            }
        }
    }

    enum LearnTarget {
        case key, mode, tempo
    }

    /// MIDI beat clock, off unless explicitly enabled — Logic only follows it in
    /// external sync, which slaves its transport as well as its tempo.
    func setClock(bpm: Double?) {
        clockTimer?.cancel()
        clockTimer = nil

        guard ready, isEnabled, clockEnabled, let bpm, bpm > 20, bpm < 400 else { return }

        let endpoint = source
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue.global(qos: .userInteractive))
        // 24 pulses per quarter note is the MIDI clock standard.
        timer.schedule(deadline: .now(), repeating: 60.0 / (bpm * 24.0),
                       leeway: .nanoseconds(100_000))
        timer.setEventHandler { Self.transmit([0xF8], from: endpoint) }
        timer.resume()
        clockTimer = timer
    }

    func stopClock() {
        clockTimer?.cancel()
        clockTimer = nil
    }

    // MARK: - Encoding

    /// "F♯m" → (root 6, minor). Handles both ♯/♭ and #/b spellings.
    static func encode(key: String) -> (root: Int, minor: Bool)? {
        var text = key.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        let lower = text.lowercased()
        let minor = lower.hasSuffix("m") && !lower.hasSuffix("maj")
        if minor { text.removeLast() }

        let naturals: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5,
                                          "G": 7, "A": 9, "B": 11]
        guard let head = text.first,
              var index = naturals[Character(head.uppercased())] else { return nil }

        let accidental = text.dropFirst()
        if accidental.hasPrefix("♯") || accidental.hasPrefix("#") { index += 1 }
        if accidental.hasPrefix("♭") || accidental.hasPrefix("b") { index -= 1 }

        return ((index % 12 + 12) % 12, minor)
    }

    // MARK: - Transmission

    private func send(cc: UInt8, value: UInt8) {
        Self.transmit([0xB0, cc, min(127, value)], from: source)
    }

    /// nonisolated so the clock timer can transmit from its own queue;
    /// MIDIReceived is safe to call from any thread.
    nonisolated private static func transmit(_ bytes: [UInt8], from endpoint: MIDIEndpointRef) {
        var payload = bytes
        var list = MIDIPacketList()

        // The pointer has to stay valid for the whole build-and-send sequence.
        // Taking it with `UnsafeMutablePointer(&list)` yields one that dies at the
        // end of that call, which the compiler flags as a dangling pointer.
        withUnsafeMutablePointer(to: &list) { pointer in
            var packet = MIDIPacketListInit(pointer)
            packet = MIDIPacketListAdd(pointer,
                                       MemoryLayout<MIDIPacketList>.size,
                                       packet, 0, payload.count, &payload)
            _ = MIDIReceived(endpoint, pointer)
        }
    }
}
