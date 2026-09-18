import Foundation
import AppKit
import QuartzCore
@main struct Keyframes {
 @MainActor static func main() throws {
  let root=CALayer();root.frame=CGRect(x:0,y:0,width:1240,height:1000)
  root.backgroundColor=NSColor(calibratedRed:0.93,green:0.96,blue:0.98,alpha:1).cgColor
  func text(_ value:String,_ x:Double,_ y:Double,_ width:Double,_ font:Double=15) {
   let l=CATextLayer();l.frame=CGRect(x:x,y:y,width:width,height:font+9);l.string=value
   l.font=NSFont.systemFont(ofSize:font,weight:.medium);l.fontSize=font;l.contentsScale=2
   l.foregroundColor=NSColor(calibratedWhite:0.16,alpha:1).cgColor;root.addSublayer(l)
  }
  text("Grokoo · Working / Done 原生关键姿势",30,948,1150,25)
  text("三种代表身体的 72pt 放大检查；正式尺寸与完整 56 组合见连续时间轴",30,916,1160,15)
  let sampler=NativeMotionSampler(), shapes:[OfficialShape]=[.blob,.tablet,.cloud]
  for (section,state) in [PresenceState.working,.done].enumerated() {
   let times=state == .working ? [0.0,1.2,2.4,3.4,8.5,15.0] : [0.15,0.5,1.2,2.8,4.85,6.35]
   let top=Double(854-section*405)
   text(state.rawValue.capitalized,30,top,160,19)
   for (col,time) in times.enumerated() { text(String(format:"%.2fs",time),180+Double(col)*174,top,145) }
   for (row,shape) in shapes.enumerated() {
    let y=top-75-Double(row)*113
    text(shape.rawValue,30,y-5,130)
    for (col,time) in times.enumerated() {
     let f=sampler.sample(shape:shape,state:state,time:time,instanceID:"\(state)-\(shape)-\(col)")
     let l=NativeMotionLayer();l.position=CGPoint(x:216+Double(col)*174,y:y+7)
     l.apply(frame:f,color:(row == 0 ? OfficialColor.blue : row == 1 ? .green : .violet).cgColor,bodySize:72);root.addSublayer(l)
    }
   }
  }
  text("Swift / Core Graphics / Core Animation 原生图层导出 · 非桌面录屏",30,30,1160,14)
  let c=CGContext(data:nil,width:2480,height:2000,bitsPerComponent:8,bytesPerRow:2480*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
  c.scaleBy(x:2,y:2);root.render(in:c)
  let rep=NSBitmapImageRep(cgImage:c.makeImage()!);try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
 }
}
