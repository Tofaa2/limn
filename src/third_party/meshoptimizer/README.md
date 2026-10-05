The mesh simplifier of meshoptimizer 0.24 (https://github.com/zeux/meshoptimizer),
unchanged: `simplifier.cpp` and the header it needs. The copy of the library
that comes with zmesh is 0.18, whose simplifier cannot weigh normals and
texture coordinates or work on part of a mesh; everything else still comes
from there. `build.zig` compiles this file with its names prefixed (`rnd_`)
so the two versions can be linked together.
