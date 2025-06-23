import AVFoundation
import Combine

class AudioReactiveModel: ObservableObject {
    @Published var amplitude: Float = 1.0
    @Published var flashActive: Bool = false
    
    private var audioEngine = AVAudioEngine()
    private var flashTimer: Timer?
    private var lastAmplitude: Float = 1.0

    init() {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .undetermined:
            session.requestRecordPermission { allowed in
                print("Microphone permission: \(allowed)")
            }
        case .denied:
            print("Microphone access denied. Please enable it in Settings.")
        case .granted:
            print("Microphone access granted.")
        @unknown default:
            print("Unknown mic permission status.")
        }

        do {
            try session.setCategory(.playAndRecord, options: [.defaultToSpeaker, .mixWithOthers])
            try session.setActive(true)
        } catch {
            print("Audio session error: \(error)")
        }

        let input = audioEngine.inputNode
        let bus = 0
        let format = input.inputFormat(forBus: bus)
        input.installTap(onBus: bus, bufferSize: 256, format: format) { buffer, _ in
            let rms = Self.calculateRMS(buffer: buffer)
            let amp = max(0.5, min(rms * 20, 8.0))
            DispatchQueue.main.async {
                self.amplitude = amp
                // Trigger a flash if amplitude has a sudden spike
                if amp > 1.5 && self.lastAmplitude <= 1.5 {
                    self.triggerFlash()
                }
                self.lastAmplitude = amp
            }
        }
        do {
            try audioEngine.start()
        } catch {
            print("Audio engine failed: \(error)")
        }
    }

    private func triggerFlash() {
        flashActive = true
        flashTimer?.invalidate()
        flashTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { _ in
            self.flashActive = false
        }
    }

    private static func calculateRMS(buffer: AVAudioPCMBuffer) -> Float {
        guard let floatChannelData = buffer.floatChannelData else { return 1.0 }
        let channelData = floatChannelData[0]
        let frameLength = Int(buffer.frameLength)
        var sum: Float = 0.0
        for i in 0..<frameLength {
            sum += channelData[i] * channelData[i]
        }
        return sqrt(sum / Float(frameLength))
    }
}
