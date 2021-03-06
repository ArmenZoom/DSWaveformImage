import Foundation
import AVFoundation

public struct WaveformImageDrawer {
    var sampleWidth: CGFloat = 0.0
    var sampleOffset: CGFloat = 0.0
    var imageMultiplayer: CGFloat = 1.0
    
    public init(sampleWidth: CGFloat = 2.0, sampleOffset: CGFloat = 1.5, imageMultiplayer: CGFloat = 4.0) {
        self.sampleWidth = sampleWidth * imageMultiplayer
        self.sampleOffset = sampleOffset * imageMultiplayer
        self.imageMultiplayer = imageMultiplayer
    }
    
    
    public func waveformPathPoints(from waveform: Waveform, with configuration: WaveformConfiguration) -> [CGPoint] {
        let scaledSize = CGSize(width: configuration.size.width * configuration.scale,
                                height: configuration.size.height * configuration.scale)
        let scaledConfiguration = WaveformConfiguration(size: scaledSize,
                                                        color: configuration.color,
                                                        backgroundColor: configuration.backgroundColor,
                                                        style: configuration.style,
                                                        position: configuration.position,
                                                        scale: configuration.scale,
                                                        paddingFactor: configuration.paddingFactor)
        return renderPoints(waveform: waveform, with: scaledConfiguration)
    }
    

    
    // swiftlint:disable function_parameter_count
    public func waveformImage(from waveform: Waveform, with configuration: WaveformConfiguration) -> UIImage? {
        let scaledSize = CGSize(width: configuration.size.width * configuration.scale,
                                height: configuration.size.height * configuration.scale)
        let scaledConfiguration = WaveformConfiguration(size: scaledSize,
                                                        color: configuration.color,
                                                        backgroundColor: configuration.backgroundColor,
                                                        style: configuration.style,
                                                        position: configuration.position,
                                                        scale: configuration.scale,
                                                        paddingFactor: configuration.paddingFactor)
        return render(waveform: waveform, with: scaledConfiguration)
    }
    
    public func waveformImage(fromAudio audioAsset: AVURLAsset,
                              size: CGSize,
                              color: UIColor = UIColor.black,
                              backgroundColor: UIColor = UIColor.clear,
                              style: WaveformStyle = .gradient,
                              position: WaveformPosition = .middle,
                              scale: CGFloat = 1.0,
                              paddingFactor: CGFloat? = nil) -> UIImage? {
        guard let waveform = Waveform(audioAsset: audioAsset) else { return nil }
        let configuration = WaveformConfiguration(size: CGSize(width: size.width * self.imageMultiplayer, height: size.height * self.imageMultiplayer) , color: color, backgroundColor: backgroundColor, style: style,
                                                  position: position, scale: scale, paddingFactor: paddingFactor)
        return waveformImage(from: waveform, with: configuration)
    }
    
    public func waveformImage(fromAudioAt audioAssetURL: URL,
                              size: CGSize,
                              color: UIColor = UIColor.black,
                              backgroundColor: UIColor = UIColor.clear,
                              style: WaveformStyle = .gradient,
                              position: WaveformPosition = .middle,
                              scale: CGFloat = 1.0,
                              paddingFactor: CGFloat? = nil) -> UIImage? {
        let audioAsset = AVURLAsset(url: audioAssetURL)
        return waveformImage(fromAudio: audioAsset, size: size, color: color, backgroundColor: backgroundColor, style: style,
                             position: position, scale: scale, paddingFactor: paddingFactor)
    }
    
    public func waveformPathPoints(fromAudio audioAsset: AVURLAsset,
                                size: CGSize,
                                color: UIColor = UIColor.black,
                                backgroundColor: UIColor = UIColor.clear,
                                style: WaveformStyle = .gradient,
                                position: WaveformPosition = .middle,
                                scale: CGFloat = 1.0,
                                paddingFactor: CGFloat? = nil) -> [CGPoint] {
          guard let waveform = Waveform(audioAsset: audioAsset) else { return [] }
          let configuration = WaveformConfiguration(size: CGSize(width: size.width * self.imageMultiplayer, height: size.height * self.imageMultiplayer) , color: color, backgroundColor: backgroundColor, style: style,
                                                    position: position, scale: scale, paddingFactor: paddingFactor)
          return waveformPathPoints(from: waveform, with: configuration)
      }
      
      public func waveformPathPoints(fromAudioAt audioAssetURL: URL,
                                size: CGSize,
                                color: UIColor = UIColor.black,
                                backgroundColor: UIColor = UIColor.clear,
                                style: WaveformStyle = .gradient,
                                position: WaveformPosition = .middle,
                                scale: CGFloat = 1.0,
                                paddingFactor: CGFloat? = nil) -> [CGPoint] {
          let audioAsset = AVURLAsset(url: audioAssetURL)
          return waveformPathPoints(fromAudio: audioAsset, size: size, color: color, backgroundColor: backgroundColor, style: style,
                               position: position, scale: scale, paddingFactor: paddingFactor)
      }
    // swiftlint:enable function_parameter_count
}

// MARK: Image generation

private extension WaveformImageDrawer {
    func renderPoints(waveform: Waveform, with configuration: WaveformConfiguration) -> [CGPoint] {
        let sampleCount = Int(configuration.size.width / (self.sampleWidth + self.sampleOffset))
        guard let samples = waveform.samples(count: sampleCount) else { return [] }
        return getPathPoints(from: samples, with: configuration)
    }
    
    func render(waveform: Waveform, with configuration: WaveformConfiguration) -> UIImage? {
        let sampleCount = Int(configuration.size.width / (self.sampleWidth + self.sampleOffset))
        guard let imageSamples = waveform.samples(count: sampleCount) else { return nil }
        return graphImage(from: imageSamples, with: configuration)
    }
    
    private func graphImage(from samples: [Float], with configuration: WaveformConfiguration) -> UIImage? {
        UIGraphicsBeginImageContextWithOptions(configuration.size, false, configuration.scale)
        let context = UIGraphicsGetCurrentContext()!
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        
        drawBackground(on: context, with: configuration)
        drawGraph(from: samples, on: context, with: configuration)
        
        let graphImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        return graphImage
    }
    
    private func drawBackground(on context: CGContext, with configuration: WaveformConfiguration) {
        context.setFillColor(configuration.backgroundColor.cgColor)
        context.fill(CGRect(origin: CGPoint.zero, size: configuration.size))
    }
    
    private func drawGraph(from samples: [Float],
                           on context: CGContext,
                           with configuration: WaveformConfiguration) {
        let graphRect = CGRect(origin: CGPoint.zero, size: configuration.size)
        let positionAdjustedGraphCenter = CGFloat(configuration.position.value()) * graphRect.size.height
        let verticalPaddingDivisor = configuration.paddingFactor ?? CGFloat(configuration.position.value() == 0.5 ? 2.5 : 1.5)
        let drawMappingFactor = graphRect.size.height / verticalPaddingDivisor
        let minimumGraphAmplitude: CGFloat = 1 // we want to see at least a 1pt line for silence
        
        let allPaths = CGMutablePath()
        var maxAmplitude: CGFloat = 0.0 // we know 1 is our max in normalized data, but we keep it 'generic'
        //context.setp.setLineWidth(self.sampleWidth)
        for (x, sample) in samples.enumerated() {
            let xPos = CGFloat(x) * (sampleOffset + sampleWidth)
            let invertedDbSample = 1 - CGFloat(sample) // sample is in dB, linearly normalized to [0, 1] (1 -> -50 dB)
            let drawingAmplitude = max(minimumGraphAmplitude, invertedDbSample * drawMappingFactor)
            let drawingAmplitudeUp = positionAdjustedGraphCenter - drawingAmplitude
            // let drawingAmplitudeDown = positionAdjustedGraphCenter + drawingAmplitude
            maxAmplitude = max(drawingAmplitude, maxAmplitude)

            let cgRect = CGRect(x: xPos , y: drawingAmplitudeUp, width: sampleWidth, height: 2 * drawingAmplitude)
            let path = UIBezierPath(roundedRect: cgRect, cornerRadius: sampleWidth / 2.0)
            allPaths.addPath(path.cgPath)

        }
        
        context.addPath(allPaths)
        
        switch configuration.style {
        case .filled, .striped:
            context.setFillColor(configuration.color.cgColor)
            context.fillPath()
        case .gradient:
            context.replacePathWithStrokedPath()
            context.clip()
            let colors = NSArray(array: [
                configuration.color.cgColor,
                configuration.color.highlighted(brightnessAdjustment: 0.5).cgColor
                ]) as CFArray
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: nil)!
            context.drawLinearGradient(gradient,
                                       start: CGPoint(x: 0, y: positionAdjustedGraphCenter - maxAmplitude),
                                       end: CGPoint(x: 0, y: positionAdjustedGraphCenter + maxAmplitude),
                                       options: .drawsAfterEndLocation)
        }
    }
    
    func getPathPoints(from samples: [Float], with configuration: WaveformConfiguration) -> [CGPoint] {
        let graphRect = CGRect(origin: CGPoint.zero, size: configuration.size)
        let positionAdjustedGraphCenter = CGFloat(configuration.position.value()) * graphRect.size.height
        let verticalPaddingDivisor = configuration.paddingFactor ?? CGFloat(configuration.position.value() == 0.5 ? 2.5 : 1.5)
        let drawMappingFactor = graphRect.size.height / verticalPaddingDivisor
        let minimumGraphAmplitude: CGFloat = 1 // we want to see at least a 1pt line for silence
      
        var allPoints: [CGPoint] = []
        var upPoints: [CGPoint] = []
        var downPoints: [CGPoint] = []
        
        for i in stride(from: 0, to: samples.count, by: 1) {
            let sample = samples[i]
            let xPos = CGFloat(i) * (sampleOffset + sampleWidth)
            let invertedDbSample = 1 - CGFloat(sample) // sample is in dB, linearly normalized to [0, 1] (1 -> -50 dB)
            let drawingAmplitude = max(minimumGraphAmplitude, invertedDbSample * drawMappingFactor)
            let drawingAmplitudeUp = positionAdjustedGraphCenter - drawingAmplitude
             
            let cgRect = CGRect(x: xPos , y: drawingAmplitudeUp, width: sampleWidth, height: 2 * drawingAmplitude)
            downPoints.insert(CGPoint(x: cgRect.midX, y: cgRect.maxY), at: 0)
            upPoints.append(CGPoint(x: cgRect.midX, y: cgRect.minY))
        }
        allPoints = upPoints + downPoints
        return allPoints
    }
}
