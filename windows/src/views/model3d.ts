// Generated 3D models (GLB, e.g. from TRELLIS 2): a still for the chat and a
// turntable for the full-screen preview.
//
// three.js is only loaded the first time a model is shown, and every WebGL
// context is handed back as soon as it's done: the chat keeps a plain picture,
// not a live renderer.

import type * as ThreeNS from "three";

type Three = typeof ThreeNS;

let kit: Promise<{
  THREE: Three;
  GLTFLoader: typeof import("three/examples/jsm/loaders/GLTFLoader.js").GLTFLoader;
  OrbitControls: typeof import("three/examples/jsm/controls/OrbitControls.js").OrbitControls;
}> | null = null;

function load() {
  kit ??= Promise.all([
    import("three"),
    import("three/examples/jsm/loaders/GLTFLoader.js"),
    import("three/examples/jsm/controls/OrbitControls.js"),
  ]).then(([THREE, gltf, orbit]) => ({ THREE, GLTFLoader: gltf.GLTFLoader, OrbitControls: orbit.OrbitControls }));
  return kit;
}

/** A lit scene around the model, centred on the origin, camera framing it. */
async function stage(bytes: ArrayBuffer, canvas: HTMLCanvasElement, width: number, height: number, still: boolean) {
  const { THREE, GLTFLoader, OrbitControls } = await load();
  const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: true, preserveDrawingBuffer: still });
  renderer.setPixelRatio(Math.min(2, window.devicePixelRatio || 1));
  renderer.setSize(width, height, false);
  renderer.outputColorSpace = THREE.SRGBColorSpace;

  const scene = new THREE.Scene();
  scene.add(new THREE.HemisphereLight(0xffffff, 0x3a3d52, 2.4));
  const key = new THREE.DirectionalLight(0xffffff, 2.2);
  key.position.set(3, 5, 4);
  scene.add(key);
  const rim = new THREE.DirectionalLight(0x9aa4ff, 1.2);
  rim.position.set(-4, 2, -3);
  scene.add(rim);

  const gltf = await new GLTFLoader().parseAsync(bytes, "");
  const model = gltf.scene;
  const box = new THREE.Box3().setFromObject(model);
  const size = box.getSize(new THREE.Vector3());
  model.position.sub(box.getCenter(new THREE.Vector3()));
  scene.add(model);

  const camera = new THREE.PerspectiveCamera(35, width / height, 0.01, 1000);
  const span = Math.max(size.x, size.y, size.z) || 1;
  const distance = (span / (2 * Math.tan((camera.fov * Math.PI) / 360))) * 1.5;
  camera.position.set(distance * 0.75, distance * 0.45, distance);
  camera.near = distance / 100;
  camera.far = distance * 100;
  camera.updateProjectionMatrix();
  camera.lookAt(0, 0, 0);

  const dispose = () => {
    scene.traverse((o) => {
      const mesh = o as ThreeNS.Mesh;
      mesh.geometry?.dispose();
      const materials = Array.isArray(mesh.material) ? mesh.material : mesh.material ? [mesh.material] : [];
      for (const m of materials) {
        for (const v of Object.values(m)) if (v instanceof THREE.Texture) v.dispose();
        m.dispose();
      }
    });
    renderer.dispose();
    renderer.forceContextLoss();
  };
  return { THREE, OrbitControls, renderer, scene, camera, dispose };
}

/** One rendered frame of the model as a PNG data URL, for the chat. */
export async function snapshot(bytes: ArrayBuffer, width = 280, height = 168): Promise<string> {
  const canvas = document.createElement("canvas");
  const s = await stage(bytes, canvas, width, height, true);
  s.renderer.render(s.scene, s.camera);
  const url = canvas.toDataURL("image/png");
  s.dispose();
  return url;
}

/**
 * A turntable filling `host`: drag to turn, scroll to zoom; it spins slowly
 * until touched. Returns the function that stops it and frees the GPU.
 */
export async function mountViewer(host: HTMLElement, bytes: ArrayBuffer): Promise<() => void> {
  const canvas = document.createElement("canvas");
  canvas.className = "preview-3d-canvas";
  host.append(canvas);
  const { width, height } = host.getBoundingClientRect();
  const s = await stage(bytes, canvas, width || 800, height || 600, false);
  const controls = new s.OrbitControls(s.camera, canvas);
  controls.enableDamping = true;
  controls.autoRotate = true;
  controls.autoRotateSpeed = 1.6;
  controls.addEventListener("start", () => (controls.autoRotate = false));

  const resize = new ResizeObserver(() => {
    const r = host.getBoundingClientRect();
    if (!r.width || !r.height) return;
    s.renderer.setSize(r.width, r.height, false);
    s.camera.aspect = r.width / r.height;
    s.camera.updateProjectionMatrix();
  });
  resize.observe(host);

  let frame = 0;
  const tick = () => {
    controls.update();
    s.renderer.render(s.scene, s.camera);
    frame = requestAnimationFrame(tick);
  };
  tick();
  return () => {
    cancelAnimationFrame(frame);
    resize.disconnect();
    controls.dispose();
    s.dispose();
    canvas.remove();
  };
}
