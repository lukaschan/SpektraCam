import Foundation
private struct Case: Decodable {
    let width: Int,height: Int,luminance: [Double],smallWidth: Int,smallHeight: Int,smallLuminance: [Double],expected: [String: Double]
}
private struct Fixtures: Decodable { let cases: [Case] }
@main struct MeteringChecks {
    static func main() async throws {
        let fixture=try JSONDecoder().decode(Fixtures.self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
        var maximum=0.0,count=0
        for f in fixture.cases {
            let image=try MeteringCore.Image(width:f.width,height:f.height,luminance:f.luminance)
            let small=try image.smallPreview()
            precondition(small.width == f.smallWidth && small.height == f.smallHeight)
            for i in small.luminance.indices {
                let error=abs(small.luminance[i]-f.smallLuminance[i]);precondition(error<1e-12,"Metering resize mismatch: \(error)")
                maximum=max(maximum,error);count+=1
            }
            for (method,expected) in f.expected {
                let value=small.exposureEV(method:method),error=abs(value-expected)
                precondition(error<1e-11,"Metering \(method) mismatch: \(value) vs \(expected)")
                maximum=max(maximum,error);count+=1
            }
        }
        print("PASS: seven metering methods, six image shapes and anti-aliased preview sampling; \(count) values; max absolute error \(maximum)")
        // Independent scalar evaluation of selected legacy convolution samples.
        // Large, portrait and one-dimensional inputs cover the slow preview path
        // and mirror boundaries without computing an unused full-size blur.
        for (width,height,limit) in [(2160,1620,256),(1080,1620,256),(333,199,63),(1,2049,256),(2049,1,256)] {
            let values = (0..<(width*height)).map { Double(($0*17+$0/width*31)%1000)/1000 }
            let image = try MeteringCore.Image(width: width, height: height, luminance: values)
            let start = ContinuousClock.now
            let small = try image.smallPreview(maximum: limit)
            precondition(start.duration(to: .now) < .seconds(1), "Metering resized by blurring the full source")
            for y in Set([0,small.height/3,small.height/2,small.height-1]) {
                for x in Set([0,small.width/3,small.width/2,small.width-1]) {
                    let expected = scalarSample(values, width: width, height: height,
                        outputWidth: small.width, outputHeight: small.height, x: x, y: y)
                    precondition(abs(expected-small.luminance[y*small.width+x]) < 1e-12,
                        "Large metering preview differs from the reference convolution")
                }
            }
        }
        let image = try MeteringCore.Image(width: 2160, height: 1620,
            luminance: .init(repeating: 0.184, count: 2160*1620))
        let cancel = Task { await Task.yield(); return try image.smallPreview() }
        cancel.cancel()
        do { _ = try await cancel.value; preconditionFailure("Cancelled metering completed") }
        catch is CancellationError {}
        print("PASS: large/portrait/degenerate sampling matches scalar reference, remains within the metering budget and honors cancellation")
    }
    private static func scalarSample(_ source: [Double], width: Int, height: Int,
        outputWidth: Int, outputHeight: Int, x: Int, y: Int) -> Double {
        func kernel(_ ratio: Double) -> [Double] {
            let sigma = max(0,(ratio-1)/2)
            guard sigma > 1e-15 else { return [1] }
            let radius = Int(4*sigma+0.5)
            let values = (-radius...radius).map { exp(-0.5*Double($0*$0)/(sigma*sigma)) }
            let sum = values.reduce(0,+)
            return values.map { $0/sum }
        }
        func mirror(_ index: Int, _ size: Int) -> Int {
            if size == 1 { return 0 }
            let period = 2*(size-1)
            let point = ((index%period)+period)%period
            return point < size ? point : period-point
        }
        let kx = kernel(Double(width)/Double(outputWidth))
        let ky = kernel(Double(height)/Double(outputHeight))
        let sx = min(width-1,Int(floor((Double(x)+0.5)*Double(width)/Double(outputWidth))))
        let sy = min(height-1,Int(floor((Double(y)+0.5)*Double(height)/Double(outputHeight))))
        var value = 0.0
        for column in kx.indices {
            var vertical = 0.0
            let sourceX = mirror(sx+column-kx.count/2,width)
            for row in ky.indices {
                let sourceY = mirror(sy+row-ky.count/2,height)
                vertical += source[sourceY*width+sourceX]*ky[row]
            }
            value += vertical*kx[column]
        }
        return value
    }
}
