# Test data

What the unit tests and `zig build checks` read. These are plain files, not
Git LFS, and are left out of the package's `.paths`, so projects that depend
on limn never fetch them.

`world/Fox.glb` comes from the Khronos Group glTF Sample Assets repository:

https://github.com/KhronosGroup/glTF-Sample-Assets/tree/main/Models/Fox

The Fox sample is distributed under CC BY 4.0. See the upstream README for
the original author attribution.

Downloaded asset SHA-256:
`d97044e701822bac5a62696459b27d7b375aada5de8574ed4362edbba94771f7`.

`panel/` holds a small textured panel generated for these tests, in three
encodings: PNG, and Basis Universal ETC1S and UASTC in KTX2 files. The tests
read them to check texture transcoding.

`fonts/` holds fonts from the Noto project for the text shaping tests; see
`fonts/README.md`.
