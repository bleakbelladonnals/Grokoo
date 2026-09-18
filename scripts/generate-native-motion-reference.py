#!/usr/bin/env python3
"""Independent reference measurements from the unchanged handoff ESM output.
Only test fixtures use these snapshots; the App never consumes them.
"""
import argparse, json, math, pathlib, re, subprocess, tempfile, xml.etree.ElementTree as ET
root=pathlib.Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--kit', type=pathlib.Path, required=True, metavar='PATH',
                    help='path to the approved animation kit (not needed for normal builds)')
kit=parser.parse_args().kit.expanduser().resolve()
if not kit.is_dir():
 parser.error(f'--kit is not a directory: {kit}')
if not (kit/'dist/index.js').is_file():
 parser.error('--kit is missing required file: dist/index.js')
I=(1,0,0,1,0,0)
def mul(a,b):
 return (a[0]*b[0]+a[2]*b[1],a[1]*b[0]+a[3]*b[1],a[0]*b[2]+a[2]*b[3],a[1]*b[2]+a[3]*b[3],a[0]*b[4]+a[2]*b[5]+a[4],a[1]*b[4]+a[3]*b[5]+a[5])
def transform(s):
 out=I
 for op,params in re.findall(r'(\w+)\(([^)]*)\)',s):
  p=[float(v) for v in re.findall(r'[-+]?(?:\d*\.)?\d+(?:[eE][-+]?\d+)?',params)]
  if op=='translate': m=(1,0,0,1,p[0],p[1] if len(p)>1 else 0)
  elif op=='scale': m=(p[0],0,0,p[1] if len(p)>1 else p[0],0,0)
  elif op=='rotate':
   a=p[0]*math.pi/180;m=(math.cos(a),math.sin(a),-math.sin(a),math.cos(a),0,0)
  elif op=='matrix': m=tuple(p)
  else: raise ValueError(op)
  out=mul(out,m)
 return out
def applied(p,m): return (m[0]*p[0]+m[2]*p[1]+m[4],m[1]*p[0]+m[3]*p[1]+m[5])
def arc(start,rx,ry,angle,large,sweep,end):
 # SVG endpoint arc conversion. Approved caps/eyes have axis-aligned circles.
 assert angle==0 and abs(rx-ry)<1e-6
 dx=(start[0]-end[0])/2;dy=(start[1]-end[1])/2
 r=max(rx,math.hypot(dx,dy));den=dx*dx+dy*dy
 fac=math.sqrt(max(0,(r*r-den)/den)) if den else 0
 if large==sweep:fac=-fac
 cx=fac*dy+(start[0]+end[0])/2;cy=-fac*dx+(start[1]+end[1])/2
 a=math.atan2(start[1]-cy,start[0]-cx);b=math.atan2(end[1]-cy,end[0]-cx);delta=b-a
 if sweep and delta<0:delta+=2*math.pi
 if not sweep and delta>0:delta-=2*math.pi
 return [(cx+r*math.cos(a+delta*i/128),cy+r*math.sin(a+delta*i/128)) for i in range(129)]
def points(el):
 tag=el.tag.split('}')[-1];a=el.attrib
 if tag=='circle':
  x=float(a.get('cx',0));y=float(a.get('cy',0));r=float(a['r'])
  return [(x+r*math.cos(i*math.pi/256),y+r*math.sin(i*math.pi/256)) for i in range(512)]
 if tag!='path':return []
 tokens=re.findall(r'[MLCQAZ]|[-+]?(?:\d*\.)?\d+(?:[eE][-+]?\d+)?',a['d']);i=0;out=[];p=(0,0);origin=(0,0)
 def number():
  nonlocal i
  x=float(tokens[i]);i+=1;return x
 def point():return(number(),number())
 while i<len(tokens):
  op=tokens[i];i+=1
  if op=='M':p=point();origin=p;out.append(p)
  elif op=='L':p=point();out.append(p)
  elif op in ['C','Q']:
   start=p;c1=point();c2=point() if op=='C' else None;p=point()
   for k in range(1,129):
    t=k/128;u=1-t
    if op=='C':q=tuple(u**3*start[d]+3*u*u*t*c1[d]+3*u*t*t*c2[d]+t**3*p[d] for d in (0,1))
    else:q=tuple(u*u*start[d]+2*u*t*c1[d]+t*t*p[d] for d in(0,1))
    out.append(q)
  elif op=='A':
   rx=number();ry=number();rotation=number();large=number();sweep=number();end=point();out.extend(arc(p,rx,ry,rotation,large,sweep,end));p=end
  elif op=='Z':p=origin;out.append(p)
  else:raise ValueError(op)
 return out
def bounds(ps):
 if not ps:return None
 return [min(p[0] for p in ps),min(p[1] for p in ps),max(p[0] for p in ps),max(p[1] for p in ps)]
def measure(item):
 svg=ET.fromstring(item.pop('svg'));state=item['state'];motion=state in ['working','done'];rest=state in ['idle','waiting','offline']
 center=(1,0,0,1,-114.2705,-114.2705) if motion else I
 groups={'body':[],'eyes':[],'marks':[],'back':[],'front':[]}
 def walk(el,parent=I,category=None,in_defs=False):
  tag=el.tag.split('}')[-1];a=el.attrib;m=mul(parent,transform(a.get('transform','')))
  if tag=='defs':in_defs=True
  if 'data-motion-layer'in a:category=a['data-motion-layer']
  if 'data-motion-body'in a:category='body'
  if 'data-status-mark'in a:category='marks'
  current=category
  if 'data-motion-eye'in a:current='eyes'
  if 'data-status-body'in a:current='body'
  if not in_defs and tag in ['path','circle'] and current:
   ps=[applied(p,mul(center,m)) for p in points(el)]
   groups[current].append(ps)
  for child in el:walk(child,m,category,in_defs)
 walk(svg)
 if rest:
  pose=transform(next(child for child in svg if child.tag.split('}')[-1]=='g').attrib['transform'])
  for el in svg.iter():
   if el.tag.split('}')[-1]=='mask':
    for index,path in enumerate(el):
     m=mul(pose,transform(path.attrib.get('transform','')))
     groups['body' if index==0 else 'eyes'].append([applied(p,m) for p in points(path)])
 item.update({'sampleTime':float(svg.attrib.get('data-time',item['time'])),'surfaceTurn':float(svg.attrib.get('data-surface-turn',0)),
              'bodyBounds':bounds([p for ps in groups['body'] for p in ps]),'eyeBounds':[bounds(ps) for ps in groups['eyes']],
              'markBounds':bounds([p for ps in groups['marks'] for p in ps]),
              'backBounds':[bounds(ps) for ps in groups['back']],'frontBounds':[bounds(ps) for ps in groups['front']]})
 return item
shapes=['cercle','galet','squircle','capsule','triangle','hexagone','nuage','goutte'];states=['idle','working','thinking','waiting','blocked','done','offline'];times=[1,1.2,2.4,2.4,2.4,4.85,.35]
requests=[{'shape':shape,'state':state,'time':time} for shape in shapes for state,time in zip(states,times)]
for shape in shapes:
 for state,ts in [('working',[0,.5,1.8,2.4,2.8,3.5,8.5,10,14,19.95,25]),('done',[0,.14,.15,.4,.7,1.2,2.8,3.3,4.5,5.64,6.2,6.35,7.5,12.55])]:
  requests.extend({'shape':shape,'state':state,'time':t} for t in ts)
with tempfile.TemporaryDirectory(prefix='grokoo-ts-reference-') as temp:
 p=pathlib.Path(temp)/'reference.mjs';p.write_text('import {renderBotFrame} from '+json.dumps((kit/'dist/index.js').as_uri())+';\nconst requests='+json.dumps(requests)+';\nconsole.log(JSON.stringify(requests.map((r,i)=>({...r,svg:renderBotFrame({...r,color:"#1084FE",instanceId:"native-reference-"+i})}))));')
 frames=json.loads(subprocess.check_output(['node',str(p)],text=True))
reference={'source':'Approved animation-kit dist/index.js, unchanged, generated 2026-09-18','samples':[measure(f) for f in frames]}
out=root/'GrokooTests/Fixtures/native-motion-reference.json';out.write_text(json.dumps(reference,separators=(',',':'))+'\n')
print('Generated',len(reference['samples']),'independent reference frames;',out.stat().st_size,'bytes')
