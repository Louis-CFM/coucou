import assert from 'node:assert/strict';
import {centeredFrame,capsulePose,surfaceRect,outsideRects} from '../motion.js';
for (const s of [1,1.25,1.7518248558044434,2]) {
 const displaced={x:490*s,y:50*s,width:720*s,height:320*s};
 const capsule={x:500*s,y:5*s,width:280*s,height:28*s};
 const surface={width:640,height:180};
 const window=centeredFrame(displaced,capsule);
 assert.ok(Math.abs(window.x+window.width/2-capsule.x-capsule.width/2)<=.5);
 const pose=capsulePose(window,capsule,surface);
 const r=surfaceRect(window,surface);
 assert.equal(r.width*pose.scale_x,capsule.width);
 assert.equal(r.height*pose.scale_y,capsule.height);
 assert.equal(window.y+pose.translation_y,capsule.y);
 assert.equal(window.x+window.width/2+pose.translation_x,capsule.x+capsule.width/2);
 const monitors=[{x:-800,y:0,width:800,height:600},{x:0,y:0,width:1280*s,height:720*s}];
 const holes=[r,capsule];
 const pieces=outsideRects(monitors,holes);
 const inside=(r,x,y)=>x>=r.x&&x<r.x+r.width&&y>=r.y&&y<r.y+r.height;
 for(const m of monitors) for(let y=m.y;y<m.y+m.height;y+=7) for(let x=m.x;x<m.x+m.width;x+=7){
  const hit=pieces.filter(r=>inside(r,x,y)).length;
  assert.equal(hit,holes.some(r=>inside(r,x,y))?0:1,`input routing ${x},${y}`);
 }
}
console.log('PASS: capsule origin, matching return path, input holes at integer and fractional scales and multiple monitors');
