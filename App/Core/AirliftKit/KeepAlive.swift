import AVFAudio
import Foundation

/// Keeps the app alive in the background (silent audio session) while the user
/// approves the pairing PIN in Settings ▸ Developer Mode.
///
/// Adopted from AirCard-iOS (MIT License, © 2026 Johnny Franks).
@MainActor
final class KeepAlive: NSObject {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var audioRunning = false

    func startAudio() {
        guard !audioRunning else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            if player.engine == nil {
                engine.attach(player)
            }
            let format = engine.outputNode.inputFormat(forBus: 0)
            guard format.sampleRate > 0 && format.channelCount > 0 else {
                audioRunning = true
                return
            }

            engine.connect(player, to: engine.mainMixerNode, format: format)

            let frames = max(1024, AVAudioFrameCount(format.sampleRate))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
                audioRunning = true
                return
            }
            buffer.frameLength = frames
            if let channelData = buffer.floatChannelData {
                for channel in 0..<Int(format.channelCount) {
                    memset(channelData[channel], 0, Int(frames) * MemoryLayout<Float>.size)
                }
            }

            if !engine.isRunning {
                try engine.start()
            }
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            audioRunning = true
        } catch {
            audioRunning = false
            Log.warning("KeepAlive: không khởi động được audio nền — \(error.localizedDescription)", category: .pairing)
        }
    }

    func stopAll() {
        guard audioRunning else { return }
        audioRunning = false
        player.stop()
        if engine.isRunning {
            engine.stop()
        }
        if player.engine != nil {
            engine.detach(player)
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
