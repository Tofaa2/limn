The transcoder of Basis Universal (https://github.com/BinomialLLC/basis_universal,
Apache-2.0, see LICENSE), unchanged, in `transcoder/`: it turns the
supercompressed textures KTX2 files carry for glTF (ETC1S, UASTC and their
newer relatives) into the block formats a GPU reads.

`rnd_basis.cpp` is the renderer's own small C interface to it, and
`zstd/zstd.h` stands in for Zstandard's header: the transcoder's few calls
go to the decoder the renderer already has.
