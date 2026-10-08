# Example assets

`DamagedHelmet.glb` comes from the Khronos Group glTF Sample Assets repository:

https://github.com/KhronosGroup/glTF-Sample-Assets/tree/main/Models/DamagedHelmet

The rebuilt glTF asset is credited to ctxwing under CC BY 4.0. The original
helmet by theblueturtle_ is licensed under CC BY-NC 4.0. See the upstream model
README and license files for the full attribution and terms.

Downloaded asset SHA-256:
`a1e3b04de97b11de564ce6e53b95f02954a297f0008183ac63a4f5974f6b32d8`.

`studio_small_03_1k.hdr` is the Studio Small 03 environment from Poly Haven:

https://polyhaven.com/a/studio_small_03

Poly Haven assets are released under CC0.

Downloaded asset SHA-256:
`30933d55e45f0795daf49f3cbefbe0e5ebcb821ee04fb0a2818c02ffc3938817`.

`world/Fox.glb` comes from the Khronos Group glTF Sample Assets repository:

https://github.com/KhronosGroup/glTF-Sample-Assets/tree/main/Models/Fox

The Fox sample is distributed under CC BY 4.0. See the upstream README for
the original author attribution.

Downloaded asset SHA-256:
`d97044e701822bac5a62696459b27d7b375aada5de8574ed4362edbba94771f7`.

`world/RobotExpressive.glb` comes from the Three.js example assets. The model
is by Tomás Laulhé, with glTF modifications by Don McCurdy, and is released
under CC0 1.0:

https://github.com/mrdoob/three.js/tree/dev/examples/models/gltf/RobotExpressive

Downloaded asset SHA-256:
`047f5e5fb3bb6d378bd1df16ca6137f2a596c99b3a1b5690b4020c05aaf6f319`.

`world/Sponza.glb` is the single-file textured Sponza scene from the
Breush/lava-assets distribution:

https://github.com/Breush/lava-assets/blob/master/models/sponza.glb

The scene preserves the original Khronos/Crytek Sponza attribution. See the
upstream asset repository and source distribution for the included license
information.

Downloaded asset SHA-256:
`ce1af0a88db56981d4878382b33ce9afa5c4d88395df74d33b11615600108a7f`.

`world/venice_sunset_2k.hdr` is the Venice Sunset environment from Poly Haven:

https://polyhaven.com/a/venice_sunset

Poly Haven assets are released under CC0.

Downloaded asset SHA-256:
`cbfac020ee17ab36016ccc7fbe9020b828587b9864af6ecda0a93089914889a6`.

`world/venice_sunset_1k.hdr` is the same Venice Sunset environment at a
lower resolution.

`panel/` holds a small textured panel generated for this repository's tests,
in three encodings: PNG, and
Basis Universal ETC1S and UASTC in KTX2 files. The unit tests and the
headless example read them to check texture transcoding.

`fonts/` holds fonts from the Noto project for the `text` example and the
text shaping tests; see `fonts/README.md`.

The binary files in this folder are stored with Git LFS.

`world/Rogue_Hooded.glb` is the hooded rogue of the KayKit Adventurers
character pack by Kay Lousberg, released under CC0 1.0:

https://github.com/KayKit-Game-Assets/KayKit-Character-Pack-Adventures-1.0

The copy here has the meshes of the weapons it carries removed; the
skeleton and the animation clips are unchanged.

`hair/` is not kept with these sources (it is in `.gitignore`). The `hair`
example looks there for `wWavyThin.hair` and `woman.obj`, which are Cem
Yuksel's hair model and the head it was combed on (the head courtesy of
Murat Afshar):

http://www.cemyuksel.com/research/hairmodels

They may be downloaded and used freely for personal or research projects;
anything published that was made with them is expected to link to that
page. Without them the example makes a head of hair of its own.

`bistro/` is not kept with these sources either (it is in `.gitignore`, at
3.5 GB). The `bistro` example looks there for Amazon Lumberyard Bistro as
glTF with DDS textures:

    git clone --depth 1 https://github.com/zeux/niagara_bistro examples/assets/bistro

That repository is a lightly edited copy of the scene from NVIDIA's
rtxdi-assets, under the MIT license. The scene itself is by Amazon
Lumberyard, released under CC BY 4.0 through NVIDIA's Open Research Content
Archive.
