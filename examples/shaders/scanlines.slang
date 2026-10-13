#include "canvas.slang"

[shader("fragment")]
float4 fragmentMain(Varyings input) : SV_Target {
    float4 color = canvasColor(input);
    float line = 0.75 + 0.25 * sin(input.position.y * 3.14159 + push.time * 6.0);
    float sweep = smoothstep(0.96, 1.0, sin(input.position.y * 0.02 - push.time * 2.0));
    color.rgb = color.rgb * line + color.rgb * sweep * 0.6;
    return canvasEncode(color);
}
