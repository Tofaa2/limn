AMD FidelityFX Super Resolution 1.0
(https://github.com/GPUOpen-Effects/FidelityFX-FSR, `ffx-fsr/ffx_a.h` and
`ffx-fsr/ffx_fsr1.h`), unchanged. MIT; see `LICENSE.txt`.

The renderer compiles them as they are: `fsr_easu.frag` and
`fsr_rcas.frag` in `src/render/shaders` include them and supply the
texture fetches they ask for. They are what `Settings.upscaling = .fsr`
brings a picture rendered below the output size up to it with: an
edge-adaptive upscale (EASU) and a sharpening pass (RCAS).
