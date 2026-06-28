import Cocoa
import AVFoundation
import CoreMedia
import Accelerate
import ScreenCaptureKit

// RecordMonitor — live audio passthrough from a USB record player to the
// system default output, with a live camera preview of the turntable.
// VU meter and sound visualiser can overlay or replace the video feed.
// System audio (ScreenCaptureKit) can drive the meter and visualiser.

let kRepoSlug = "polerix/RecordMonitor"
let kRepoURL  = "https://github.com/polerix/RecordMonitor"

#if arch(arm64)
let kArchName     = "Apple Silicon"
let kArchKeywords = ["applesilicon", "apple-silicon", "arm64", "silicon"]
#else
let kArchName     = "Intel"
let kArchKeywords = ["intel", "x86_64", "x86-64", "x64", "x86"]
#endif

// MARK: - Persisted settings

enum MeterStyle: Int, CaseIterable {
    case segmented, needle, gradient
    var title: String {
        switch self {
        case .segmented: return "Segmented LED"
        case .needle:    return "Classic Needle"
        case .gradient:  return "Gradient Bar"
        }
    }
}

enum VisualiserStyle: Int, CaseIterable {
    case bars, radial, waveform, particles, circularWave, tunnel, mirror
    var title: String {
        switch self {
        case .bars:         return "Spectrum Bars"
        case .radial:       return "Radial Spectrum"
        case .waveform:     return "Waveform"
        case .particles:    return "Particle Burst"
        case .circularWave: return "Circular Wave"
        case .tunnel:       return "Tunnel Rings"
        case .mirror:       return "Mirror Spectrum"
        }
    }
}

final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard
    private init() {
        d.register(defaults: [
            "meterOverlay":    true,
            "meterStyle":      MeterStyle.segmented.rawValue,
            "visualiser":      false,
            "visualiserStyle": VisualiserStyle.bars.rawValue,
            "systemAudioVis":  false,
        ])
    }
    var meterOverlay:    Bool            { get { d.bool(forKey:"meterOverlay") }    set { d.set(newValue,forKey:"meterOverlay") } }
    var meterStyle:      MeterStyle      { get { MeterStyle(rawValue:d.integer(forKey:"meterStyle")) ?? .segmented }       set { d.set(newValue.rawValue,forKey:"meterStyle") } }
    var visualiser:      Bool            { get { d.bool(forKey:"visualiser") }      set { d.set(newValue,forKey:"visualiser") } }
    var visualiserStyle: VisualiserStyle { get { VisualiserStyle(rawValue:d.integer(forKey:"visualiserStyle")) ?? .bars }  set { d.set(newValue.rawValue,forKey:"visualiserStyle") } }
    var systemAudioVis:  Bool            { get { d.bool(forKey:"systemAudioVis") }  set { d.set(newValue,forKey:"systemAudioVis") } }
}

// MARK: - Device enumeration

func audioInputDevices() -> [AVCaptureDevice] {
    var byID: [String: AVCaptureDevice] = [:]
    let ds = AVCaptureDevice.DiscoverySession(deviceTypes:[.microphone,.external], mediaType:.audio, position:.unspecified)
    for d in ds.devices { byID[d.uniqueID] = d }
    for d in AVCaptureDevice.devices(for:.audio) { byID[d.uniqueID] = d }
    return Array(byID.values).sorted { $0.localizedName < $1.localizedName }
}

func videoInputDevices() -> [AVCaptureDevice] {
    var byID: [String: AVCaptureDevice] = [:]
    let ds = AVCaptureDevice.DiscoverySession(deviceTypes:[.builtInWideAngleCamera,.external], mediaType:.video, position:.unspecified)
    for d in ds.devices { byID[d.uniqueID] = d }
    for d in AVCaptureDevice.devices(for:.video) { byID[d.uniqueID] = d }
    return Array(byID.values).sorted { $0.localizedName < $1.localizedName }
}

func bestMatch(_ devices:[AVCaptureDevice], _ needles:[String], fallbackExternal:Bool) -> AVCaptureDevice? {
    let lc = needles.map { $0.lowercased() }
    if let hit = devices.first(where:{ d in lc.contains(where:{ d.localizedName.lowercased().contains($0) }) }) { return hit }
    if fallbackExternal, #available(macOS 14.0, *), let ext = devices.first(where:{ $0.deviceType == .external }) { return ext }
    return devices.first
}

// MARK: - Base right-click view

class CapturingView: NSView {
    var contextMenuProvider: (() -> NSMenu)?
    override func menu(for event: NSEvent) -> NSMenu? { contextMenuProvider?() ?? super.menu(for:event) }
}

// MARK: - Video preview

final class PreviewView: CapturingView {
    let previewLayer = AVCaptureVideoPreviewLayer()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        previewLayer.videoGravity = .resizeAspect
        previewLayer.backgroundColor = NSColor.black.cgColor
        layer = previewLayer; wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - VU Meter (three styles)

final class MeterView: CapturingView {
    var levels: [CGFloat] = [0,0]; var peaks: [CGFloat] = [0,0]
    var style: MeterStyle = .segmented
    var isOverlay = false
    private let segCount = 24
    private let green = NSColor(srgbRed:0.22, green:0.83, blue:0.33, alpha:1)
    private let amber = NSColor(srgbRed:0.96, green:0.70, blue:0.01, alpha:1)
    private let red   = NSColor(srgbRed:1.00, green:0.23, blue:0.19, alpha:1)
    override var isFlipped: Bool { true }
    func update(levels:[CGFloat], peaks:[CGFloat]) { self.levels=levels; self.peaks=peaks; needsDisplay=true }
    private func segColor(_ f:CGFloat) -> NSColor { f<0.60 ? green : f<0.85 ? amber : red }
    private func channelNames(_ n:Int) -> [String] { n==2 ? ["L","R"] : n==1 ? ["M"] : (0..<n).map{"\($0)"} }
    private func meterArea() -> NSRect {
        guard isOverlay else { return bounds }
        let h: CGFloat = style == .needle ? 150 : 86
        let w = min(bounds.width-48, 560)
        return NSRect(x:(bounds.width-w)/2, y:bounds.height-h-24, width:w, height:h)
    }
    override func draw(_ dirtyRect: NSRect) {
        let area = meterArea()
        if isOverlay {
            let p = NSBezierPath(roundedRect:area.insetBy(dx:-14,dy:-10), xRadius:16, yRadius:16)
            NSColor(calibratedWhite:0, alpha:0.55).setFill(); p.fill()
        } else { NSColor(calibratedWhite:0.04, alpha:1).setFill(); bounds.fill() }
        switch style {
        case .segmented: drawSegmented(in:area)
        case .needle:    drawNeedle(in:area)
        case .gradient:  drawGradient(in:area)
        }
    }
    private func drawSegmented(in area:NSRect) {
        let n=max(1,levels.count); let padX:CGFloat=isOverlay ? 14:32; let padY:CGFloat=isOverlay ? 12:40
        let rowGap:CGFloat=isOverlay ? 10:16
        let rowH=max(8,(area.height-padY*2-rowGap*CGFloat(n-1))/CGFloat(n))
        let rowX=area.minX+padX+26; let rowW=area.maxX-rowX-padX
        let segW=(rowW-3*CGFloat(segCount-1))/CGFloat(segCount)
        let font=NSFont.monospacedSystemFont(ofSize:13, weight:.semibold)
        let names=channelNames(n)
        for ch in 0..<n {
            let y=area.minY+padY+(rowH+rowGap)*CGFloat(ch)
            NSAttributedString(string:names[ch], attributes:[.font:font,.foregroundColor:NSColor(calibratedWhite:0.55,alpha:1)]).draw(at:NSPoint(x:area.minX+padX, y:y+rowH/2-8))
            let lit=Int((levels[ch]*CGFloat(segCount)).rounded()); let peakIdx=Int((peaks[ch]*CGFloat(segCount)).rounded())-1
            for i in 0..<segCount {
                let r=NSRect(x:rowX+(segW+3)*CGFloat(i), y:y, width:segW, height:rowH)
                let p=NSBezierPath(roundedRect:r, xRadius:2, yRadius:2); let f=CGFloat(i)/CGFloat(segCount)
                if i<lit { segColor(f).setFill() }
                else if i==peakIdx && peakIdx>=0 { NSColor(calibratedWhite:0.95,alpha:1).setFill() }
                else { segColor(f).withAlphaComponent(0.12).setFill() }
                p.fill()
            }
        }
    }
    private func drawGradient(in area:NSRect) {
        let n=max(1,levels.count); let padX:CGFloat=isOverlay ? 14:32; let padY:CGFloat=isOverlay ? 12:40
        let rowGap:CGFloat=isOverlay ? 12:18
        let rowH=max(10,(area.height-padY*2-rowGap*CGFloat(n-1))/CGFloat(n))
        let rowX=area.minX+padX+26; let rowW=area.maxX-rowX-padX
        let grad=NSGradient(colors:[green,amber,red], atLocations:[0,0.7,1], colorSpace:.sRGB)!
        let font=NSFont.monospacedSystemFont(ofSize:13, weight:.semibold)
        let names=channelNames(n)
        for ch in 0..<n {
            let y=area.minY+padY+(rowH+rowGap)*CGFloat(ch)
            NSAttributedString(string:names[ch], attributes:[.font:font,.foregroundColor:NSColor(calibratedWhite:0.55,alpha:1)]).draw(at:NSPoint(x:area.minX+padX, y:y+rowH/2-8))
            let track=NSRect(x:rowX, y:y, width:rowW, height:rowH)
            NSColor(calibratedWhite:0.16, alpha:isOverlay ? 0.7:1).setFill()
            NSBezierPath(roundedRect:track, xRadius:rowH/2, yRadius:rowH/2).fill()
            let fw=max(0,rowW*levels[ch])
            if fw>1 {
                let fp=NSBezierPath(roundedRect:NSRect(x:rowX,y:y,width:fw,height:rowH), xRadius:rowH/2, yRadius:rowH/2)
                NSGraphicsContext.saveGraphicsState(); fp.addClip()
                grad.draw(in:NSRect(x:rowX,y:y,width:rowW,height:rowH), angle:0)
                NSGraphicsContext.restoreGraphicsState()
            }
            if peaks[ch]>0.01 {
                NSColor(calibratedWhite:0.97,alpha:1).setFill()
                NSBezierPath(rect:NSRect(x:rowX+rowW*peaks[ch]-1.5, y:y, width:3, height:rowH)).fill()
            }
        }
    }
    private func drawNeedle(in area:NSRect) {
        let n=max(1,levels.count); let gW=area.width/CGFloat(n); let names=channelNames(n)
        for ch in 0..<n { drawGauge(in:NSRect(x:area.minX+gW*CGFloat(ch),y:area.minY,width:gW,height:area.height).insetBy(dx:8,dy:6), value:levels[ch], peak:peaks[ch], name:names[ch]) }
    }
    private func drawGauge(in g:NSRect, value:CGFloat, peak:CGFloat, name:String) {
        let pivot=NSPoint(x:g.midX, y:g.maxY-6); let radius=min(g.width*0.5,g.height)*0.9; let spread=CGFloat.pi*0.34
        let face=NSBezierPath(roundedRect:g, xRadius:10, yRadius:10)
        NSColor(srgbRed:0.94,green:0.90,blue:0.78,alpha:isOverlay ? 0.92:1).setFill(); face.fill()
        NSColor(calibratedWhite:0, alpha:0.25).setStroke(); face.lineWidth=1; face.stroke()
        for t in 0...11 {
            let f=CGFloat(t)/11; let a = -spread+f*spread*2
            let p=NSBezierPath()
            p.move(to:NSPoint(x:pivot.x+sin(a)*radius*0.9, y:pivot.y-cos(a)*radius*0.9))
            p.line(to:NSPoint(x:pivot.x+sin(a)*radius, y:pivot.y-cos(a)*radius))
            (f>0.72 ? red : NSColor(calibratedWhite:0.2,alpha:1)).setStroke(); p.lineWidth=f>0.72 ? 2.5:1.5; p.stroke()
        }
        let a = -spread+max(0,min(1,value))*spread*2
        let needle=NSBezierPath(); needle.move(to:pivot)
        needle.line(to:NSPoint(x:pivot.x+sin(a)*radius*0.96, y:pivot.y-cos(a)*radius*0.96))
        NSColor(srgbRed:0.10,green:0.10,blue:0.12,alpha:1).setStroke(); needle.lineWidth=2.2; needle.stroke()
        let pa = -spread+max(0,min(1,peak))*spread*2
        let pn=NSBezierPath(); pn.move(to:pivot)
        pn.line(to:NSPoint(x:pivot.x+sin(pa)*radius*0.96, y:pivot.y-cos(pa)*radius*0.96))
        red.withAlphaComponent(0.55).setStroke(); pn.lineWidth=1; pn.stroke()
        NSColor(calibratedWhite:0.1,alpha:1).setFill()
        NSBezierPath(ovalIn:NSRect(x:pivot.x-4,y:pivot.y-4,width:8,height:8)).fill()
        NSAttributedString(string:name, attributes:[.font:NSFont.monospacedSystemFont(ofSize:11,weight:.bold),.foregroundColor:NSColor(calibratedWhite:0.25,alpha:1)]).draw(at:NSPoint(x:g.midX-5,y:g.minY+2))
    }
}

// MARK: - FFT analyser + waveform ring buffer

final class SpectrumAnalyzer {
    let n = 1024
    let bandCount = 56
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private var window: [Float]
    private var realp: [Float]; private var imagp: [Float]
    private var accum: [Float] = []
    private let waveSize = 2048           // power-of-2 for fast modulo
    private var waveBuf: [Float]
    private var wavePos: Int = 0
    private var _energy: Float = 0
    private var _bands:  [Float]
    private var bandRanges: [(Int,Int)] = []
    private let lock = NSLock()

    init() {
        log2n   = vDSP_Length(log2(Float(n)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window   = [Float](repeating:0, count:n); vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        realp    = [Float](repeating:0, count:n/2); imagp = [Float](repeating:0, count:n/2)
        _bands   = [Float](repeating:0, count:bandCount)
        waveBuf  = [Float](repeating:0, count:waveSize)
        let lo=2, hi=n/2-1
        for b in 0..<bandCount {
            let f0=Float(b)/Float(bandCount), f1=Float(b+1)/Float(bandCount)
            let blo=Int(Float(lo)*powf(Float(hi)/Float(lo), f0))
            let bhi=max(blo+1, Int(Float(lo)*powf(Float(hi)/Float(lo), f1)))
            bandRanges.append((blo, min(bhi,hi)))
        }
    }

    func append(_ samples:[Float]) {
        for s in samples { waveBuf[wavePos & (waveSize-1)] = s; wavePos += 1 }
        accum.append(contentsOf:samples)
        if accum.count >= n {
            let frame = Array(accum.suffix(n)); accum.removeAll(keepingCapacity:true); process(frame)
        }
    }

    private func process(_ frame:[Float]) {
        var windowed=[Float](repeating:0,count:n)
        vDSP_vmul(frame,1,window,1,&windowed,1,vDSP_Length(n))
        var rms:Float=0; vDSP_rmsqv(frame,1,&rms,vDSP_Length(n))
        var mags=[Float](repeating:0,count:n/2)
        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split=DSPSplitComplex(realp:rp.baseAddress!, imagp:ip.baseAddress!)
                windowed.withUnsafeBufferPointer { ptr in
                    ptr.baseAddress!.withMemoryRebound(to:DSPComplex.self, capacity:n/2) { cptr in
                        vDSP_ctoz(cptr,2,&split,1,vDSP_Length(n/2))
                    }
                }
                vDSP_fft_zrip(fftSetup,&split,1,log2n,FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split,1,&mags,1,vDSP_Length(n/2))
            }
        }
        var out=[Float](repeating:0,count:bandCount)
        for b in 0..<bandCount {
            let (blo,bhi)=bandRanges[b]; var sum:Float=0
            for i in blo..<bhi { sum+=mags[i] }
            let db=10*log10f(sum/Float(max(1,bhi-blo))+1e-9)-10*log10f(Float(n))
            out[b]=max(0,min(1,(db+70)/70))
        }
        lock.lock(); _bands=out; _energy=_energy*0.7+rms*0.3; lock.unlock()
    }

    func snapshot() -> [Float] { lock.lock(); defer{lock.unlock()}; return _bands }
    func energy()   -> Float   { lock.lock(); defer{lock.unlock()}; return _energy }
    func waveform() -> [Float] {
        lock.lock(); defer{lock.unlock()}
        let s=wavePos & (waveSize-1)
        return s==0 ? waveBuf : Array(waveBuf[s...]+waveBuf[..<s])
    }
    deinit { vDSP_destroy_fftsetup(fftSetup) }
}

// MARK: - Particle

struct Particle {
    var x,y: CGFloat; var vx,vy: CGFloat; var life,size,hue: CGFloat
}

// MARK: - Visualiser view (four styles)

final class VisualiserView: CapturingView {
    var bandsSource:  (()->[Float])?
    var waveSource:   (()->[Float])?
    var energySource: (()->Float)?
    var style: VisualiserStyle = .bars { didSet { particles.removeAll(); rotation=0; beatCooldown=0; needsDisplay=true } }

    private var disp: [CGFloat] = []
    private var rotation: CGFloat = 0
    private var particles: [Particle] = []
    private var beatAvg:      Float = 0
    private var beatCooldown: Int   = 0

    override var isFlipped: Bool { true }

    func tick() {
        guard !isHidden else { return }
        let bands  = bandsSource?()  ?? []
        let energy = energySource?() ?? 0
        if disp.count != bands.count { disp = bands.map{CGFloat($0)} }
        for i in 0..<bands.count {
            let t=CGFloat(bands[i]); disp[i] = t > disp[i] ? t : disp[i]*0.78+t*0.22
        }
        rotation += 0.004
        if style == .particles { tickParticles(energy:energy) }
        needsDisplay = true
    }

    // MARK: Particle physics

    private func tickParticles(energy:Float) {
        beatAvg = beatAvg*0.96+energy*0.04
        let isBeat = beatCooldown==0 && energy > beatAvg*1.7 && energy > 0.04
        if isBeat { emitBurst(count:min(40,Int(energy*80)), energy:energy); beatCooldown=10 }
        if beatCooldown>0 { beatCooldown -= 1 }
        if energy>0.01 { emitBurst(count:max(1,Int(energy*5)), energy:energy*0.4) }
        for i in particles.indices.reversed() {
            particles[i].x  += particles[i].vx
            particles[i].y  += particles[i].vy
            particles[i].vy += 0.08          // gravity (flipped: +y = down)
            particles[i].vx *= 0.99
            particles[i].life -= 0.018
            if particles[i].life <= 0 { particles.remove(at:i) }
        }
        if particles.count > 400 { particles.removeFirst(particles.count-400) }
    }

    private func emitBurst(count:Int, energy:Float) {
        let cx=bounds.midX, cy=bounds.midY
        for _ in 0..<count {
            let angle=CGFloat.random(in:0..<(.pi*2))
            let speed=CGFloat.random(in:1...max(2,CGFloat(energy)*18))
            particles.append(Particle(
                x:cx+CGFloat.random(in:-8...8), y:cy+CGFloat.random(in:-8...8),
                vx:cos(angle)*speed, vy:sin(angle)*speed,
                life:CGFloat.random(in:0.5...1), size:CGFloat.random(in:2...max(3,CGFloat(energy)*8)),
                hue:CGFloat.random(in:0...1)
            ))
        }
    }

    // MARK: Draw dispatch

    override func draw(_ dirtyRect: NSRect) {
        switch style {
        case .bars:         drawBars()
        case .radial:       drawRadial()
        case .waveform:     drawWaveform()
        case .particles:    drawParticles()
        case .circularWave: drawCircularWave()
        case .tunnel:       drawTunnel()
        case .mirror:       drawMirror()
        }
    }

    // MARK: Spectrum Bars

    private func drawBars() {
        guard !disp.isEmpty else { return }
        NSGradient(colors:[NSColor(white:0,alpha:0),NSColor(white:0,alpha:0.45)])!.draw(in:bounds, angle:-90)
        let count=disp.count; let pad:CGFloat=24; let baseY=bounds.height-26; let maxH=bounds.height*0.62
        let gap:CGFloat=3; let barW=(bounds.width-pad*2-gap*CGFloat(count-1))/CGFloat(count)
        let grad=NSGradient(colors:[NSColor(srgbRed:0.20,green:0.78,blue:1.00,alpha:0.95),
                                    NSColor(srgbRed:0.55,green:0.40,blue:1.00,alpha:0.95),
                                    NSColor(srgbRed:1.00,green:0.35,blue:0.70,alpha:0.95)],
                            atLocations:[0,0.55,1], colorSpace:.sRGB)!
        for i in 0..<count {
            let h=max(2,disp[i]*maxH); let x=pad+(barW+gap)*CGFloat(i)
            let bar=NSRect(x:x, y:baseY-h, width:barW, height:h)
            let path=NSBezierPath(roundedRect:bar, xRadius:barW/2, yRadius:barW/2)
            NSGraphicsContext.saveGraphicsState(); path.addClip(); grad.draw(in:bar,angle:90); NSGraphicsContext.restoreGraphicsState()
            let refl=NSRect(x:x, y:baseY+4, width:barW, height:h*0.4)
            let rp=NSBezierPath(roundedRect:refl, xRadius:barW/2, yRadius:barW/2)
            NSGraphicsContext.saveGraphicsState(); rp.addClip(); grad.draw(in:refl,angle:-90)
            NSColor(white:0,alpha:0.5).setFill(); refl.fill(); NSGraphicsContext.restoreGraphicsState()
        }
    }

    // MARK: Radial Spectrum

    private func drawRadial() {
        guard !disp.isEmpty else { return }
        NSGradient(colors:[NSColor(white:0,alpha:0),NSColor(white:0,alpha:0.3)])!.draw(in:bounds, angle:-90)
        let cx=bounds.midX, cy=bounds.midY
        let minDim=min(bounds.width,bounds.height)
        let innerR=minDim*0.13, outerMax=minDim*0.46
        let count=disp.count
        let barW=max(1.5, (2*CGFloat.pi*innerR)/CGFloat(count)*0.7)
        for i in 0..<count {
            let angle=CGFloat(i)/CGFloat(count)*(.pi*2)+rotation - .pi/2
            let barH=max(2, disp[i]*outerMax)
            let x0=cx+cos(angle)*innerR;        let y0=cy+sin(angle)*innerR
            let x1=cx+cos(angle)*(innerR+barH); let y1=cy+sin(angle)*(innerR+barH)
            let hue=0.58+disp[i]*0.42           // blue → magenta
            NSColor(hue:hue, saturation:0.85, brightness:1.0, alpha:0.9).setStroke()
            let p=NSBezierPath(); p.move(to:NSPoint(x:x0,y:y0)); p.line(to:NSPoint(x:x1,y:y1))
            p.lineWidth=barW; p.lineCapStyle = .round; p.stroke()
        }
        let energy=energySource?() ?? 0
        let pulseR=innerR*(0.7+CGFloat(energy)*0.6)
        let circle=NSBezierPath(ovalIn:NSRect(x:cx-pulseR, y:cy-pulseR, width:pulseR*2, height:pulseR*2))
        NSColor(hue:0.62, saturation:0.6, brightness:1, alpha:CGFloat(energy)*0.8+0.1).setFill(); circle.fill()
        NSColor(white:1, alpha:0.35).setStroke(); circle.lineWidth=1.5; circle.stroke()
    }

    // MARK: Waveform Oscilloscope

    private func drawWaveform() {
        let raw=waveSource?() ?? []; guard raw.count > 1 else { return }
        NSGradient(colors:[NSColor(white:0,alpha:0),NSColor(white:0,alpha:0.5)])!.draw(in:bounds, angle:-90)
        let target=min(512,raw.count); let step=raw.count/target
        var samples=[Float](repeating:0, count:target)
        for i in 0..<target { samples[i]=raw[i*step] }
        let midY=bounds.midY; let ampH=bounds.height*0.38
        let passes:[(lw:CGFloat,a:CGFloat)] = [(5,0.18),(2.5,0.45),(1,0.95)]
        for pass in passes {
            let path=NSBezierPath()
            for i in 0..<target {
                let x=bounds.minX+bounds.width*CGFloat(i)/CGFloat(target-1)
                let y=midY+CGFloat(samples[i])*ampH
                if i==0 { path.move(to:NSPoint(x:x,y:y)) } else { path.line(to:NSPoint(x:x,y:y)) }
            }
            NSColor(srgbRed:0.25, green:0.92, blue:1.0, alpha:pass.a).setStroke()
            path.lineWidth=pass.lw; path.lineCapStyle = .round; path.stroke()
        }
        // mirrored reflection
        let reflPath=NSBezierPath()
        for i in 0..<target {
            let x=bounds.minX+bounds.width*CGFloat(i)/CGFloat(target-1)
            let y=midY-CGFloat(samples[i])*ampH*0.45
            if i==0 { reflPath.move(to:NSPoint(x:x,y:y)) } else { reflPath.line(to:NSPoint(x:x,y:y)) }
        }
        NSColor(srgbRed:0.25, green:0.92, blue:1.0, alpha:0.22).setStroke(); reflPath.lineWidth=1; reflPath.stroke()
        let cl=NSBezierPath(); cl.move(to:NSPoint(x:0,y:midY)); cl.line(to:NSPoint(x:bounds.maxX,y:midY))
        NSColor(white:1, alpha:0.06).setStroke(); cl.lineWidth=1; cl.stroke()
    }

    // MARK: Particle Burst

    private func drawParticles() {
        let cx=bounds.midX, cy=bounds.midY
        NSGradient(colors:[NSColor(white:0,alpha:0.1), NSColor(white:0,alpha:0.65)], atLocations:[0,1], colorSpace:.genericGray)!
            .draw(fromCenter:NSPoint(x:cx,y:cy), radius:0, toCenter:NSPoint(x:cx,y:cy),
                  radius:max(bounds.width,bounds.height)/2, options:[])
        for p in particles where p.life > 0 {
            let alpha=p.life*0.88; let r=p.size*(0.4+p.life*0.6)
            let glow=NSBezierPath(ovalIn:NSRect(x:p.x-r*2.5, y:p.y-r*2.5, width:r*5, height:r*5))
            NSColor(hue:p.hue, saturation:0.7, brightness:1, alpha:alpha*0.25).setFill(); glow.fill()
            let core=NSBezierPath(ovalIn:NSRect(x:p.x-r, y:p.y-r, width:r*2, height:r*2))
            NSColor(hue:p.hue, saturation:0.55, brightness:1, alpha:alpha).setFill(); core.fill()
        }
        let energy=energySource?() ?? 0; let er=CGFloat(energy)*80+8
        NSGradient(colors:[NSColor(white:1, alpha:CGFloat(energy)*0.7+0.05), NSColor(white:1,alpha:0)])!
            .draw(fromCenter:NSPoint(x:cx,y:cy), radius:0, toCenter:NSPoint(x:cx,y:cy), radius:er, options:[])
    }

    // MARK: Circular Wave

    private func drawCircularWave() {
        let raw=waveSource?() ?? []; guard raw.count > 1 else { return }
        NSColor(white:0, alpha:0.65).setFill(); bounds.fill()
        let cx=bounds.midX, cy=bounds.midY
        let minDim=min(bounds.width, bounds.height)
        let baseR=minDim*0.28; let ampR=minDim*0.18
        let target=256; let step=max(1, raw.count/target); let count=raw.count/step
        guard count > 2 else { return }
        let energy=CGFloat(energySource?() ?? 0)
        let path=NSBezierPath()
        for i in 0..<count {
            let angle=CGFloat(i)/CGFloat(count) * .pi*2 - .pi/2
            let r=baseR + CGFloat(raw[i*step])*ampR
            let pt=NSPoint(x:cx+cos(angle)*r, y:cy+sin(angle)*r)
            if i==0 { path.move(to:pt) } else { path.line(to:pt) }
        }
        path.close()
        let hue=0.47+energy*0.12
        NSColor(hue:hue, saturation:0.7, brightness:0.8, alpha:0.12).setFill(); path.fill()
        let passes:[(lw:CGFloat,a:CGFloat)]=[(6,0.14),(2.5,0.5),(1,1.0)]
        for pass in passes {
            NSColor(hue:hue, saturation:0.75, brightness:1, alpha:pass.a).setStroke()
            path.lineWidth=pass.lw; path.stroke()
        }
        let glowR=baseR*0.25*(1+energy*2)
        NSGradient(colors:[NSColor(hue:hue, saturation:0.5, brightness:1, alpha:energy*0.7+0.05),
                           NSColor(white:0, alpha:0)])!
            .draw(fromCenter:NSPoint(x:cx,y:cy), radius:0, toCenter:NSPoint(x:cx,y:cy), radius:glowR, options:[])
    }

    // MARK: Tunnel Rings

    private func drawTunnel() {
        let bands=bandsSource?() ?? []; guard !bands.isEmpty else { return }
        let energy=energySource?() ?? 0
        NSColor.black.setFill(); bounds.fill()
        let cx=bounds.midX, cy=bounds.midY
        let maxR=max(bounds.width, bounds.height)*0.65
        let ringCount=18; let phase=fmod(rotation*3, 1.0)
        for i in stride(from:ringCount-1, through:0, by:-1) {
            let t=fmod(CGFloat(i)/CGFloat(ringCount)+phase, 1.0)
            let r=t*maxR
            let bi=min(bands.count-1, Int(t*CGFloat(bands.count)))
            let band=CGFloat(bands[bi])
            let alpha=(1-t*t)*(band*0.7+0.3)*min(1, t*5)*0.9
            let hue=fmod(t*0.45+0.55, 1.0)
            let oval=NSBezierPath(ovalIn:NSRect(x:cx-r, y:cy-r, width:r*2, height:r*2))
            oval.lineWidth=max(0.5, (1-t)*5+band*3)
            NSColor(hue:hue, saturation:0.9, brightness:1, alpha:alpha).setStroke()
            oval.stroke()
        }
        let glowR=maxR*0.07*(1+CGFloat(energy)*4)
        NSGradient(colors:[NSColor(white:1, alpha:CGFloat(energy)*0.9+0.1), NSColor(white:1,alpha:0)])!
            .draw(fromCenter:NSPoint(x:cx,y:cy), radius:0, toCenter:NSPoint(x:cx,y:cy), radius:glowR, options:[])
    }

    // MARK: Mirror Spectrum

    private func drawMirror() {
        guard !disp.isEmpty else { return }
        NSGradient(colors:[NSColor(white:0,alpha:0),NSColor(white:0,alpha:0.5)])!.draw(in:bounds, angle:-90)
        let count=disp.count; let pad:CGFloat=24; let midY=bounds.midY; let maxH=bounds.height*0.44
        let gap:CGFloat=3; let barW=(bounds.width-pad*2-gap*CGFloat(count-1))/CGFloat(count)
        let grad=NSGradient(colors:[NSColor(srgbRed:1.00,green:0.85,blue:0.20,alpha:0.95),
                                    NSColor(srgbRed:1.00,green:0.45,blue:0.10,alpha:0.95),
                                    NSColor(srgbRed:0.90,green:0.10,blue:0.40,alpha:0.95)],
                            atLocations:[0,0.6,1], colorSpace:.sRGB)!
        for i in 0..<count {
            let h=max(2,disp[i]*maxH); let x=pad+(barW+gap)*CGFloat(i)
            let upper=NSRect(x:x, y:midY, width:barW, height:h)
            let up=NSBezierPath(roundedRect:upper, xRadius:barW/2, yRadius:barW/2)
            NSGraphicsContext.saveGraphicsState(); up.addClip()
            grad.draw(in:upper, angle:90); NSGraphicsContext.restoreGraphicsState()
            let lower=NSRect(x:x, y:midY-h, width:barW, height:h)
            let lp=NSBezierPath(roundedRect:lower, xRadius:barW/2, yRadius:barW/2)
            NSGraphicsContext.saveGraphicsState(); lp.addClip()
            grad.draw(in:lower, angle:-90)
            NSColor(white:0,alpha:0.4).setFill(); lower.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        let line=NSBezierPath()
        line.move(to:NSPoint(x:pad, y:midY)); line.line(to:NSPoint(x:bounds.maxX-pad, y:midY))
        NSColor(white:1,alpha:0.12).setStroke(); line.lineWidth=1; line.stroke()
    }
}

// MARK: - System Audio capture (ScreenCaptureKit)

final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    var onBuffer: ((CMSampleBuffer)->Void)?
    private var stream: SCStream?
    private let q = DispatchQueue(label:"net.big0time.recordmonitor.sysaudio")

    func start(completion: @escaping (Bool,String?)->Void) {
        SCShareableContent.getWithCompletionHandler { [weak self] content, error in
            guard let self else { return }
            if let error { DispatchQueue.main.async { completion(false, error.localizedDescription) }; return }
            guard let display=content?.displays.first else { DispatchQueue.main.async { completion(false, "No display found.") }; return }
            let filter=SCContentFilter(display:display, excludingApplications:[], exceptingWindows:[])
            let cfg=SCStreamConfiguration()
            cfg.capturesAudio = true
            cfg.excludesCurrentProcessAudio = false
            cfg.sampleRate = 44100; cfg.channelCount = 2
            cfg.width=2; cfg.height=2
            cfg.minimumFrameInterval=CMTime(value:1, timescale:1)
            let s=SCStream(filter:filter, configuration:cfg, delegate:self)
            do {
                try s.addStreamOutput(self, type:.audio,  sampleHandlerQueue:self.q)
                try s.addStreamOutput(self, type:.screen, sampleHandlerQueue:self.q)
                s.startCapture { err in DispatchQueue.main.async { completion(err==nil, err?.localizedDescription) } }
                self.stream = s
            } catch { DispatchQueue.main.async { completion(false, error.localizedDescription) } }
        }
    }

    func stop() { stream?.stopCapture { _ in }; stream=nil }

    func stream(_ stream:SCStream, didOutputSampleBuffer buf:CMSampleBuffer, of type:SCStreamOutputType) {
        guard type == .audio else { return }
        onBuffer?(buf)
    }
    func stream(_ stream:SCStream, didStopWithError error:Error) {}
}

// MARK: - GitHub Releases self-updater

final class Updater {
    struct Release { let version:String; let zipURL:URL? }
    static func currentVersion()->String { (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0" }
    private static func tuple(_ s:String)->[Int] { s.split{!$0.isNumber}.map{Int($0) ?? 0} }
    static func isNewer(_ a:String, than b:String)->Bool {
        let x=tuple(a),y=tuple(b)
        for i in 0..<max(x.count,y.count) { let p=i<x.count ? x[i]:0, q=i<y.count ? y[i]:0; if p != q { return p>q } }
        return false
    }
    static func fetchLatest(_ done:@escaping(Release?)->Void) {
        guard let url=URL(string:"https://api.github.com/repos/\(kRepoSlug)/releases/latest") else { done(nil); return }
        var req=URLRequest(url:url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField:"Accept")
        req.setValue("RecordMonitor", forHTTPHeaderField:"User-Agent")
        URLSession.shared.dataTask(with:req) { data,_,_ in
            guard let data, let json=try? JSONSerialization.jsonObject(with:data) as? [String:Any], let tag=json["tag_name"] as? String else { DispatchQueue.main.async{done(nil)}; return }
            var zip:URL?
            if let assets=json["assets"] as? [[String:Any]] {
                let zips=assets.filter{($0["name"] as? String)?.lowercased().hasSuffix(".zip")==true}
                let pick=zips.first{a in let n=(a["name"] as? String)?.lowercased() ?? ""; return kArchKeywords.contains{n.contains($0)}} ?? zips.first
                if let s=pick?["browser_download_url"] as? String { zip=URL(string:s) }
            }
            DispatchQueue.main.async{done(Release(version:tag, zipURL:zip))}
        }.resume()
    }
    static func installFromZip(_ zipURL:URL, progress:@escaping(String)->Void) {
        progress("Downloading update…")
        URLSession.shared.downloadTask(with:zipURL) { tmp,_,err in
            guard let tmp, err==nil else { DispatchQueue.main.async{progress("Download failed.")}; return }
            let fm=FileManager.default
            let work=fm.temporaryDirectory.appendingPathComponent("RecordMonitorUpdate-\(UUID().uuidString)")
            do {
                try fm.createDirectory(at:work, withIntermediateDirectories:true)
                let zipPath=work.appendingPathComponent("update.zip"); try fm.moveItem(at:tmp, to:zipPath)
                DispatchQueue.main.async{progress("Unpacking…")}
                let unzip=work.appendingPathComponent("unpacked"); try fm.createDirectory(at:unzip, withIntermediateDirectories:true)
                let p=Process(); p.executableURL=URL(fileURLWithPath:"/usr/bin/ditto"); p.arguments=["-x","-k",zipPath.path,unzip.path]; try p.run(); p.waitUntilExit()
                guard p.terminationStatus==0,
                      let newApp=try? fm.contentsOfDirectory(at:unzip,includingPropertiesForKeys:nil).first(where:{$0.pathExtension=="app"}) else {
                    DispatchQueue.main.async{progress("Could not read downloaded app.")}; return
                }
                DispatchQueue.main.async{progress("Installing… the app will relaunch."); swapAndRelaunch(newApp:newApp)}
            } catch { DispatchQueue.main.async{progress("Update failed: \(error.localizedDescription)")} }
        }.resume()
    }
    private static func swapAndRelaunch(newApp:URL) {
        let dst=Bundle.main.bundlePath; let pid=ProcessInfo.processInfo.processIdentifier
        let script="#!/bin/sh\nwhile kill -0 \(pid) 2>/dev/null; do sleep 0.3; done\nrm -rf \"$1\"\n/usr/bin/ditto \"$2\" \"$1\"\n/usr/bin/xattr -dr com.apple.quarantine \"$1\" 2>/dev/null\nopen \"$1\"\n"
        let sh=FileManager.default.temporaryDirectory.appendingPathComponent("rm-update-\(UUID().uuidString).sh")
        try? script.write(to:sh, atomically:true, encoding:.utf8)
        let p=Process(); p.executableURL=URL(fileURLWithPath:"/bin/sh"); p.arguments=[sh.path,dst,newApp.path]; try? p.run()
        DispatchQueue.main.asyncAfter(deadline:.now()+0.4){NSApp.terminate(nil)}
    }
}

// MARK: - App Controller

final class AppController: NSObject, NSApplicationDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    let session      = AVCaptureSession()
    let audioPreview = AVCaptureAudioPreviewOutput()
    let audioData    = AVCaptureAudioDataOutput()
    private let sessionQueue = DispatchQueue(label:"net.big0time.recordmonitor.session")
    private let meterQueue   = DispatchQueue(label:"net.big0time.recordmonitor.meter")
    private let analyzer     = SpectrumAnalyzer()
    private let sysCapture   = SystemAudioCapture()

    var currentAudioInput: AVCaptureDeviceInput?
    var currentVideoInput: AVCaptureDeviceInput?
    var videoActive    = false
    var sysAudioActive = false
    private var sysDispLevels: [CGFloat] = [0,0]
    private var sysDispPeaks:  [CGFloat] = [0,0]

    var audioDevices: [AVCaptureDevice] = []
    var videoDevices: [AVCaptureDevice] = []

    var window: NSWindow!
    var previewView:    PreviewView!
    var meterView:      MeterView!
    var visualiserView: VisualiserView!
    var audioPopup:     NSPopUpButton!
    var videoPopup:     NSPopUpButton!
    var volumeSlider:   NSSlider!
    var playButton:     NSButton!

    private var meterOverlayItem: NSMenuItem?
    private var visualiserItem:   NSMenuItem?
    private var sysAudioItem:     NSMenuItem?
    private var meterStyleItems: [MeterStyle:      NSMenuItem] = [:]
    private var visStyleItems:   [VisualiserStyle: NSMenuItem] = [:]

    private var meterTimer: Timer?
    private var visTimer:   Timer?
    private var dispLevels: [CGFloat] = [0,0]
    private var dispPeaks:  [CGFloat] = [0,0]

    private var aboutWindow:       NSWindow?
    private var aboutStatus:       NSTextField?
    private var aboutUpdateButton: NSButton?
    private var pendingZip:        URL?

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()
        ensurePermissions { [weak self] in
            self?.buildUI(); self?.buildSession(); self?.startTimers(); self?.observeDisconnect()
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ note: Notification) { sysCapture.stop() }

    func ensurePermissions(_ done: @escaping()->Void) {
        func ask(_ type:AVMediaType, _ next:@escaping()->Void) {
            switch AVCaptureDevice.authorizationStatus(for:type) {
            case .authorized: next()
            case .notDetermined: AVCaptureDevice.requestAccess(for:type){_ in DispatchQueue.main.async{next()}}
            default: next()
            }
        }
        ask(.video){ask(.audio){done()}}
    }

    // MARK: Menus

    func buildMenu() {
        let mainMenu=NSMenu()
        let appItem=NSMenuItem(); mainMenu.addItem(appItem)
        let appMenu=NSMenu()
        appMenu.addItem(withTitle:"About RecordMonitor", action:#selector(showAbout), keyEquivalent:"")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle:"Quit RecordMonitor", action:#selector(NSApplication.terminate(_:)), keyEquivalent:"q")
        appItem.submenu=appMenu

        let viewItem=NSMenuItem(); mainMenu.addItem(viewItem)
        let viewMenu=NSMenu(title:"View")

        let ov=NSMenuItem(title:"Show VU Meter over Video", action:#selector(toggleMeterOverlay), keyEquivalent:"")
        ov.target=self; viewMenu.addItem(ov); meterOverlayItem=ov

        let msItem=NSMenuItem(title:"VU Meter Style", action:nil, keyEquivalent:"")
        let msSub=NSMenu(title:"VU Meter Style")
        for s in MeterStyle.allCases {
            let it=NSMenuItem(title:s.title, action:#selector(pickMeterStyle(_:)), keyEquivalent:"")
            it.target=self; it.tag=s.rawValue; msSub.addItem(it); meterStyleItems[s]=it
        }
        msItem.submenu=msSub; viewMenu.addItem(msItem)

        let vis=NSMenuItem(title:"Show Sound Visualiser", action:#selector(toggleVisualiser), keyEquivalent:"")
        vis.target=self; viewMenu.addItem(vis); visualiserItem=vis

        let vsItem=NSMenuItem(title:"Visualiser Style", action:nil, keyEquivalent:"")
        let vsSub=NSMenu(title:"Visualiser Style")
        for s in VisualiserStyle.allCases {
            let it=NSMenuItem(title:s.title, action:#selector(pickVisStyle(_:)), keyEquivalent:"")
            it.target=self; it.tag=s.rawValue; vsSub.addItem(it); visStyleItems[s]=it
        }
        vsItem.submenu=vsSub; viewMenu.addItem(vsItem)

        viewMenu.addItem(.separator())
        let sa=NSMenuItem(title:"Visualise System Audio", action:#selector(toggleSystemAudio), keyEquivalent:"")
        sa.target=self; viewMenu.addItem(sa); sysAudioItem=sa

        viewItem.submenu=viewMenu
        NSApplication.shared.mainMenu=mainMenu
    }

    func buildContextMenu() -> NSMenu {
        let s=Settings.shared; let m=NSMenu()
        func item(_ title:String,_ sel:Selector,_ on:Bool,tag:Int=0)->NSMenuItem {
            let it=NSMenuItem(title:title,action:sel,keyEquivalent:""); it.target=self; it.state=on ? .on:.off; it.tag=tag; return it
        }
        m.addItem(item("Show VU Meter over Video",#selector(toggleMeterOverlay),s.meterOverlay))
        let msItem=NSMenuItem(title:"VU Meter Style",action:nil,keyEquivalent:""); let msSub=NSMenu()
        for st in MeterStyle.allCases { msSub.addItem(item(st.title,#selector(pickMeterStyle(_:)),s.meterStyle==st,tag:st.rawValue)) }
        msItem.submenu=msSub; m.addItem(msItem)
        m.addItem(item("Show Sound Visualiser",#selector(toggleVisualiser),s.visualiser))
        let vsItem=NSMenuItem(title:"Visualiser Style",action:nil,keyEquivalent:""); let vsSub=NSMenu()
        for st in VisualiserStyle.allCases { vsSub.addItem(item(st.title,#selector(pickVisStyle(_:)),s.visualiserStyle==st,tag:st.rawValue)) }
        vsItem.submenu=vsSub; m.addItem(vsItem)
        m.addItem(.separator())
        m.addItem(item("Visualise System Audio",#selector(toggleSystemAudio),s.systemAudioVis))
        m.addItem(.separator())
        m.addItem(item("About RecordMonitor",#selector(showAbout),false))
        m.addItem(.separator())
        m.addItem(NSMenuItem(title:"Quit RecordMonitor",action:#selector(NSApplication.terminate(_:)),keyEquivalent:""))
        return m
    }

    func updateMenuStates() {
        let s=Settings.shared
        meterOverlayItem?.state = s.meterOverlay    ? .on:.off
        visualiserItem?.state   = s.visualiser       ? .on:.off
        sysAudioItem?.state     = s.systemAudioVis   ? .on:.off
        for (st,it) in meterStyleItems { it.state = s.meterStyle==st      ? .on:.off }
        for (st,it) in visStyleItems   { it.state = s.visualiserStyle==st  ? .on:.off }
    }

    // MARK: UI

    func buildUI() {
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:760,height:560),
                        styleMask:[.titled,.closable,.miniaturizable,.resizable],
                        backing:.buffered, defer:false)
        window.title="RecordMonitor"; window.center()
        let content=CapturingView(frame:window.contentLayoutRect)
        content.contextMenuProvider={[weak self] in self?.buildContextMenu() ?? NSMenu()}
        window.contentView=content

        previewView=PreviewView(frame:.zero); previewView.translatesAutoresizingMaskIntoConstraints=false
        previewView.isHidden=true; content.addSubview(previewView)

        visualiserView=VisualiserView(frame:.zero); visualiserView.translatesAutoresizingMaskIntoConstraints=false
        visualiserView.wantsLayer=true
        visualiserView.bandsSource  = {[weak self] in self?.analyzer.snapshot() ?? []}
        visualiserView.waveSource   = {[weak self] in self?.analyzer.waveform() ?? []}
        visualiserView.energySource = {[weak self] in self?.analyzer.energy() ?? 0}
        visualiserView.style = Settings.shared.visualiserStyle
        content.addSubview(visualiserView)

        meterView=MeterView(frame:.zero); meterView.translatesAutoresizingMaskIntoConstraints=false
        meterView.wantsLayer=true; meterView.style=Settings.shared.meterStyle
        content.addSubview(meterView)

        for v in [previewView,visualiserView,meterView] as [CapturingView] {
            v.contextMenuProvider={[weak self] in self?.buildContextMenu() ?? NSMenu()}
        }

        let bar=CapturingView(); bar.contextMenuProvider={[weak self] in self?.buildContextMenu() ?? NSMenu()}
        bar.translatesAutoresizingMaskIntoConstraints=false; bar.wantsLayer=true
        bar.layer?.backgroundColor=NSColor.controlBackgroundColor.cgColor; content.addSubview(bar)

        audioDevices=audioInputDevices(); videoDevices=videoInputDevices()

        audioPopup=NSPopUpButton(frame:.zero, pullsDown:false)
        audioPopup.addItem(withTitle:"🔊 System Audio")          // index 0 — special
        audioPopup.addItems(withTitles:audioDevices.map{$0.localizedName})
        audioPopup.target=self; audioPopup.action=#selector(audioChanged)

        videoPopup=NSPopUpButton(frame:.zero, pullsDown:false)
        videoPopup.addItem(withTitle:"None")
        videoPopup.addItems(withTitles:videoDevices.map{$0.localizedName})
        videoPopup.target=self; videoPopup.action=#selector(videoChanged)

        volumeSlider=NSSlider(value:1.0,minValue:0,maxValue:1,target:self,action:#selector(volumeChanged))
        volumeSlider.widthAnchor.constraint(equalToConstant:120).isActive=true
        playButton=NSButton(title:"Stop",target:self,action:#selector(togglePlay)); playButton.bezelStyle = .rounded

        func label(_ s:String)->NSTextField {
            let t=NSTextField(labelWithString:s); t.font = .systemFont(ofSize:11); t.textColor = .secondaryLabelColor; return t
        }
        let stack=NSStackView(views:[label("Input"),audioPopup,label("Camera"),videoPopup,label("Vol"),volumeSlider,playButton])
        stack.orientation = .horizontal; stack.spacing=8; stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints=false; bar.addSubview(stack)

        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo:content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo:content.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo:content.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant:52),
            stack.leadingAnchor.constraint(equalTo:bar.leadingAnchor,constant:12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo:bar.trailingAnchor,constant:-12),
            stack.centerYAnchor.constraint(equalTo:bar.centerYAnchor),
        ])
        for v in [previewView!,visualiserView!,meterView!] {
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo:content.leadingAnchor),
                v.trailingAnchor.constraint(equalTo:content.trailingAnchor),
                v.topAnchor.constraint(equalTo:content.topAnchor),
                v.bottomAnchor.constraint(equalTo:bar.topAnchor),
            ])
        }
        applyDisplay()
        window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps:true)
    }

    func applyDisplay() {
        let s=Settings.shared
        if videoActive {
            previewView.isHidden=false; meterView.isOverlay=true; meterView.isHidden = !s.meterOverlay
        } else {
            previewView.isHidden=true; meterView.isOverlay=false; meterView.isHidden=false
        }
        meterView.style=s.meterStyle; meterView.needsDisplay=true
        visualiserView.isHidden = !s.visualiser
        visualiserView.style = s.visualiserStyle
        updateMenuStates()
    }

    // MARK: Session

    func buildSession() {
        sessionQueue.async {
            self.session.beginConfiguration()
            self.audioPreview.volume=Float(self.volumeSlider?.doubleValue ?? 1.0)
            self.audioPreview.outputDeviceUniqueID=nil
            if self.session.canAddOutput(self.audioPreview) { self.session.addOutput(self.audioPreview) }
            self.audioData.setSampleBufferDelegate(self, queue:self.meterQueue)
            if self.session.canAddOutput(self.audioData) { self.session.addOutput(self.audioData) }
            self.session.commitConfiguration()
        }
        DispatchQueue.main.async {
            self.previewView.previewLayer.session=self.session
            // default audio: first matching USB device (audioPopup index 0 = System Audio, so +1)
            if let a=bestMatch(self.audioDevices,["ion","usb"],fallbackExternal:true),
               let i=self.audioDevices.firstIndex(where:{$0.uniqueID==a.uniqueID}) {
                self.audioPopup.selectItem(at:i+1); self.setAudioDevice(a)
            }
            if let v=bestMatch(self.videoDevices,["ziggi","ziggy","ipevo"],fallbackExternal:true),
               let i=self.videoDevices.firstIndex(where:{$0.uniqueID==v.uniqueID}) {
                self.videoPopup.selectItem(at:i+1); self.setVideoDevice(v)
            }
            self.startSession()
        }
    }

    func setAudioDevice(_ device:AVCaptureDevice) {
        stopSystemAudio()
        sessionQueue.async {
            self.session.beginConfiguration()
            if let cur=self.currentAudioInput { self.session.removeInput(cur) }
            if let input=try? AVCaptureDeviceInput(device:device), self.session.canAddInput(input) {
                self.session.addInput(input); self.currentAudioInput=input
            }
            self.session.commitConfiguration()
        }
    }
    func setVideoDevice(_ device:AVCaptureDevice) {
        sessionQueue.async {
            self.session.beginConfiguration()
            if let cur=self.currentVideoInput { self.session.removeInput(cur); self.currentVideoInput=nil }
            var ok=false
            if let input=try? AVCaptureDeviceInput(device:device), self.session.canAddInput(input) {
                self.session.addInput(input); self.currentVideoInput=input; ok=true
            }
            self.session.commitConfiguration()
            DispatchQueue.main.async { self.videoActive=ok; self.applyDisplay() }
        }
    }
    func clearVideoDevice() {
        sessionQueue.async {
            self.session.beginConfiguration()
            if let cur=self.currentVideoInput { self.session.removeInput(cur); self.currentVideoInput=nil }
            self.session.commitConfiguration()
            DispatchQueue.main.async { self.videoActive=false; self.applyDisplay() }
        }
    }
    func startSession() { sessionQueue.async { if !self.session.isRunning { self.session.startRunning() } } }
    func stopSession()  { sessionQueue.async { if  self.session.isRunning { self.session.stopRunning()  } } }

    func observeDisconnect() {
        NotificationCenter.default.addObserver(forName:.AVCaptureDeviceWasDisconnected, object:nil, queue:.main) { [weak self] note in
            guard let self, let dev=note.object as? AVCaptureDevice else { return }
            if dev.uniqueID==self.currentVideoInput?.device.uniqueID { self.videoPopup.selectItem(at:0); self.clearVideoDevice() }
        }
    }

    // MARK: System Audio

    func startSystemAudio() {
        sysCapture.onBuffer={[weak self] buf in self?.processSysAudioBuffer(buf)}
        sysCapture.start { [weak self] ok, errMsg in
            guard let self else { return }
            if ok {
                self.sysAudioActive=true
            } else {
                // revert popup to first real device
                if self.audioDevices.count > 0 { self.audioPopup.selectItem(at:1) }
                let alert=NSAlert()
                alert.messageText="System Audio Unavailable"
                alert.informativeText=errMsg ?? "Grant Screen Recording permission in System Settings → Privacy & Security → Screen Recording, then try again."
                alert.runModal()
            }
        }
    }

    func stopSystemAudio() {
        sysAudioActive=false; sysCapture.stop()
        sysDispLevels=[0,0]; sysDispPeaks=[0,0]
    }

    private func processSysAudioBuffer(_ buf:CMSampleBuffer) {
        guard let mono=monoSamples(from:buf) else { return }
        if Settings.shared.visualiser { analyzer.append(mono) }
        var rms:Float=0; vDSP_rmsqv(mono,1,&rms,vDSP_Length(mono.count))
        let level=CGFloat(min(1.0, rms*5.0))
        DispatchQueue.main.async { [weak self] in
            guard let self, self.sysAudioActive else { return }
            for ch in 0..<self.sysDispLevels.count {
                self.sysDispLevels[ch] = level > self.sysDispLevels[ch] ? level : self.sysDispLevels[ch]*0.80+level*0.20
                self.sysDispPeaks[ch]  = level > self.sysDispPeaks[ch]  ? level : max(level, self.sysDispPeaks[ch]-0.018)
            }
        }
    }

    // MARK: Metering + FFT

    func captureOutput(_ output:AVCaptureOutput, didOutput sampleBuffer:CMSampleBuffer, from connection:AVCaptureConnection) {
        guard Settings.shared.visualiser, !sysAudioActive else { return }
        if let mono=monoSamples(from:sampleBuffer) { analyzer.append(mono) }
    }

    private func monoSamples(from sampleBuffer:CMSampleBuffer) -> [Float]? {
        guard let fmt=CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdP=CMAudioFormatDescriptionGetStreamBasicDescription(fmt) else { return nil }
        let asbd=asbdP.pointee; let ch=max(1,Int(asbd.mChannelsPerFrame)); let bits=Int(asbd.mBitsPerChannel)
        guard bits==16||bits==32 else { return nil }
        let isFloat=(asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let interleaved=(asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        var sizeNeeded=0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer,bufferListSizeNeededOut:&sizeNeeded,bufferListOut:nil,bufferListSize:0,blockBufferAllocator:nil,blockBufferMemoryAllocator:nil,flags:0,blockBufferOut:nil)
        let raw=UnsafeMutableRawPointer.allocate(byteCount:sizeNeeded,alignment:16); defer{raw.deallocate()}
        let ablPtr=raw.assumingMemoryBound(to:AudioBufferList.self); var bb:CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer,bufferListSizeNeededOut:nil,bufferListOut:ablPtr,bufferListSize:sizeNeeded,blockBufferAllocator:nil,blockBufferMemoryAllocator:nil,flags:0,blockBufferOut:&bb)==noErr else { return nil }
        let list=UnsafeMutableAudioBufferListPointer(ablPtr)
        func cvt(_ data:UnsafeMutableRawPointer,count:Int,stride:Int,into mono:inout[Float],add:Bool=false) {
            for f in 0..<count {
                let v:Float = isFloat ? data.assumingMemoryBound(to:Float.self)[f*stride]
                    : bits==16 ? Float(data.assumingMemoryBound(to:Int16.self)[f*stride])/32768
                    : Float(data.assumingMemoryBound(to:Int32.self)[f*stride])/2147483648
                if add { mono[f]+=v } else { mono[f]=v }
            }
        }
        if interleaved {
            guard let buf=list.first, let data=buf.mData else { return nil }
            let frames=Int(buf.mDataByteSize)/(bits/8)/ch; var mono=[Float](repeating:0,count:frames)
            for c in 0..<ch { cvt(data.advanced(by:c*(bits/8)),count:frames,stride:ch,into:&mono,add:true) }
            let inv=1.0/Float(ch); for f in 0..<frames { mono[f]*=inv }; return mono
        } else {
            let frames=Int(list[0].mDataByteSize)/(bits/8); var mono=[Float](repeating:0,count:frames)
            for c in 0..<min(ch,list.count) { if let data=list[c].mData { cvt(data,count:frames,stride:1,into:&mono,add:true) } }
            let inv=1.0/Float(max(1,min(ch,list.count))); for f in 0..<frames { mono[f]*=inv }; return mono
        }
    }

    func startTimers() {
        meterTimer=Timer.scheduledTimer(withTimeInterval:1.0/30, repeats:true){[weak self] _ in self?.tickMeter()}
        visTimer   = Timer.scheduledTimer(withTimeInterval:1.0/60, repeats:true){[weak self] _ in self?.visualiserView?.tick()}
    }

    private func norm(_ db:Float)->CGFloat { CGFloat((max(-60,min(0,db))+60)/60) }

    private func tickMeter() {
        if sysAudioActive {
            dispLevels=sysDispLevels; dispPeaks=sysDispPeaks
        } else {
            let channels=audioData.connection(with:.audio)?.audioChannels ?? []
            let n=max(2,channels.count)
            if dispLevels.count != n { dispLevels=Array(repeating:0,count:n); dispPeaks=Array(repeating:0,count:n) }
            for ch in 0..<n {
                let target:CGFloat=ch<channels.count ? norm(channels[ch].averagePowerLevel):0
                dispLevels[ch]=target>dispLevels[ch] ? target : dispLevels[ch]*0.80+target*0.20
                dispPeaks[ch]  = target>dispPeaks[ch]  ? target : max(target,dispPeaks[ch]-0.018)
            }
        }
        if !meterView.isHidden { meterView.update(levels:dispLevels, peaks:dispPeaks) }
    }

    // MARK: Display actions

    @objc func toggleMeterOverlay() { Settings.shared.meterOverlay.toggle();    applyDisplay() }
    @objc func toggleVisualiser()   { Settings.shared.visualiser.toggle();      applyDisplay() }
    @objc func pickMeterStyle(_ sender:NSMenuItem) { if let s=MeterStyle(rawValue:sender.tag)      { Settings.shared.meterStyle=s;      applyDisplay() } }
    @objc func pickVisStyle(_ sender:NSMenuItem)   { if let s=VisualiserStyle(rawValue:sender.tag) { Settings.shared.visualiserStyle=s; applyDisplay() } }

    @objc func toggleSystemAudio() {
        Settings.shared.systemAudioVis.toggle()
        if Settings.shared.systemAudioVis { startSystemAudio() } else { stopSystemAudio() }
        updateMenuStates()
    }

    // MARK: Device actions

    @objc func audioChanged() {
        let i=audioPopup.indexOfSelectedItem
        if i==0 { startSystemAudio(); return }     // "System Audio" entry
        stopSystemAudio()
        let di=i-1; guard audioDevices.indices.contains(di) else { return }
        setAudioDevice(audioDevices[di])
    }
    @objc func videoChanged() {
        let i=videoPopup.indexOfSelectedItem
        if i==0 { clearVideoDevice(); return }
        let di=i-1; guard videoDevices.indices.contains(di) else { return }
        setVideoDevice(videoDevices[di])
    }
    @objc func volumeChanged() { audioPreview.volume=Float(volumeSlider.doubleValue) }
    @objc func togglePlay() {
        if session.isRunning { stopSession(); playButton.title="Play" }
        else { startSession(); playButton.title="Stop" }
    }

    // MARK: About + updates

    @objc func showAbout() {
        if aboutWindow==nil { aboutWindow=makeAboutWindow() }
        aboutWindow?.center(); aboutWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
    }
    private func makeAboutWindow()->NSWindow {
        let w=NSWindow(contentRect:NSRect(x:0,y:0,width:360,height:320),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        w.title="About RecordMonitor"; w.isReleasedWhenClosed=false
        let c=NSView(frame:.zero); w.contentView=c
        let icon=NSImageView(image:NSApp.applicationIconImage); icon.imageScaling = .scaleProportionallyUpOrDown
        let name=NSTextField(labelWithString:"RecordMonitor"); name.font = .systemFont(ofSize:20,weight:.semibold); name.alignment = .center
        let ver=NSTextField(labelWithString:"Version \(Updater.currentVersion())"); ver.font = .systemFont(ofSize:12); ver.textColor = .secondaryLabelColor; ver.alignment = .center
        let link=NSButton(title:kRepoSlug,target:self,action:#selector(openRepo)); link.isBordered=false
        link.attributedTitle=NSAttributedString(string:kRepoSlug,attributes:[.foregroundColor:NSColor.linkColor,.underlineStyle:NSUnderlineStyle.single.rawValue,.font:NSFont.systemFont(ofSize:12)])
        let status=NSTextField(labelWithString:" "); status.font = .systemFont(ofSize:11); status.textColor = .secondaryLabelColor; status.alignment = .center; status.lineBreakMode = .byWordWrapping; status.maximumNumberOfLines=2; aboutStatus=status
        let update=NSButton(title:"Check for Updates",target:self,action:#selector(checkForUpdates)); update.bezelStyle = .rounded; aboutUpdateButton=update
        let copyright=NSTextField(labelWithString:"net.big0time.recordmonitor"); copyright.font = .systemFont(ofSize:10); copyright.textColor = .tertiaryLabelColor; copyright.alignment = .center
        let stack=NSStackView(views:[icon,name,ver,link,update,status,copyright])
        stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing=10; stack.translatesAutoresizingMaskIntoConstraints=false; c.addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant:96), icon.heightAnchor.constraint(equalToConstant:96),
            stack.centerXAnchor.constraint(equalTo:c.centerXAnchor), stack.topAnchor.constraint(equalTo:c.topAnchor,constant:24),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo:c.leadingAnchor,constant:20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo:c.trailingAnchor,constant:-20),
        ])
        return w
    }
    @objc func openRepo() { if let u=URL(string:kRepoURL) { NSWorkspace.shared.open(u) } }
    @objc func checkForUpdates() {
        aboutUpdateButton?.isEnabled=false; aboutStatus?.stringValue="Checking for updates…"
        Updater.fetchLatest { [weak self] release in
            guard let self else { return }
            guard let release else { self.aboutStatus?.stringValue="Couldn't reach GitHub."; self.aboutUpdateButton?.isEnabled=true; return }
            let cur=Updater.currentVersion()
            if Updater.isNewer(release.version,than:cur) {
                if let zip=release.zipURL {
                    self.aboutStatus?.stringValue="Update \(release.version) available."
                    self.aboutUpdateButton?.title="Install \(release.version)"; self.aboutUpdateButton?.isEnabled=true
                    self.aboutUpdateButton?.target=self; self.aboutUpdateButton?.action=#selector(self.installUpdate)
                    self.pendingZip=zip
                } else {
                    self.aboutStatus?.stringValue="\(release.version) available — opening releases page."; self.aboutUpdateButton?.isEnabled=true
                    if let u=URL(string:"\(kRepoURL)/releases/latest") { NSWorkspace.shared.open(u) }
                }
            } else { self.aboutStatus?.stringValue="You're on the latest version (\(cur))."; self.aboutUpdateButton?.isEnabled=true }
        }
    }
    @objc func installUpdate() {
        guard let zip=pendingZip else { return }
        aboutUpdateButton?.isEnabled=false
        Updater.installFromZip(zip){[weak self] msg in self?.aboutStatus?.stringValue=msg}
    }
}

let app=NSApplication.shared
let delegate=AppController()
app.delegate=delegate
app.setActivationPolicy(.regular)
app.run()
