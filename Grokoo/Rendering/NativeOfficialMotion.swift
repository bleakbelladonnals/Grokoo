import CoreGraphics
import Foundation

private struct NativeSpring {
    var p: Double; var v: Double = 0; var target: Double
    init(_ value: Double) { p = value; target = value }
    mutating func advance(speed: Double, damping: Double, dt: Double) {
        v += (-2*damping*speed*v - speed*speed*(p-target))*dt
        p += v*dt
    }
}
private struct NativeEyeMetrics {
    var cx: Double; var cy: Double; var angle: Double; var length: Double; var width: Double
    init(_ points: [CGPoint]) {
        cx = points.reduce(0) { $0+$1.x }/Double(points.count)
        cy = points.reduce(0) { $0+$1.y }/Double(points.count)
        var xx=0.0, yy=0.0, xy=0.0
        for p in points { xx += pow(p.x-cx,2); yy += pow(p.y-cy,2); xy += (p.x-cx)*(p.y-cy) }
        let eigen = (xx+yy+hypot(xx-yy,2*xy))/2
        var ux=eigen-yy, uy=xy
        let normal=hypot(ux,uy)
        ux /= normal == 0 ? 1 : normal; uy /= normal == 0 ? 1 : normal
        if uy < 0 || (uy == 0 && ux < 0) { ux = -ux; uy = -uy }
        angle=atan2(uy,ux); length=0; width=0
        for p in points {
            length=max(length,abs((p.x-cx)*ux+(p.y-cy)*uy))
            width=max(width,abs(-(p.x-cx)*uy+(p.y-cy)*ux))
        }
    }
    func capsule(count: Int = 48) -> [CGPoint] {
        let ux=cos(angle), uy=sin(angle), straight=max(0,length-width)
        return (0..<count).map { index in
            let a=Double(index)/Double(count)*nativeTau, dx=cos(a), dy=sin(a)
            let along=dx*ux+dy*uy, across = -dx*uy+dy*ux
            let edge=width/max(abs(across),0.000001)
            let end=(along >= 0 ? 1.0 : -1.0)*straight*along
            let radius = edge*abs(along) <= straight+0.000001 && edge.isFinite ? edge : end+sqrt(max(0,end*end-straight*straight+width*width))
            return CGPoint(x:cx+radius*dx,y:cy+radius*dy)
        }
    }
}
private func nativeShortAngle(_ value: Double) -> Double {
    var value=value
    while value > .pi/2 { value -= .pi }
    while value < -.pi/2 { value += .pi }
    return value
}
private func nativeInterpolateEye(_ a:[CGPoint], _ b:[CGPoint], _ progress: Double) -> [CGPoint] {
    let t=nativeClamp(progress)
    if t == 0 { return a }; if t == 1 { return b }
    let am=NativeEyeMetrics(a), bm=NativeEyeMetrics(b)
    var result=am
    result.cx += (bm.cx-am.cx)*t; result.cy += (bm.cy-am.cy)*t
    result.angle += nativeShortAngle(bm.angle-am.angle)*t
    result.width=max(0.35,am.width+(bm.width-am.width)*t)
    result.length=max(0,am.length-am.width)*(1-t)+max(0,bm.length-bm.width)*t+result.width
    return result.capsule(count:a.count)
}
private func nativeEyeContour(_ id: Int) -> [[CGPoint]] {
    NativeGeometryCatalog.shared.eyeContours[String(id)]!.map { $0.map { CGPoint(x:$0[0],y:$0[1]) } }
}
private func nativeWorkingEyes(_ id: Int) -> [[CGPoint]] {
    var result=nativeEyeContour(id)
    if id == 7 || id == 16 {
        let targets=result.map(NativeEyeMetrics.init), home=nativeEyeContour(0).map(NativeEyeMetrics.init)
        let average=(nativeShortAngle(targets[0].angle-home[0].angle)+nativeShortAngle(targets[1].angle-home[1].angle))/2
        for index in 0..<2 {
            let m=targets[index], rot=nativeShortAngle(home[index].angle+average-m.angle), c=cos(rot), s=sin(rot)
            result[index]=result[index].map { CGPoint(x:m.cx+($0.x-m.cx)*c-($0.y-m.cy)*s,y:m.cy+($0.x-m.cx)*s+($0.y-m.cy)*c) }
        }
    }
    for index in 0..<2 {
        let m=NativeEyeMetrics(result[index]), home=NativeEyeMetrics(nativeEyeContour(0)[index])
        let scale=min(1,1.05/max(m.length/home.length,m.width/home.width))
        result[index]=result[index].map { CGPoint(x:m.cx+($0.x-m.cx)*scale,y:m.cy+($0.y-m.cy)*scale) }
    }
    let left=NativeEyeMetrics(result[0]); var right=NativeEyeMetrics(result[1])
    right.length=left.length; right.width=left.width; result[1]=right.capsule()
    return result
}

private struct NativeWildPose {
    var angle:Double; var roll:Double; var x:Double; var y:Double
    var eyeX:Double; var eyeY:Double; var lid:Double; var eyeScale:Double
    init(time t:Double, direction dir:Double) {
        let cruise=(9*nativeTau+0.5)/(0.15+2+0.3125)
        let turn:Double
        if t < 0.24 { turn = -0.25*(1-cos(t/0.24 * .pi)) }
        else if t < 0.54 { turn = -0.5+cruise*pow(t-0.24,2)/0.6 }
        else if t < 2.54 { turn = -0.5+cruise*(0.15+t-0.54) }
        else if t < 3.79 { turn = -0.5+cruise*2.15+1.25*cruise*(1-pow(1-(t-2.54)/1.25,4))/4 }
        else { turn=9*nativeTau }
        let afterBrake=max(t-2.54,0)
        var recovery=0.0
        if t > 2.54 {
            let u=min((t-2.54)/1.25,1)
            recovery=u < 0.4 ? 0 : pow((u-0.4)/0.6,2)
            if t >= 3.79 { recovery=pow(max(0,1-(t-3.79)/1.7),1.6) }
        }
        angle=turn*dir
        roll=turn/(9*nativeTau)*1080*dir+11*sin(9.2*afterBrake)*dir*recovery
        x=(cos(9.2*afterBrake)-1)*6*dir*recovery; y=2.6*sin(18.4*afterBrake)*recovery
        eyeX=13*sin(11.5*afterBrake)*dir*recovery; eyeY=(cos(9*afterBrake)-1)*3.5*recovery
        lid=1.14-0.44*recovery+0.1*sin(16*afterBrake)*recovery; eyeScale=1.12-0.09*recovery
    }
}

final class NativeOfficialMotionClock {
    let state: PresenceState
    let shape: OfficialShape
    let geometry: NativeMotionGeometry
    private let random=NativeSeededRandom()
    private let trails: NativeTrailSystem
    private var bodyRoll=NativeSpring(0), bodyX=NativeSpring(0), bodyY=NativeSpring(0), bodyScale=NativeSpring(1)
    private var lid=NativeSpring(1), eyeSize=NativeSpring(1), gazeX=NativeSpring(0), gazeY=NativeSpring(0), morph=NativeSpring(0)
    private var eyeFrom=nativeEyeContour(0), eyeTo=nativeEyeContour(0)
    private var expressionIndex=0, expressionID=0, morphSpeed=8.0
    private(set) var time=0.0
    private var frame=0, first=true
    private var gazeAt=0.0, expressionAt=0.0, blinkAt=0.0, spinAt=0.0, rareAt=0.0
    private var spin:NativeSpring?, wildStart:Double?, wildDir=1.0, pose:NativeWildPose?
    private var eyeSpin:Double?, trailAngle=0.0
    private var blinkQueue:[(at:Double,value:Double)]=[]
    private let baselineSolids:[Double]?
    private var expressions:[Int] { state == .working ? [7,16,11,10] : [2,8,17] }
    private var expressionRange:(Double,Double) { state == .working ? (1.8,3.2) : (1.4,2.6) }

    init(state:PresenceState, shape:OfficialShape) {
        self.state=state; self.shape=shape; geometry=NativeGeometryCatalog.shared.motion[shape.rawValue]!
        baselineSolids=geometry.solid.map { Self.solidRadii($0,angle:0) }
        // PRNG order mirrors the handoff, including consumed-but-unused values.
        rareAt=random.range(2.5,5)
        trails=NativeTrailSystem(random:random,radius:geometry.beltRadius,sizeScale:pow(340.0/128,0.7))
        _=random.range(0,5)
        expressionAt=random.range(expressionRange.0,expressionRange.1)
        blinkAt=random.range(1.5,7)
        spinAt=state == .working ? random.range(1.2,2.4) : random.range(6,10)
        _=random.range(0.5,1.2); _=random.range(1.2,2.2)
        gazeAt=random.range(0.5,1.4); _=random.range(3,8)
        if state == .done { spinAt=0.14 }
        blink(0); setExpression(expressions[0],speed:8)
    }
    private func blink(_ t:Double) {
        blinkQueue += [(t,0.05),(t+0.07,0.05),(t+0.15,1.08),(t+0.3,1)]
        if random.next() < 0.14 { blinkQueue += [(t+0.37,0.05),(t+0.48,1)] }
    }
    private func setExpression(_ id:Int,speed:Double) {
        if id == expressionID && morph.target == 1 { return }
        eyeFrom=(0..<2).map { nativeInterpolateEye(eyeFrom[$0],eyeTo[$0],morph.p) }
        eyeTo=state == .working ? nativeWorkingEyes(id) : nativeEyeContour(id)
        expressionID=id; morph=NativeSpring(0); morph.target=1; morphSpeed=speed
    }
    func advance(to time:Double) {
        let target=max(0,Int(floor(time*60+0.000001)))
        while frame <= target { advance(time:Double(frame)/60,dt:first ? 0 : 1.0/60); first=false; frame += 1 }
    }
    private func advance(time t:Double,dt:Double) {
        time=t
        if state == .done && wildStart == nil && t+0.000000001 >= spinAt {
            wildDir=random.next() < 0.5 ? 1 : -1; wildStart=t; spinAt=t+6.2
        }
        if t+0.000000001 >= rareAt { rareAt=t+random.range(9,18) }
        var lidTarget=1.0, sizeTarget=1.0
        if state == .working {
            let pulse=sin(t * .pi * 3.2)
            bodyRoll.target=4+2.5*pulse; bodyX.target=3; bodyY.target=1.5+3*max(0,pulse); bodyScale.target=1-0.02*max(0,pulse)
            if t+0.000000001 >= spinAt {
                if spin == nil { spin=NativeSpring(0); spin!.target=nativeTau }
                spinAt=t+random.range(6,9)
            }
        } else {
            bodyRoll.target=0; bodyX.target=0; bodyY.target = -2.5*abs(sin(1.6*t)); bodyScale.target=1; lidTarget=1.1; sizeTarget=1.1
        }
        if t+0.000000001 >= gazeAt {
            gazeX.target=random.range(-6,6)
            gazeY.target=state == .working ? random.range(3.6,9) : random.range(-2.7,2.7)
            gazeAt=t+(state == .working ? random.range(1.2,2.4) : random.range(2.5,5))
        }
        pose=nil
        if let start=wildStart {
            let age=t-start
            if age < 5.49 { pose=NativeWildPose(time:age,direction:wildDir); lidTarget=pose!.lid; sizeTarget=pose!.eyeScale }
            else { wildStart=nil }
        }
        if t+0.000000001 >= expressionAt {
            expressionIndex=(expressionIndex+1+Int(floor(random.range(0,Double(expressions.count-1))))) % expressions.count
            setExpression(expressions[expressionIndex],speed:6)
            expressionAt=t+random.range(expressionRange.0,expressionRange.1)
        }
        if t+0.000000001 >= blinkAt {
            blink(t); blinkAt=t+(state == .working ? random.range(2.8,5.5) : random.range(2.2,4.5))
        }
        var queued:Double?
        while let event=blinkQueue.first, t+0.000000001 >= event.at { queued=blinkQueue.removeFirst().value }
        lid.target=queued ?? (blinkQueue.isEmpty ? lidTarget : lid.target)
        if state == .working { sizeTarget *= 1+0.14*nativeSmooth((-gazeX.p-0.5)/4.5)*nativeSmooth((gazeY.p-3)/6) }
        eyeSize.target=sizeTarget
        for _ in 0..<2 {
            let h=dt/2
            morph.advance(speed:morphSpeed,damping:1,dt:h); spin?.advance(speed:6.2,damping:1,dt:h)
            bodyRoll.advance(speed:5,damping:0.9,dt:h); bodyX.advance(speed:3.5,damping:1,dt:h)
            bodyY.advance(speed:4,damping:1,dt:h); bodyScale.advance(speed:10,damping:0.8,dt:h)
            lid.advance(speed:26,damping:1,dt:h); eyeSize.advance(speed:9,damping:0.85,dt:h)
            gazeX.advance(speed:13,damping:1,dt:h); gazeY.advance(speed:13,damping:1,dt:h)
        }
        if let current=spin, abs(current.target-current.p) < 0.004 && abs(current.v) < 0.015 { spin=nil }
        eyeSpin=spin?.p ?? pose?.angle
        if let eyeSpin { trailAngle=eyeSpin }
        trails.advance(time:t,dt:dt,spinAngle:trailAngle,wide:wildStart != nil)
    }

    func render(basePath:CGPath) -> NativeMotionFrame {
        let points=turnedBody()
        let outline=geometry.solid != nil && eyeSpin != nil ? nativePolygon(points,curved:true) : basePath
        let spinningRoll=(pose?.angle ?? 0)/(9*nativeTau)*1080
        let recoveryRoll=(pose?.roll ?? 0)-spinningRoll
        let roll=(bodyRoll.p+recoveryRoll)*geometry.tiltScale+spinningRoll
        // Center-relative output; both eyes and silhouette receive precisely the same pose.
        let transform=CGAffineTransform(translationX:nativeRound(nativeCenter+bodyX.p+(pose?.x ?? 0),digits:1000)-nativeCenter,
                                        y:nativeRound(nativeCenter+bodyY.p+(pose?.y ?? 0),digits:1000)-nativeCenter)
            .rotated(by:nativeRound(roll,digits:1000) * .pi/180)
            .scaledBy(x:1,y:nativeRound(bodyScale.p,digits:1000)).translatedBy(x:-nativeCenter,y:-nativeCenter)
        let ribbons=trails.render()
        return NativeMotionFrame(bodyPath:nativeTransform(outline,transform),
            eyes:renderEyes(points:points).map { NativePaintPath(path:nativeTransform($0,transform)) },
            backRibbons:ribbons.back,frontRibbons:ribbons.front,sampleTime:time,surfaceTurn:eyeSpin ?? 0,doneActionActive:pose != nil)
    }
    private static func solidRadii(_ solids:[[Double]],angle:Double) -> [Double] {
        let c=cos(angle),s=sin(angle)
        let radii=(0..<96).map { index -> Double in
            let a=Double(index)/96*nativeTau,dx=cos(a),dy=sin(a)
            var outer=0.0
            for solid in solids {
                let rx=solid[0]*c+solid[2]*s, along=dx*rx+dy*solid[1]
                let disc=along*along-rx*rx-solid[1]*solid[1]+solid[3]*solid[3]
                if disc > 0 { outer=max(outer,along+sqrt(disc)) }
            }
            return outer
        }
        return smoothRadii(radii)
    }
    private static func smoothRadii(_ values:[Double]) -> [Double] {
        (0..<96).map { i in
            let outer = values[(i+94)%96] + values[(i+2)%96]
            let inner = 4 * values[(i+95)%96] + 4 * values[(i+1)%96]
            return (outer + inner + 6 * values[i]) / 16
        }
    }
    private func turnedBody() -> [CGPoint] {
        let points=geometry.ring.map { CGPoint(x:$0[0],y:$0[1]) }
        guard let solids=geometry.solid, let eyeSpin, let baselineSolids else { return points }
        var factors=Self.solidRadii(solids,angle:eyeSpin).enumerated().map { nativeClamp(($0.element+12)/(baselineSolids[$0.offset]+12),0.32,1.5) }
        for _ in 0..<3 { factors=Self.smoothRadii(factors) }
        return points.enumerated().map { CGPoint(x:nativeCenter+($0.element.x-nativeCenter)*factors[$0.offset],y:$0.element.y) }
    }
    private func horizontalSpan(_ points:[CGPoint],y:Double) -> (Double,Double) {
        var left = -Double.infinity, right=Double.infinity
        for index in points.indices {
            let a=points[index],b=points[(index+1)%points.count]
            if (a.y <= y) == (b.y <= y) { continue }
            let x=a.x+(b.x-a.x)*(y-a.y)/(b.y-a.y)
            if x <= nativeCenter { left=max(left,x) } else { right=min(right,x) }
        }
        return (left.isFinite ? left : nativeCenter,right.isFinite ? right : nativeCenter)
    }
    private func renderEyes(points:[CGPoint]) -> [CGPath] {
        let face=geometry.face, done=state == .done, t=time
        let growth=nativeClamp(t/0.28), blend=pow(growth,3)*(growth*(6*growth-15)+10)
        let gap=done ? 1+0.18*blend : 1, eyeWidth=done ? 1.2+(0.84-1.2)*blend : 1.2
        let eyeHeight=done ? 1.16+(0.84-1.16)*blend : 1.16
        let faceSX=face.sx*gap,faceSY=face.sy,faceEye=face.eye*(done ? 1-0.26*blend : 1)
        let pair=(0..<2).map { nativeInterpolateEye(eyeFrom[$0],eyeTo[$0],morph.p) }, stats=pair.map(NativeEyeMetrics.init)
        let widths=(0..<2).map { index in pair[index].map { abs($0.x-stats[index].cx) }.max()! }
        let minimumGap=nativeClamp((abs(stats[1].cx-stats[0].cx)*faceSX-5)/(widths[0]+widths[1]),0.35,4)
        let morphPop=1+0.07*sin(nativeClamp(morph.p) * .pi)
        let size=min(nativeClamp(eyeSize.p,0.2,2)*faceEye,minimumGap/morphPop)
        let top=points.map(\.y).min()!,bottom=points.map(\.y).max()!
        var compensation=[0.0,0.0]
        if state == .working, let eyeSpin, [.pebble,.tablet,.cloud].contains(shape) {
            let positions=stats.map { m -> (Double,Bool) in
                let y=nativeClamp(nativeCenter+face.y+(m.cy-nativeCenter)*faceSY,top+2,bottom-2)
                let (left,right)=horizontalSpan(points,y:y), radius=max((right-left)/2,12)
                let angle=asin(nativeClamp((m.cx-nativeCenter)*faceSX/radius,-1,1))+eyeSpin
                return ((left+right)/2+radius*sin(angle),cos(angle)>0.02)
            }
            let normalGap=abs(stats[1].cx-stats[0].cx)*faceSX,projectedGap=positions[1].0-positions[0].0
            if positions.allSatisfy({$0.1}) && projectedGap < normalGap { compensation=[-(normalGap-projectedGap)/2,(normalGap-projectedGap)/2] }
        }
        var output:[CGPath]=[]
        for index in 0..<2 {
            let metrics=stats[index],base=pair[index], lid=max(self.lid.p,0.04),ux=cos(metrics.angle),uy=sin(metrics.angle)
            let contour=base.map { p -> CGPoint in
                let along=(p.x-metrics.cx)*ux+(p.y-metrics.cy)*uy
                return CGPoint(x:p.x-along*(1-lid)*ux,y:p.y-along*(1-lid)*uy)
            }
            var offsetX=(metrics.cx-nativeCenter)*faceSX
            var centerY=nativeClamp(nativeCenter+face.y+(metrics.cy-nativeCenter)*faceSY,top+2,bottom-2)
            var centerX=nativeCenter+face.x,perspective=1.0,inside=1.0
            if let eyeSpin {
                let (left,right)=horizontalSpan(points,y:centerY),radius=max((right-left)/2,12)
                let initial=asin(nativeClamp(offsetX/radius,-1,1)),angle=initial+eyeSpin,depth=cos(angle)
                if depth <= 0.02 { continue }
                centerX=(left+right)/2; offsetX=radius*sin(angle)
                perspective=max(depth,0.02)/max(cos(initial),0.02); inside=nativeSmooth(depth/0.5)
            }
            let swayX=1.4*sin(0.42*t+Double(index))+0.5*sin(t+2*Double(index))+gazeX.p+(pose?.eyeX ?? 0)
            let swayY=0.9*sin(0.58*t+Double(index))+gazeY.p+(pose?.eyeY ?? 0)
            let sizeX=nativeClamp(perspective*min(size*eyeWidth,minimumGap/morphPop)*morphPop,0.02,2.4)
            let sizeY=nativeClamp(size*eyeHeight*morphPop,0.02,2.4), border=21*sizeY+2
            centerY=nativeClamp(centerY+swayY*faceSY,top+border,bottom-border)
            var allowedLeft = -Double.infinity,allowedRight=Double.infinity
            for i in stride(from:0,to:contour.count,by:2) {
                let x=(contour[i].x-metrics.cx)*sizeX
                let (left,right)=horizontalSpan(points,y:centerY+(contour[i].y-metrics.cy)*sizeY)
                allowedLeft=max(allowedLeft,left-x); allowedRight=min(allowedRight,right-x)
            }
            let desiredX=centerX+offsetX+compensation[index]+swayX*faceSX
            let fittedX=allowedLeft <= allowedRight ? nativeClamp(desiredX,allowedLeft,allowedRight) : (allowedLeft+allowedRight)/2
            let finalX=fittedX+(desiredX-fittedX)*(1-inside)
            let matrix=CGAffineTransform(translationX:nativeRound(finalX,digits:1000),y:nativeRound(centerY,digits:1000))
                .scaledBy(x:nativeRound(sizeX,digits:1000),y:nativeRound(sizeY,digits:1000))
                .translatedBy(x:-nativeRound(metrics.cx,digits:1000),y:-nativeRound(metrics.cy,digits:1000))
            output.append(nativeTransform(nativePolygon(contour),matrix))
        }
        return output
    }
}
