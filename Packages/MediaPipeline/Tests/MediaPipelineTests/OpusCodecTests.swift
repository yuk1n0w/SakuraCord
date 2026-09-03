import AVFAudio
@testable import MediaPipeline
import Synchronization
import Testing

@Test func `opus packet duration follows its TOC sequence`() throws {
    #expect(try OpusPacket.sampleCount(Data([0b0001_1000])) == 2_880)
    #expect(try OpusPacket.sampleCount(Data([0b0110_0000])) == 480)
    #expect(try OpusPacket.sampleCount(Data([0b1000_0000])) == 120)
    #expect(try OpusPacket.sampleCount(Data([0b1000_0010])) == 240)
    #expect(try OpusPacket.sampleCount(Data([0b1000_0011, 0b0000_0100])) == 480)
}

@Test func `opus packet duration rejects missing and oversized frame counts`() {
    #expect(throws: OpusCodecError.invalidPacket) {
        try OpusPacket.sampleCount(Data([0b0001_1011]))
    }
    #expect(throws: OpusCodecError.invalidPacket) {
        try OpusPacket.sampleCount(Data([0b0001_1011, 0b0000_0000]))
    }
    #expect(throws: OpusCodecError.invalidPacket) {
        try OpusPacket.sampleCount(Data([0b0001_1011, 0b0000_0011]))
    }
}

@Test func `native opus codec produces discord twenty millisecond frames`() throws {
    let codec = try OpusCodec()
    let format = OpusCodec.pcmFormat
    let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: OpusCodec.frameSamples))
    input.frameLength = OpusCodec.frameSamples
    for channel in 0 ..< Int(format.channelCount) {
        let samples = try #require(input.floatChannelData?[channel])
        for index in 0 ..< Int(input.frameLength) {
            samples[index] = Float(sin(Double(index) * 0.08)) * 0.05
        }
    }

    let packet = try codec.encode(input)
    let decoded = try codec.decode(packet)

    #expect(!packet.isEmpty)
    #expect(packet.count <= OpusCodec.maximumPacketSize)
    #expect(decoded.format.sampleRate == 48000)
    #expect(decoded.format.channelCount == 2)
    #expect(decoded.frameLength > 0)
}

@Test func `native opus codec decodes sixty millisecond packets`() throws {
    let packet = Data([0xFF, 0x03, 0xFF, 0xFE, 0xFF, 0xFE, 0xFF, 0xFE])
    let decoded = try OpusCodec().decode(packet)

    #expect(decoded.frameLength > OpusCodec.frameSamples)
    #expect(decoded.frameLength <= 2_880)
}

@Test func `native opus codec encodes and decodes consecutive voice packets`() throws {
    let codec = try OpusCodec()
    let format = OpusCodec.pcmFormat
    let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: OpusCodec.frameSamples))
    input.frameLength = OpusCodec.frameSamples
    for channel in 0 ..< Int(format.channelCount) {
        let samples = try #require(input.floatChannelData?[channel])
        for index in 0 ..< Int(input.frameLength) {
            samples[index] = Float(sin(Double(index) * 0.11)) * 0.08
        }
    }

    for _ in 0 ..< 20 {
        let packet = try codec.encode(input)
        let decoded = try codec.decode(packet)
        #expect(!packet.isEmpty)
        #expect(decoded.frameLength > 0)
    }
}

@Test func `media device catalog returns only usable directions`() {
    let snapshot = MediaDeviceCatalog.snapshot()
    #expect(snapshot.audioInputs.allSatisfy { !$0.name.isEmpty && !$0.uid.isEmpty })
    #expect(snapshot.audioOutputs.allSatisfy { !$0.name.isEmpty && !$0.uid.isEmpty })
    #expect(snapshot.cameras.allSatisfy { !$0.name.isEmpty && !$0.uniqueID.isEmpty })
}

@Test func `voice capture encoder meters controlled audio and mutes transmitted samples`() throws {
    let encoder = try OpusSampleBufferEncoder()
    let capturedFrames = Mutex<[CapturedOpusFrame]>([])
    let capturedLevels = Mutex<[Float]>([])
    encoder.handler = { frame in
        capturedFrames.withLock { $0.append(frame) }
    }
    encoder.levelHandler = { level in
        capturedLevels.withLock { $0.append(level) }
    }
    let format = OpusCodec.pcmFormat
    let input = try #require(AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: OpusCodec.frameSamples
    ))
    input.frameLength = OpusCodec.frameSamples
    for channel in 0 ..< Int(format.channelCount) {
        let samples = try #require(input.floatChannelData?[channel])
        for index in 0 ..< Int(input.frameLength) {
            samples[index] = Float(sin(Double(index) * 0.1)) * 0.08
        }
    }

    encoder.process(input)

    #expect(capturedFrames.withLock { $0.count } == 1)
    #expect(capturedFrames.withLock { $0.first?.containsVoice } == true)
    #expect(capturedLevels.withLock { ($0.last ?? 0) > 0 })

    encoder.isMuted = true
    encoder.process(input)

    #expect(capturedFrames.withLock { $0.count } == 2)
    #expect(capturedFrames.withLock { $0.last?.containsVoice } == false)
    #expect(capturedLevels.withLock { $0.last } == 0)
    encoder.reset()
}
