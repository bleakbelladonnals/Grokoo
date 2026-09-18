import CoreGraphics
import Foundation

/// Native geometry port of official-trails.ts. History is live orbital geometry,
/// split at z=0; it is neither a frame cache nor a prerecorded path sequence.
final class NativeTrailSystem {
    private struct Point { var x:Double; var y:Double; var z:Double; var angle:Double }
    private struct Plane { var tilt:Double; var roll:Double }
    private struct Ribbon {
        var age=0.0, retreat=0.0
        var thickness:Double; var hue:Double; var hueSpan:Double; var hueVelocity:Double
        var angle:Double; var angularVelocity:Double; var tilt:Double; var roll:Double
        var radius:Double; var radialVelocity:Double; var follow:Double
        var carry=0.0; var arc:Double; var history:[Point]=[]; var width=0.0,opacity=0.0
    }
    private let random:NativeSeededRandom
    private let radius:Double, sizeScale:Double
    private var previousAngle=0.0,velocity=0.0,emitted=false
    private var pending:[(at:Double,index:Int)]=[], ribbons:[Ribbon]=[], planes:[Plane]=[]
    private var count=4,baseHue=0.0
    init(random:NativeSeededRandom,radius:Double,sizeScale:Double) {
        self.random=random; self.radius=radius; self.sizeScale=sizeScale
        _=random.range(0,nativeTau)
    }
    private func configure(wide:Bool) {
        let planeCount=wide ? 3 : 1,baseRoll=random.range(-0.85,0.85)
        planes=(0..<planeCount).map { i in Plane(tilt:random.range(0.16,0.5),roll:baseRoll+Double(i) * .pi/Double(planeCount)+random.range(-0.12,0.12)) }
        count=wide ? 9 : Int(floor(random.range(3,5)+0.5)); baseHue=random.range(0,360)
    }
    private func spawn(angle:Double,direction:Double,index:Int) {
        if ribbons.count > 110 { return }
        if planes.isEmpty { configure(wide:false) }
        let plane=planes[index % planes.count]
        let thickness=count <= 3 ? random.range(8,10.5) : count == 4 ? random.range(6.6,8.6) : random.range(5.6,7.4)
        _=random.range(0,360); _=random.range(-240,240); _=random.next()
        let hue=baseHue+360*Double(index)/Double(max(count,1))+random.range(-14,14)
        let hueSpan=random.range(45,95)*(random.next() < 0.5 ? 1 : -1)
        let hueVelocity=random.range(18,42)*(random.next() < 0.5 ? 1 : -1)
        let angularVelocity=direction*random.range(0.5,1.1)
        let tilt=plane.tilt+random.range(-0.04,0.04),roll=plane.roll+random.range(-0.05,0.05)
        let radius=116*self.radius/nativeCenter+floor(Double(index)/Double(planes.count))*(38/max(ceil(Double(count)/Double(planes.count))-1,1))+random.range(-1.5,1.5)
        ribbons.append(Ribbon(thickness:thickness,hue:hue,hueSpan:hueSpan,hueVelocity:hueVelocity,angle:angle,
                              angularVelocity:angularVelocity,tilt:tilt,roll:roll,radius:radius,
                              radialVelocity:random.range(0,2.5),follow:random.range(0.74,0.94),arc:random.range(2.2,3.4)))
    }
    private func position(_ ribbon:Ribbon,angle:Double) -> Point {
        let horizontal=ribbon.radius*sin(angle),vertical = -ribbon.radius*cos(angle)*sin(ribbon.tilt)
        let c=cos(ribbon.roll),s=sin(ribbon.roll)
        return Point(x:nativeCenter+horizontal*c-vertical*s,y:nativeCenter+horizontal*s+vertical*c,z:cos(angle)*cos(ribbon.tilt),angle:angle)
    }
    func advance(time:Double,dt:Double,spinAngle:Double,wide:Bool) {
        var delta=spinAngle-previousAngle
        if !delta.isFinite || abs(delta) > 1.2 { delta=0 }
        previousAngle=spinAngle
        let wasSpinning=abs(velocity) >= 0.9
        velocity=dt > 0 ? delta/dt : 0
        let spinning=abs(velocity) >= 0.9
        if !wasSpinning && spinning { configure(wide:wide); emitted=false }
        if wasSpinning && !spinning { pending=[] }
        if !emitted && abs(velocity) >= 5 {
            emitted=true; pending=[]
            for i in 0..<count { pending.append((time+Double(i)*random.range(0.055,0.105),i)) }
        }
        while let event=pending.first, time >= event.at {
            pending.removeFirst()
            spawn(angle:spinAngle-random.range(0,0.18),direction:velocity == 0 ? 1 : velocity > 0 ? 1 : -1,index:event.index)
        }
        var survivors:[Ribbon]=[]
        for var ribbon in ribbons {
            ribbon.age += dt
            let returning = !spinning || nativeClamp(ribbon.age/9) > 0.55
            ribbon.retreat=nativeClamp(ribbon.retreat+(returning ? dt/0.5 : -dt/0.35))
            if ribbon.retreat >= 1 { continue }
            if spinning {
                ribbon.carry=velocity*ribbon.follow
                ribbon.angle += velocity*dt*ribbon.follow+ribbon.angularVelocity*dt
            } else {
                ribbon.angle += (ribbon.carry+ribbon.angularVelocity)*dt
                let decay=exp(-2.6*dt); ribbon.carry *= decay; ribbon.angularVelocity *= decay
            }
            ribbon.radius += ribbon.radialVelocity*dt
            let head=position(ribbon,angle:ribbon.angle),depthWidth=0.72+0.28*nativeClamp(head.z)
            let growth=nativeSmooth(min(ribbon.age/0.34,1))
            ribbon.width=max(ribbon.thickness*depthWidth*1.7*sizeScale*growth*(1-0.72*ribbon.retreat*ribbon.retreat),0.5)
            ribbon.opacity=min(1,ribbon.age/0.26)
            let oldAngle=ribbon.history.last?.angle ?? ribbon.angle,travel=ribbon.angle-oldAngle
            let steps=min(Int(ceil(abs(travel)/0.09)),24)
            if steps > 0 { for i in 1...steps { ribbon.history.append(position(ribbon,angle:oldAngle+travel*Double(i)/Double(steps))) } }
            if ribbon.history.isEmpty { ribbon.history.append(head) }
            let remainingArc=ribbon.arc*(1-nativeSmooth(ribbon.retreat))
            while ribbon.history.count > 2 && abs(ribbon.angle-ribbon.history[0].angle) > remainingArc { ribbon.history.removeFirst() }
            let excess=abs(ribbon.angle-ribbon.history[0].angle)-remainingArc
            if ribbon.history.count >= 2 && excess > 0 {
                let sign=ribbon.angle-ribbon.history[0].angle >= 0 ? 1.0 : -1.0
                ribbon.history[0]=position(ribbon,angle:ribbon.history[0].angle+sign*excess)
            }
            if ribbon.history.count > 48 { ribbon.history.removeFirst(ribbon.history.count-48) }
            survivors.append(ribbon)
        }
        ribbons=survivors
    }
    func render() -> (back:[NativeRibbonPaint],front:[NativeRibbonPaint]) {
        var back:[NativeRibbonPaint]=[],front:[NativeRibbonPaint]=[]
        for ribbon in ribbons where ribbon.history.count >= 2 {
            let paths=ribbonPaths(ribbon.history,width:ribbon.width)
            let start=ribbon.history.first!,end=ribbon.history.last!
            let colors=(0..<5).map { i -> CGColor in
                let progress=Double(i)/4
                let hue=ribbon.hue+ribbon.hueVelocity*ribbon.age+progress*ribbon.hueSpan
                let wrapped=(hue.truncatingRemainder(dividingBy:360)+360).truncatingRemainder(dividingBy:360)
                return Self.color(hue:floor(wrapped+0.5),saturation:0.56,lightness:floor(56+11*progress+0.5)/100)
            }
            func paint(_ path:CGPath) -> NativeRibbonPaint {
                NativeRibbonPaint(path:nativeTransform(path,CGAffineTransform(translationX:-nativeCenter,y:-nativeCenter)),
                    start:CGPoint(x:nativeRound(start.x,digits:10)-nativeCenter,y:nativeRound(start.y,digits:10)-nativeCenter),
                    end:CGPoint(x:nativeRound(end.x,digits:10)-nativeCenter,y:nativeRound(end.y,digits:10)-nativeCenter),
                    colors:colors,opacity:nativeRound(ribbon.opacity,digits:1000))
            }
            if !paths.back.isEmpty { back.append(paint(paths.back)) }
            if !paths.front.isEmpty { front.append(paint(paths.front)) }
        }
        return (back,front)
    }
    private func ribbonPaths(_ points:[Point],width:Double) -> (back:CGPath,front:CGPath) {
        let back=CGMutablePath(),front=CGMutablePath()
        var distance=0.0
        for i in 1..<points.count { distance += hypot(points[i].x-points[i-1].x,points[i].y-points[i-1].y) }
        if distance < 2 { return (back,front) }
        let boundedWidth=min(width,distance*0.34)
        let normals=points.indices.map { i -> CGPoint in
            let previous=points[max(0,i-1)],next=points[min(points.count-1,i+1)]
            let dx=next.x-previous.x,dy=next.y-previous.y,len=hypot(dx,dy)
            let length=len == 0 ? 1 : len,halfWidth=boundedWidth*(0.5+0.5*Double(i)/Double(points.count-1))/2
            return CGPoint(x:-dy/length*halfWidth,y:dx/length*halfWidth)
        }
        func edge(_ i:Int,_ sign:Double) -> CGPoint { CGPoint(x:nativeRound(points[i].x+sign*normals[i].x,digits:10),y:nativeRound(points[i].y+sign*normals[i].y,digits:10)) }
        func cap(_ path:CGMutablePath,_ i:Int,_ to:CGPoint) {
            let from=path.currentPoint
            let radius=nativeRound(max(hypot(normals[i].x,normals[i].y),0.2),digits:10)
            let dx=to.x-from.x,dy=to.y-from.y,chord=hypot(dx,dy)
            let actualRadius=max(radius,chord/2),distance=sqrt(max(0,actualRadius*actualRadius-chord*chord/4))
            let center=CGPoint(x:(from.x+to.x)/2+dy/max(chord,0.000001)*distance,y:(from.y+to.y)/2-dx/max(chord,0.000001)*distance)
            path.addArc(center:center,radius:actualRadius,startAngle:atan2(from.y-center.y,from.x-center.x),endAngle:atan2(to.y-center.y,to.x-center.x),clockwise:true)
        }
        func segment(_ start:Int,_ end:Int,_ path:CGMutablePath) {
            path.move(to:edge(start,1))
            if end > start { for i in (start+1)...end { path.addLine(to:edge(i,1)) } }
            if end == points.count-1 { cap(path,end,edge(end,-1)) } else { path.addLine(to:edge(end,-1)) }
            if end > start { for i in stride(from:end-1,through:start,by:-1) { path.addLine(to:edge(i,-1)) } }
            if start == 0 { cap(path,0,edge(0,1)) }
            path.closeSubpath()
        }
        var start=0
        while start < points.count {
            let inFront=points[start].z >= 0; var end=start
            while end+1 < points.count && (points[end+1].z >= 0) == inFront { end += 1 }
            let low=max(0,start-1),high=min(points.count-1,end+1)
            if high > low { segment(low,high,inFront ? front : back) }
            start=end+1
        }
        return (back,front)
    }
    private static func color(hue:Double,saturation:Double,lightness:Double) -> CGColor {
        let h=hue.truncatingRemainder(dividingBy:360),c=(1-abs(2*lightness-1))*saturation
        let x=c*(1-abs((h/60).truncatingRemainder(dividingBy:2)-1)),m=lightness-c/2
        let rgb:(Double,Double,Double)
        switch h {
        case ..<60: rgb=(c,x,0)
        case ..<120: rgb=(x,c,0)
        case ..<180: rgb=(0,c,x)
        case ..<240: rgb=(0,x,c)
        case ..<300: rgb=(x,0,c)
        default: rgb=(c,0,x)
        }
        return CGColor(srgbRed:rgb.0+m,green:rgb.1+m,blue:rgb.2+m,alpha:1)
    }
}
