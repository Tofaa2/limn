The reflection denoiser of AMD's FidelityFX Denoiser 1.2
(https://github.com/GPUOpen-Effects/FidelityFX-Denoiser, commit d7dfecb),
unchanged, in `ffx-reflection-dnsr`. MIT; see `LICENSE.txt`.

These files are HLSL compute shaders that write their results to storage
images, which the renderer's device layer does not have, so they are not
compiled. They are kept as the reference for the port that is: the
`ffx_reflections*.glsl` and `ffx_reflections_*.frag` shaders in
`src/render/shaders`, which follow them pass for pass as full-screen
fragment shaders. The path tracer uses them to clear the grain of what
shows in glossy surfaces.
