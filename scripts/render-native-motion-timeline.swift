import Foundation
import AppKit
import QuartzCore

@main struct Timeline {
 @MainActor static func main() throws {
  let output=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
  try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
  let width=1280.0,height=960.0,scale=1.5
  let root=CALayer();root.frame=CGRect(x:0,y:0,width:width,height:height)
  root.backgroundColor=NSColor(calibratedRed:0.93,green:0.96,blue:0.98,alpha:1).cgColor
  func label(_ text:String,_ x:Double,_ y:Double,_ w:Double,_ size:Double=14)->CATextLayer {
   let layer=CATextLayer();layer.frame=CGRect(x:x,y:y,width:w,height:size+9);layer.string=text
   layer.font=NSFont.systemFont(ofSize:size,weight:.medium);layer.fontSize=size;layer.contentsScale=scale
   layer.foregroundColor=NSColor(calibratedWhite:0.16,alpha:1).cgColor;root.addSublayer(layer);return layer
  }
  _=label("Grokoo · 原生动作时间轴",36,914,800,26)
  _=label("8 种身体 × 7 种状态 · 42pt 身体 · 连续 20 秒",36,880,1000,15)
  let states:[PresenceState]=[.idle,.working,.thinking,.waiting,.blocked,.done,.offline]
  let shapes=OfficialShape.allCases
  let palette:[OfficialColor]=[.black,.brown,.blue,.green,.orange,.violet,.cyan,.magenta]
  for (col,state) in states.enumerated() { _=label(state.rawValue.capitalized,172+Double(col)*154,839,150,14) }
  let sampler=NativeMotionSampler()
  var layers:[NativeMotionLayer]=[]
  for (row,shape) in shapes.enumerated() {
   _=label(shape.rawValue,28,782-Double(row)*94,130,14)
   for col in states.indices {
    let layer=NativeMotionLayer();layer.position=CGPoint(x:208+Double(col)*154,y:793-Double(row)*94);root.addSublayer(layer);layers.append(layer)
   }
  }
  let timeLabel=label("0.00s",1120,913,140,22)
  _=label("Swift / Core Graphics / Core Animation 原生图层导出",36,51,1100,14)
  _=label("Working 连续时间采样；Done 首次约 0.14s、动作 5.49s、每 6.2s 再触发",36,26,1190,13)
  let bar=CALayer();bar.backgroundColor=NSColor(calibratedRed:0.08,green:0.48,blue:0.76,alpha:1).cgColor;bar.anchorPoint = .zero;bar.position=CGPoint(x:36,y:77);root.addSublayer(bar)
  for tick in 0..<480 {
   let t=Double(tick)/24
   CATransaction.begin();CATransaction.setDisableActions(true)
   for (row,shape) in shapes.enumerated() {
    for (col,state) in states.enumerated() {
     let frame=sampler.sample(shape:shape,state:state,time:t,instanceID:"\(row)-\(col)")
     layers[row*7+col].apply(frame:frame,color:palette[row].cgColor,bodySize:42)
    }
   }
   timeLabel.string=String(format:"%.2fs",t);bar.bounds=CGRect(x:0,y:0,width:1208*t/20,height:3)
   CATransaction.commit()
   let context=CGContext(data:nil,width:Int(width*scale),height:Int(height*scale),bitsPerComponent:8,bytesPerRow:Int(width*scale)*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
   context.scaleBy(x:scale,y:scale);root.render(in:context)
   let image=context.makeImage()!,rep=NSBitmapImageRep(cgImage:image)
   try rep.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent(String(format:"frame-%04d.png",tick)))
   if tick % 120 == 0 { print("Rendered",tick,"/480") }
  }
 }
}
