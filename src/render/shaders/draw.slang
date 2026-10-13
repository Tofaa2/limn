#include "canvas.slang"

[shader("fragment")]
float4 fragmentMain(Varyings input) : SV_Target {
    return canvasEncode(canvasColor(input));
}
