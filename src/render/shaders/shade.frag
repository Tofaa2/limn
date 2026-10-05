#version 460
#ifdef RAY_TRACED
#extension GL_EXT_ray_query : require
#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require
#endif
#include "shade.glsl"
