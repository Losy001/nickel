cbuffer Constants : register(b0) { float2 inv_size; float2 pad; };

struct VSIn  { float2 pos : POSITION; float2 uv : TEXCOORD0; float4 col : COLOR0; };
struct VSOut { float4 pos : SV_POSITION; float2 uv : TEXCOORD0; float4 col : COLOR0; };

VSOut VS(VSIn i) {
    VSOut o;
    o.pos = float4(i.pos.x * inv_size.x * 2.0 - 1.0, 1.0 - i.pos.y * inv_size.y * 2.0, 0.0, 1.0);
    o.uv  = i.uv;
    o.col = i.col;
    return o;
}

// The glyph atlas (R8), or an RGBA image for PS_IMAGE.
Texture2D atlas : register(t0);
SamplerState smp : register(s0);

float4 PS(VSOut i) : SV_Target {
    float a = atlas.Sample(smp, i.uv).r;
    return float4(i.col.rgb, i.col.a * a);
}

float4 PS_IMAGE(VSOut i) : SV_Target {
    return atlas.Sample(smp, i.uv) * i.col;
}
