# Limn
A high quality realtime concurrency-first physically based renderer written in zig with Vulkan 1.3

![Sponza, path traced](.github/images/rtx_path.png)

| ![meadow](.github/images/meadow.png) | ![rtx](.github/images/rtx.png) | ![world](.github/images/world.png) |
|:-:|:-:|:-:|
| **meadow** | **rtx** | **world** |
| ![pathtrace](.github/images/pathtrace.png) | ![clouds](.github/images/clouds.png) | ![materials](.github/images/materials.png) |
| **pathtrace** | **clouds** | **materials** |
| ![lights](.github/images/lights.png) | ![reflections](.github/images/reflections.png) | ![water](.github/images/water.png) |
| **lights** | **reflections** | **water** |
| ![liquid](.github/images/liquid.png) | ![fluid](.github/images/fluid.png) | ![particles](.github/images/particles.png) |
| **liquid** | **fluid** | **particles** |
| ![post](.github/images/post.png) | ![decals](.github/images/decals.png) | ![animation](.github/images/animation.png) |
| **post** | **decals** | **animation** |
| ![instancing](.github/images/instancing.png) | ![views](.github/images/views.png) | ![shader](.github/images/shader.png) |
| **instancing** | **views** | **shader** |
| ![text](.github/images/text.png) | ![canvas](.github/images/canvas.png) | ![triangle](.github/images/triangle.png) |
| **text** | **canvas** | **triangle** |

Every picture is an example in `examples/`: run it with `zig build <name>`.

```zig
const gfx = @import("limn");

const renderer = try gfx.Renderer.init(gpa, io, .{ .surface = surface });
defer renderer.deinit();

const scene = try renderer.createScene();
const model = try renderer.loadModel("helmet.glb");
_ = try renderer.spawn(scene, .{ .model = model });
renderer.setSun(scene, .{ .direction = .{ -0.4, -1.0, -0.3 } });

while (running) {
    _ = try renderer.render(.{
        .views = &.{.{ .scene = scene, .camera = gfx.Camera.lookAt(eye, target) }},
        .delta_time = dt,
    });
}
```

## Build

Requires Zig 0.16, a Vulkan 1.3 driver and `glslc`. The Vulkan headers and
loader are fetched by the build; the examples also need GLFW, which is
fetched on Windows and linked from the system elsewhere. `flake.nix`
provides everything. The example assets are stored with Git LFS: run
`git lfs install` before cloning, or `git lfs pull` afterwards.

```sh
zig build            # library and examples
zig build run        # the meadow example
zig build test       # unit tests
zig build verify     # formatting, tests, and the examples under Vulkan validation
zig build docs       # API reference in zig-out/docs
```

Add `-Doptimize=ReleaseFast` for full speed. Every example takes `--frames N`
and `--screenshot file.png`, and lists its keys at the top of its source
file; `zig build scene` renders the test scene offscreen with timings.

## Documentation

`zig build docs` writes the API reference from the doc comments in `src`.
After that you can use python to serve you the documentation as a webserver with `python3 -m http.server 8000 -d zig-out/docs`

## Platforms

Developed and tested on Linux with an NVIDIA GPU and with Mesa's software
driver. It cross-compiles for Windows, but has not yet been verified on
Windows itself, nor on AMD or Intel GPUs.

## LLM Notice
AI was used for documentation, README prettification, examples, and specific core content. All code PR'ed to this, repo if LLM developed, requires complete verification by the developer. Slop PR's will not be accepted all LLM code must be reviewed.

## License

Apache-2.0; see [`LICENSE`](LICENSE). Bundled work keeps its own terms:

- meshoptimizer (MIT): `src/third_party/meshoptimizer`
- Basis Universal transcoder (Apache-2.0): `src/third_party/basisu`
- DejaVu Sans, the built-in font: `src/render/fonts/LICENSE`
- Example models, environments and fonts: `examples/assets/README.md`
