// =============================================================================
//  RaindropMaterial.hlsl — 直接粘贴进 Custom Node Code 框
//  Niagara 粒子精灵 · 风格化雨滴 · 纯程序化无外部贴图
//
//  【Custom 节点设置】
//  Output Type : CMOT Float4
//  输出接线    : output.rgb → Emissive Color
//              : output.a   → Opacity
//
//  【Input 引脚列表】（名称必须一致）
//    UV            float2   TexCoord[0]
//    Time          float    Time 节点
//    DynParam      float4   DynamicParameter  (.x=NormalizedAge  .y=RandomSeed)
//    ParticleColor float3   Particle Color 节点（只取 RGB，连接方式见下）
//    ParticleAlpha float    Particle Color 节点 → ComponentMask(A)
//    DropColor     float3   VectorParameter   默认 (0.20, 0.40, 0.75)
//    CausticColor  float3   VectorParameter   默认 (0.55, 0.80, 1.00)
//    RimColor      float3   VectorParameter   默认 (0.85, 0.95, 1.00)
//    DropScale     float    ScalarParameter   默认 0.38
//    DropStretch   float    ScalarParameter   默认 0.25  ← 横纵比控制
//    EdgeSoftness  float    ScalarParameter   默认 1.0
//    FadeInEnd     float    ScalarParameter   默认 0.08
//    FadeOutStart  float    ScalarParameter   默认 0.80
//
//  【精灵尺寸】
//    Niagara 精灵请使用方形（例如 200×200），
//    用 DropStretch 控制水滴细长程度：
//      0.25 = 细长雨滴（推荐）
//      0.50 = 椭圆形
//      1.00 = 圆形对称泪滴
//    不要靠非方形精灵拉伸——非方形精灵会导致 UV 变形、颜色错乱。
//
//  【注意】Custom Node 代码被注入到 UE 生成函数体内部，
//  不能定义函数或 struct，本文件已将所有逻辑完全展开为顺序代码。
// =============================================================================


// ─────────────────────────────────────────────────────────────────────────────
//  1. 解包粒子参数
// ─────────────────────────────────────────────────────────────────────────────

float _age  = saturate(DynParam.x);   // NormalizedAge [0,1]
float _seed = DynParam.y;             // 每粒子随机种子

// ─────────────────────────────────────────────────────────────────────────────
//  2. 中心化 UV + 落地挤压形变 + 横纵比拉伸
//     精灵 UV 原点在左上角，中心化后 p.y 向下为正
//     泪滴 SDF：圆体在下（+Y），尖端在上（-Y），符合下落方向
//
//     DropStretch < 1 → 水平方向压缩 → 精灵上呈现细长雨滴形
//     请配合方形精灵使用，不要靠非方形精灵拉伸。
// ─────────────────────────────────────────────────────────────────────────────

float2 _p   = UV - 0.5;
float  _sqT = smoothstep(0.85, 1.0, _age);   // 落地临近时触发
_p         *= float2(1.0 + _sqT * 0.25, 1.0 - _sqT * 0.15);
_p.x       /= max(DropStretch, 0.05);         // 横向压缩：值越小雨滴越细长

// ─────────────────────────────────────────────────────────────────────────────
//  3. 泪滴 SDF — 主距离值
//     形状 = SMin(底部圆, 顶部楔形, 0.18)
//     SMin(a,b,k): h = sat(0.5+0.5*(b-a)/k),  lerp(b,a,h) - k*h*(1-h)
// ─────────────────────────────────────────────────────────────────────────────

float2 _pn  = _p / DropScale;
float  _cir = length(_pn) - 0.5;
float  _kk  = abs(_pn.x) * 0.75 + _pn.y * 0.65;
float  _con = max(_kk - 0.28, -_pn.y - 0.48);
float  _hh  = saturate(0.5 + 0.5 * (_con - _cir) / 0.18);
float  _dist = (lerp(_con, _cir, _hh) - 0.18 * _hh * (1.0 - _hh)) * DropScale;

// ─────────────────────────────────────────────────────────────────────────────
//  4. 表面法线 — 有限差分（4 次 SDF，展开写）
//     不用循环是因为 ternary 在一些 SM6 驱动上展开有问题
//     注：差分在已拉伸的 _p 空间中计算，法线与形状一致
// ─────────────────────────────────────────────────────────────────────────────

float _eps = 0.0008;
float _dxp, _dxn, _dyp, _dyn;

// dx+
_pn = (_p + float2(_eps, 0.0)) / DropScale;
_cir = length(_pn)-0.5; _kk = abs(_pn.x)*0.75+_pn.y*0.65; _con = max(_kk-0.28,-_pn.y-0.48);
_hh = saturate(0.5+0.5*(_con-_cir)/0.18);
_dxp = (lerp(_con,_cir,_hh)-0.18*_hh*(1.0-_hh))*DropScale;

// dx-
_pn = (_p - float2(_eps, 0.0)) / DropScale;
_cir = length(_pn)-0.5; _kk = abs(_pn.x)*0.75+_pn.y*0.65; _con = max(_kk-0.28,-_pn.y-0.48);
_hh = saturate(0.5+0.5*(_con-_cir)/0.18);
_dxn = (lerp(_con,_cir,_hh)-0.18*_hh*(1.0-_hh))*DropScale;

// dy+
_pn = (_p + float2(0.0, _eps)) / DropScale;
_cir = length(_pn)-0.5; _kk = abs(_pn.x)*0.75+_pn.y*0.65; _con = max(_kk-0.28,-_pn.y-0.48);
_hh = saturate(0.5+0.5*(_con-_cir)/0.18);
_dyp = (lerp(_con,_cir,_hh)-0.18*_hh*(1.0-_hh))*DropScale;

// dy-
_pn = (_p - float2(0.0, _eps)) / DropScale;
_cir = length(_pn)-0.5; _kk = abs(_pn.x)*0.75+_pn.y*0.65; _con = max(_kk-0.28,-_pn.y-0.48);
_hh = saturate(0.5+0.5*(_con-_cir)/0.18);
_dyn = (lerp(_con,_cir,_hh)-0.18*_hh*(1.0-_hh))*DropScale;

float3 _N = normalize(float3(_dxp-_dxn, _dyp-_dyn, _eps*2.5));

// ─────────────────────────────────────────────────────────────────────────────
//  5. 折射 UV 偏移（用法线扰动全局 UV）
//     _N.x 在拉伸空间里，折射时需要还原回 UV 空间（乘回 DropStretch）
// ─────────────────────────────────────────────────────────────────────────────

float2 _refUV = UV + _N.xy * float2(DropStretch, 1.0) * 0.07;

// ─────────────────────────────────────────────────────────────────────────────
//  6. 焦散图案 — 3 层正弦波（[unroll] 循环合法，函数定义不合法）
// ─────────────────────────────────────────────────────────────────────────────

// 每粒子 seed 偏移，打破不同粒子间的同质感
float2 _cUV = _refUV;
_cUV.x += frac(sin(_seed * 17.3) * 43758.5) * 4.0;
_cUV.y += frac(sin(_seed * 31.7) * 43758.5) * 4.0;

float _caus = 0.0;
[unroll]
for (int _ci = 0; _ci < 3; _ci++)
{
    float  _fi   = float(_ci);
    float2 _coff = float2(sin(Time*0.25 + _fi*1.618 + _seed*6.28) * 0.6,
                          cos(Time*0.18 + _fi*2.399 + _seed*4.71) * 0.6);
    float2 _cq   = _cUV * 2.8 + _coff;
    _caus += sin(_cq.x + sin(_cq.y + Time*0.08 + _fi)) * 0.5 + 0.5;
}
_caus /= 3.0;

// ─────────────────────────────────────────────────────────────────────────────
//  7. FBM3 值噪声（3倍频，叠加到焦散）
//     值噪声 = 双线性插值 Hash12；Hash12 使用 PCG 风格混合
// ─────────────────────────────────────────────────────────────────────────────

float2   _fp  = _cUV * 3.5 + float2(Time*0.05 + _seed, Time*0.03);
float2x2 _rot = float2x2(1.6, 1.2, -1.2, 1.6);
float _fv = 0.0, _fa = 0.5, _ft = 0.0;

[unroll]
for (int _oi = 0; _oi < 3; _oi++)
{
    float2 _fi2 = floor(_fp);
    float2 _ff  = frac(_fp);
    // Smooth5 插值权重
    float2 _fu  = _ff*_ff*_ff * (_ff*(_ff*6.0 - 15.0) + 10.0);
    // 四角 Hash12（PCG 风格）
    float3 _ha  = frac(float3(_fi2.xyx)                * float3(0.1031,0.1030,0.0973));
    float3 _hb  = frac(float3((_fi2+float2(1,0)).xyx)  * float3(0.1031,0.1030,0.0973));
    float3 _hc  = frac(float3((_fi2+float2(0,1)).xyx)  * float3(0.1031,0.1030,0.0973));
    float3 _hd  = frac(float3((_fi2+float2(1,1)).xyx)  * float3(0.1031,0.1030,0.0973));
    _ha += dot(_ha, _ha.yzx+33.33); float _va = frac((_ha.x+_ha.y)*_ha.z);
    _hb += dot(_hb, _hb.yzx+33.33); float _vb = frac((_hb.x+_hb.y)*_hb.z);
    _hc += dot(_hc, _hc.yzx+33.33); float _vc = frac((_hc.x+_hc.y)*_hc.z);
    _hd += dot(_hd, _hd.yzx+33.33); float _vd = frac((_hd.x+_hd.y)*_hd.z);
    _fv += lerp(lerp(_va,_vb,_fu.x), lerp(_vc,_vd,_fu.x), _fu.y) * _fa;
    _ft += _fa;
    _fa *= 0.5;
    _fp  = mul(_rot, _fp) * 2.1;
}
_caus = saturate(lerp(_caus, _fv/_ft, 0.35));

// ─────────────────────────────────────────────────────────────────────────────
//  8. 内部遮罩 + 着色
//     折射色 → 焦散 → 菲涅尔 → 主/次高光
// ─────────────────────────────────────────────────────────────────────────────

float  _inside = 1.0 - smoothstep(-DropScale*0.02, DropScale*0.04, _dist);
float3 _color  = float3(0.0, 0.0, 0.0);

if (_inside > 0.001)
{
    float3 _col  = lerp(DropColor * 0.6, CausticColor, _caus * 0.7);

    // 菲涅尔（视线与法线夹角越大越亮）
    float  _fres = pow(1.0 - saturate(_N.z), 2.5);  // dot(N, (0,0,1)) = N.z
    _col         = lerp(_col, RimColor * 0.9, _fres * 0.65);

    // 主高光  — H = normalize(L+V)，L=normalize(0.35,0.55,1.0)，V=(0,0,1)
    // 预算 H = normalize(0.293,0.461,0.838 + 0,0,1) = normalize(0.293,0.461,1.838)
    float3 _H   = normalize(float3(0.293, 0.461, 1.838));
    float  _ndh = saturate(dot(_N, _H));
    _col       += RimColor * pow(_ndh, 48.0) * 0.85;

    // 次级高光（玻璃亮斑）
    _col       += pow(_ndh, 180.0) * 0.5;

    _color = _col;
}

// ─────────────────────────────────────────────────────────────────────────────
//  9. 边缘辉光（水滴外轮廓）
// ─────────────────────────────────────────────────────────────────────────────

_color += RimColor * (smoothstep(DropScale*0.25, 0.0, abs(_dist))           * 0.30
                    + smoothstep(DropScale*0.08, 0.0, abs(_dist+DropScale*0.02)) * 0.50);

// ─────────────────────────────────────────────────────────────────────────────
//  10. 粒子颜色调制 + Reinhard 色调映射
// ─────────────────────────────────────────────────────────────────────────────

_color *= ParticleColor;
_color  = _color / (_color + 0.85);

// ─────────────────────────────────────────────────────────────────────────────
//  11. 泪滴形状遮罩（输出到 Alpha，在材质图里与 SphereMask 相乘后接 Opacity）
//
//  材质图接线：
//    Custom.rgb ──► Component Mask RGB ──► Emissive Color
//    Custom.a   ──► Multiply ──────────► Opacity
//                                ↑
//                          SphereMask（覆盖整个精灵，Radius 设大一点如 0.6）
//
//  SphereMask 是 Niagara 里能正常驱动 Opacity 的原生节点，
//  Custom.a 叠在上面把圆形收窄为泪滴形。
// ─────────────────────────────────────────────────────────────────────────────

float _shapeMask = saturate(
    (1.0 - smoothstep(-DropScale*0.02, DropScale*0.04*EdgeSoftness, _dist))
    + smoothstep(DropScale*0.30*EdgeSoftness, 0.0, _dist) * 0.6
);

// 生命周期淡入淡出和粒子 Alpha 保留在这里，不需要移到材质图
_shapeMask *= smoothstep(0.0, FadeInEnd,    _age)
            * smoothstep(1.0, FadeOutStart, _age)
            * ParticleAlpha;

return float4(saturate(_color), saturate(_shapeMask));
