# Roadmap

## 1.0 means

- No floor penalty: every command a frame records belongs to a feature that is on (`zig build costs`).
- Pay for what you use: a feature switched off records nothing and gives its memory back (`zig build checks`).
- No ceiling: an application can add or replace any stage with its own GPU work (`passes`, `shader`, `triangle`).
- Steady: the same at any frame rate, size and run length; misuse and bad input are errors, never crashes (`--uneven-frames`, `--memory`, `zig build checks`).
- A stable, documented API for 2D, 2D over 3D, lightweight 3D, photoreal 3D and the application's own work.

## Before 1.0

### Path tracing
- ReSTIR for bounce light.
- Blue noise sampling.
- Rough reflections denoised apart from diffuse light.
- Anisotropic texture filtering at grazing angles.
- Water, liquids, smoke, clouds, particles, decals and refraction.
- Skinned meshes in the shader fallback.

### Denoising and upscaling
- FSR Ray Regeneration.
- DLSS on Windows.
- A choice of DLSS model preset.

### Antialiasing
- No trails behind fast objects.

### Platforms
- Verified on Windows.
- Verified on AMD and Intel GPUs.

## Later
- DLSS frame generation.
- One bloom and exposure path for scene and 2D views (now two).
- Feature state in `Shared` set before use instead of `undefined` until earlier passes fill it.
- Typed handles for detached work and compiled pipelines (now raw `u64`).
- A single-pass depth pyramid for occlusion culling.
- Light records kept on the GPU between frames, with only per-view flags uploaded.
