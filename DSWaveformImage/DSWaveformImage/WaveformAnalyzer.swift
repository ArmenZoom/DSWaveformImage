//
// see
// * http://www.davidstarke.com/2015/04/waveforms.html
// * http://stackoverflow.com/questions/28626914
// for very good explanations of the asset reading and processing path
//
// FFT done using: https://github.com/jscalo/tempi-fft
//

import Foundation
import Accelerate
import AVFoundation

// TODO: can we have this not be public? Or at least not exposing TempiFFT? That would also need removal of @objc in TempiFFT
public struct WaveformAnalysis {
    let amplitudes: [Float]
    let fft: [FFTResult]?
}

class WaveformAnalyzer {
    func waveformSamples(from assetReader: AVAssetReader, count: Int, fftBands: Int?) -> WaveformAnalysis? {
        guard let audioTrack = assetReader.asset.tracks.first else {
            return nil
        }

        let trackOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings())
        assetReader.add(trackOutput)

        let requiredNumberOfSamples = count
        let analysis = extract(samplesFrom: assetReader, downsampledTo: requiredNumberOfSamples, fftBands: fftBands)

        switch assetReader.status {
        case .completed:
            return analysis
        default:
            print("ERROR: reading waveform audio data has failed \(assetReader.status)")
            return nil
        }
    }
}

// MARK: - Private

fileprivate extension WaveformAnalyzer {
    private var silenceDbThreshold: Float { return -50.0 } // everything below -50 dB will be clipped

    func extract(samplesFrom assetReader: AVAssetReader,
                 downsampledTo targetSampleCount: Int,
                 fftBands: Int?) -> WaveformAnalysis {
        var outputSamples = [Float]()
        var outputFFT = fftBands == nil ? nil : [FFTResult]()
        var sampleBuffer = Data()
        var sampleBufferFFT = Data()

        // read upfront to avoid frequent re-calculation (and memory bloat from C-bridging)
        let samplesPerPixel = max(1, sampleCount(from: assetReader) / targetSampleCount)
        let samplesPerFFT = 4096 // ~100ms at 44.1kHz, rounded to closest pow(2) for FFT

        assetReader.startReading()
        while assetReader.status == .reading {
            let trackOutput = assetReader.outputs.first!

            guard let nextSampleBuffer = trackOutput.copyNextSampleBuffer(),
                let blockBuffer = CMSampleBufferGetDataBuffer(nextSampleBuffer) else {
                    break
            }

            var readBufferLength = 0
            var readBufferPointer: UnsafeMutablePointer<Int8>? = nil
            CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &readBufferLength, totalLengthOut: nil, dataPointerOut: &readBufferPointer)
            sampleBuffer.append(UnsafeBufferPointer(start: readBufferPointer, count: readBufferLength))
            sampleBufferFFT.append(UnsafeBufferPointer(start: readBufferPointer, count: readBufferLength))
            CMSampleBufferInvalidate(nextSampleBuffer)

            let processedSamples = process(sampleBuffer, from: assetReader, downsampleTo: samplesPerPixel)
            outputSamples += processedSamples

            if processedSamples.count > 0 {
                // vDSP_desamp uses strides of samplesPerPixel; remove only the processed ones
                sampleBuffer.removeFirst(processedSamples.count * samplesPerPixel * MemoryLayout<Int16>.size)
            }

            if let fftBands = fftBands, sampleBufferFFT.count / MemoryLayout<Int16>.size >= samplesPerFFT {
                let processedFFTs = process(sampleBufferFFT, from: assetReader, samplesPerFFT: samplesPerFFT, fftBands: fftBands)
                sampleBufferFFT.removeFirst(processedFFTs.count * samplesPerFFT * MemoryLayout<Int16>.size)
                outputFFT? += processedFFTs
            }
        }

        // if we don't have enough pixels yet,
        // process leftover samples with padding (to reach multiple of samplesPerPixel for vDSP_desamp)
        if outputSamples.count < targetSampleCount {
            let missingSampleCount = (targetSampleCount - outputSamples.count) * samplesPerPixel
            let backfillPaddingSampleCount = missingSampleCount - (sampleBuffer.count / MemoryLayout<Int16>.size)
            let backfillPaddingSampleCount16 = backfillPaddingSampleCount * MemoryLayout<Int16>.size
            let backfillPaddingSamples = [UInt8](repeating: 0, count: backfillPaddingSampleCount16)
            sampleBuffer.append(backfillPaddingSamples, count: backfillPaddingSampleCount16)
            let processedSamples = process(sampleBuffer, from: assetReader, downsampleTo: samplesPerPixel)
            outputSamples += processedSamples
        }

        return WaveformAnalysis(amplitudes: normalize(outputSamples), fft: outputFFT)
    }

    private func process(_ sampleBuffer: Data,
                         from assetReader: AVAssetReader,
                         downsampleTo samplesPerPixel: Int) -> [Float] {
        var downSampledData = [Float]()
        let sampleLength = sampleBuffer.count / MemoryLayout<Int16>.size
        sampleBuffer.withUnsafeBytes { (samples: UnsafePointer<Int16>) in
            var loudestClipValue: Float = 0.0
            var quietestClipValue = silenceDbThreshold
            var zeroDbEquivalent: Float = Float(Int16.max) // maximum amplitude storable in Int16 = 0 Db (loudest)
            let samplesToProcess = vDSP_Length(sampleLength)

            var processingBuffer = [Float](repeating: 0.0, count: Int(samplesToProcess))
            vDSP_vflt16(samples, 1, &processingBuffer, 1, samplesToProcess) // convert 16bit int to float (
            vDSP_vabs(processingBuffer, 1, &processingBuffer, 1, samplesToProcess) // absolute amplitude value
            vDSP_vdbcon(processingBuffer, 1, &zeroDbEquivalent, &processingBuffer, 1, samplesToProcess, 1) // convert to DB
            vDSP_vclip(processingBuffer, 1, &quietestClipValue, &loudestClipValue, &processingBuffer, 1, samplesToProcess)

            let filter = [Float](repeating: 1.0 / Float(samplesPerPixel), count: samplesPerPixel)
            let downSampledLength = sampleLength / samplesPerPixel
            downSampledData = [Float](repeating: 0.0, count: downSampledLength)

            vDSP_desamp(processingBuffer,
                        vDSP_Stride(samplesPerPixel),
                        filter,
                        &downSampledData,
                        vDSP_Length(downSampledLength),
                        vDSP_Length(samplesPerPixel))
        }

        return downSampledData
    }

    private func process(_ sampleBuffer: Data,
                         from assetReader: AVAssetReader,
                         samplesPerFFT: Int,
                         fftBands: Int) -> [FFTResult] {
        var ffts = [FFTResult]()
        let sampleLength = sampleBuffer.count / MemoryLayout<Int16>.size
        sampleBuffer.withUnsafeBytes { (samples: UnsafePointer<Int16>) in
            let samplesToProcess = vDSP_Length(sampleLength)

            var processingBuffer = [Float](repeating: 0.0, count: Int(samplesToProcess))
            vDSP_vflt16(samples, 1, &processingBuffer, 1, samplesToProcess) // convert 16bit int to float

            repeat {
                autoreleasepool() {
                    let fftBuffer = processingBuffer[0..<samplesPerFFT]
                    let fft = TempiFFT(withSize: samplesPerFFT, sampleRate: 44100.0)
                    fft.windowType = TempiFFTWindowType.hanning
                    fft.fftForward(Array(fftBuffer))
                    let result = fft.calculateLinearBands(minFrequency: 0, maxFrequency: fft.nyquistFrequency, numberOfBands: fftBands)
                    ffts.append(result)
                    
                    processingBuffer.removeFirst(samplesPerFFT)                    
                }
            } while processingBuffer.count >= samplesPerFFT
        }
        return ffts
    }

    func normalize(_ samples: [Float]) -> [Float] {
        return samples.map { $0 / silenceDbThreshold }
    }

    private func sampleCount(from assetReader: AVAssetReader) -> Int {
        let samplesPerChannel = Int(assetReader.asset.duration.value)
        return samplesPerChannel * channelCount(from: assetReader)
    }

    // swiftlint:disable force_cast
    private func channelCount(from assetReader: AVAssetReader) -> Int {
        let audioTrack = (assetReader.outputs.first as? AVAssetReaderTrackOutput)?.track
        var channelCount = 0

        autoreleasepool {
            let descriptions = audioTrack?.formatDescriptions as! [CMFormatDescription]
            descriptions.forEach { formatDescription in
                guard let basicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else { return }
                channelCount = Int(basicDescription.pointee.mChannelsPerFrame)
            }
        }
        return channelCount
    }
    // swiftlint:enable force_cast
}

// MARK: - Configuration

private extension WaveformAnalyzer {
    func outputSettings() -> [String: Any] {
        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }
}
