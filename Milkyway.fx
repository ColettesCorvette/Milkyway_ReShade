// =============================================================================
// MILKYWAY.FX - Post-traitement multi-passes pour Alien: Isolation
// =============================================================================
//
// Pipeline :
//   1. Etalonnage   (espace gamma)    : contraste à pivot, teinte, vibrance
//   2. AMD CAS      (espace linéaire) : netteté adaptative
//   3. Optique      (espace linéaire) : aberration chromatique, vignette
//   4. Pellicule    (espace gamma)    : grain animé
//
// Conseil : désactiver le grain et l'aberration chromatique du jeu pour
// éviter les doublons (le grain du jeu serait en plus affûté par CAS).
// =============================================================================

// Valeurs de repli pour les éditeurs / analyseurs hors ReShade.
#ifndef BUFFER_WIDTH
    #define BUFFER_WIDTH 2560
    #define BUFFER_HEIGHT 1440
    #define BUFFER_RCP_WIDTH (1.0 / BUFFER_WIDTH)
    #define BUFFER_RCP_HEIGHT (1.0 / BUFFER_HEIGHT)
#endif
#ifndef BUFFER_COLOR_BIT_DEPTH
    #define BUFFER_COLOR_BIT_DEPTH 8
#endif

#include "ReShade.fxh"

// Conversion sRGB matérielle seulement pour un back buffer 8 bits.
#if BUFFER_COLOR_BIT_DEPTH == 8
    #define MILKYWAY_SRGB true
#else
    #define MILKYWAY_SRGB false
#endif

namespace Aliened {

    // =========================================================================
    // 1. Ressources
    // =========================================================================

    // Back buffer lu en espace linéaire (ReShade::BackBuffer est en gamma).
    texture MilkywayBackBufferTex : COLOR;
    sampler sBackBufferLinear
    {
        Texture = MilkywayBackBufferTex;
        SRGBTexture = MILKYWAY_SRGB;
    };

    uniform int iFrameCount < source = "framecount"; >;

    // Nombre d'échantillons de l'aberration chromatique.
    static const int CA_SAMPLES = 8;

    // =========================================================================
    // 2. UI
    // =========================================================================

    // --- 1.1 Etalonnage ---
    uniform bool bEnableGrading <
        ui_category = "1.1 : Etalonnage";
        ui_label = "Activer l'etalonnage";
    > = true;

    uniform float fContrast <
        ui_category = "1.1 : Etalonnage";
        ui_type = "slider";
        ui_min = 0.8; ui_max = 1.5;
        ui_label = "Contraste";
        ui_tooltip = "Courbe en S autour du pivot : 0 et 1 ne bougent pas.";
    > = 1.05;

    uniform float fContrastPivot <
        ui_category = "1.1 : Etalonnage";
        ui_type = "slider";
        ui_min = 0.1; ui_max = 0.9;
        ui_label = "Pivot du contraste";
        ui_tooltip = "Les tons sous le pivot s'assombrissent, ceux au-dessus s'eclaircissent.\nUn pivot bas protege les ombres.";
    > = 0.35;

    uniform float3 cColorTint <
        ui_category = "1.1 : Etalonnage";
        ui_type = "color";
        ui_label = "Teinte globale";
        ui_tooltip = "La luminosite est conservee : seule la dominante change.";
    > = float3(0.96, 1.00, 0.98); // Légère dominante froide/verte Nostromo

    uniform float fVibrance <
        ui_category = "1.1 : Etalonnage";
        ui_type = "slider";
        ui_min = -1.0; ui_max = 1.0;
        ui_label = "Vibrance";
        ui_tooltip = "Sature surtout les couleurs peu saturees.";
    > = 0.20;

    // --- 1.2 Nettete ---
    uniform bool bEnableSharpening <
        ui_category = "1.2 : Nettete (AMD CAS)";
        ui_label = "Activer AMD FidelityFX CAS";
    > = true;

    uniform float fCASSharpness <
        ui_category = "1.2 : Nettete (AMD CAS)";
        ui_type = "slider";
        ui_min = 0.0; ui_max = 1.0;
        ui_label = "Force de l'affutage";
    > = 0.65;

    // --- 1.3 Optique ---
    uniform bool bEnableChromaticAberration <
        ui_category = "1.3 : Optique";
        ui_label = "Activer l'aberration chromatique";
        ui_tooltip = "Desactivee par defaut : le jeu a deja la sienne.";
    > = false;

    uniform float fChromaticAberration <
        ui_category = "1.3 : Optique";
        ui_type = "slider";
        ui_min = 0.0; ui_max = 0.010;
        ui_label = "Aberration chromatique (bords)";
    > = 0.0025;

    uniform bool bEnableVignette <
        ui_category = "1.3 : Optique";
        ui_label = "Activer la vignette";
    > = true;

    uniform float fVignette <
        ui_category = "1.3 : Optique";
        ui_type = "slider";
        ui_min = 0.0; ui_max = 1.0;
        ui_label = "Vignette (coins sombres)";
    > = 0.40;

    // --- 1.4 Pellicule ---
    uniform bool bEnableFilmGrain <
        ui_category = "1.4 : Pellicule 1979";
        ui_label = "Activer le grain";
    > = true;

    uniform float fFilmGrain <
        ui_category = "1.4 : Pellicule 1979";
        ui_type = "slider";
        ui_min = 0.0; ui_max = 0.15;
        ui_label = "Grain de pellicule 35mm";
    > = 0.04;

    // =========================================================================
    // 3. Fonctions utilitaires
    // =========================================================================

    float GetLuma(float3 c)
    {
        return dot(c, float3(0.2126, 0.7152, 0.0722));
    }

    // Courbe de contraste en S : 0 -> 0, pivot -> pivot, 1 -> 1.
    // La pente au pivot vaut "contrast", sans écrêtage.
    float3 MilkywayContrast(float3 c, float contrast, float pivot)
    {
        c = saturate(c);
        float3 low  = pivot * pow(c / pivot, contrast);
        float3 high = 1.0 - (1.0 - pivot) * pow((1.0 - c) / (1.0 - pivot), contrast);
        return lerp(high, low, step(c, pivot.xxx));
    }

    // Hash sans sin() (Dave Hoskins) : stable quelle que soit la durée de jeu.
    float MilkywayHash13(float3 p3)
    {
        p3 = frac(p3 * 0.1031);
        p3 += dot(p3, p3.zyx + 31.32);
        return frac((p3.x + p3.y) * p3.z);
    }

    // =========================================================================
    // 4. Pixel shaders
    // =========================================================================

    // --- 1. Etalonnage (gamma) ---
    float4 PS_Grading(float4 vpos : SV_Position, float2 uv : TEXCOORD) : SV_Target
    {
        float4 original = tex2D(ReShade::BackBuffer, uv);
        if (!bEnableGrading)
            return original;

        float3 c = MilkywayContrast(original.rgb, fContrast, fContrastPivot);

        // Teinte normalisée : change la dominante sans assombrir l'image.
        c *= cColorTint / max(GetLuma(cColorTint), 0.0001);

        // Vibrance sur la saturation relative : une ombre très colorée
        // n'est plus considérée comme désaturée.
        float maxChannel = max(c.r, max(c.g, c.b));
        float minChannel = min(c.r, min(c.g, c.b));
        float sat = (maxChannel - minChannel) / max(maxChannel, 0.0001);
        float luma = GetLuma(c);
        c = lerp(luma.xxx, c, 1.0 + fVibrance * (1.0 - sat));

        return float4(saturate(c), original.a);
    }

    // --- 2. AMD FidelityFX CAS (linéaire) ---
    // Version non mise à l'échelle de CAS : min/max sur la croix + 3x3.
    float4 PS_CAS(float4 vpos : SV_Position, float2 uv : TEXCOORD) : SV_Target
    {
        float4 center = tex2D(sBackBufferLinear, uv);
        if (!bEnableSharpening)
            return center;

        float2 px = ReShade::PixelSize;

        // a b c
        // d e f
        // g h i
        float3 a = tex2D(sBackBufferLinear, uv + float2(-px.x, -px.y)).rgb;
        float3 b = tex2D(sBackBufferLinear, uv + float2(  0.0, -px.y)).rgb;
        float3 c = tex2D(sBackBufferLinear, uv + float2( px.x, -px.y)).rgb;
        float3 d = tex2D(sBackBufferLinear, uv + float2(-px.x,   0.0)).rgb;
        float3 e = center.rgb;
        float3 f = tex2D(sBackBufferLinear, uv + float2( px.x,   0.0)).rgb;
        float3 g = tex2D(sBackBufferLinear, uv + float2(-px.x,  px.y)).rgb;
        float3 h = tex2D(sBackBufferLinear, uv + float2(  0.0,  px.y)).rgb;
        float3 i = tex2D(sBackBufferLinear, uv + float2( px.x,  px.y)).rgb;

        float3 mnRGB = min(min(min(d, e), min(f, b)), h);
        float3 mxRGB = max(max(max(d, e), max(f, b)), h);
        mnRGB += min(mnRGB, min(min(a, c), min(g, i)));
        mxRGB += max(mxRGB, max(max(a, c), max(g, i)));

        // Moins d'affûtage là où le contraste local est déjà fort (pas de halos).
        float3 amp = sqrt(saturate(min(mnRGB, 2.0 - mxRGB) / max(mxRGB, 0.0001)));

        float peak = -1.0 / lerp(8.0, 5.0, fCASSharpness);
        float3 w = amp * peak;

        float3 sharpened = ((b + d + f + h) * w + e) / (1.0 + 4.0 * w);
        return float4(saturate(sharpened), center.a);
    }

    // --- 3. Optique : aberration chromatique + vignette (linéaire) ---
    float4 PS_Optics(float4 vpos : SV_Position, float2 uv : TEXCOORD) : SV_Target
    {
        float4 original = tex2D(sBackBufferLinear, uv);
        float3 color = original.rgb;

        float2 centered = uv - 0.5;

        // Aberration chromatique radiale : plusieurs échantillons répartis
        // entre rouge et bleu pour un dégradé au lieu d'une image dédoublée.
        if (bEnableChromaticAberration && fChromaticAberration > 0.0)
        {
            float2 maxOffset = centered * dot(centered, centered) * (fChromaticAberration * 4.0);

            float3 sum = 0.0;
            float3 weightSum = 0.0;

            [unroll]
            for (int s = 0; s < CA_SAMPLES; s++)
            {
                float t = float(s) / float(CA_SAMPLES - 1);       // 0 -> 1
                float3 weight = float3(t, 1.0 - abs(t * 2.0 - 1.0), 1.0 - t);
                float2 offset = maxOffset * (t * 2.0 - 1.0);       // -1 -> 1

                sum += tex2D(sBackBufferLinear, saturate(uv + offset)).rgb * weight;
                weightSum += weight;
            }

            color = sum / weightSum;
        }

        // Vignette douce, atténuée au milieu des bords haut et bas.
        if (bEnableVignette)
        {
            float2 vignetteUV = centered * 2.0;
            vignetteUV.y *= 0.65;
            float edge = smoothstep(0.65, 1.15, length(vignetteUV));
            color *= 1.0 - edge * fVignette;
        }

        return float4(color, original.a);
    }

    // --- 4. Pellicule : grain animé (gamma) ---
    float4 PS_FilmGrain(float4 vpos : SV_Position, float2 uv : TEXCOORD) : SV_Target
    {
        float4 original = tex2D(ReShade::BackBuffer, uv);
        if (!bEnableFilmGrain)
            return original;

        // Graine liée au pixel et à l'image courante (modulo pour garder la précision).
        float frame = float(iFrameCount % 4096);
        float n1 = MilkywayHash13(float3(vpos.xy, frame));
        float n2 = MilkywayHash13(float3(vpos.xy, frame + 1024.0));
        float noise = n1 + n2 - 1.0; // distribution triangulaire, -1 -> 1

        // Grain présent dans les ombres et les tons moyens, plus discret dans
        // les hautes lumières ; le noir pur (menus, bandes noires) est épargné.
        float luma = GetLuma(original.rgb);
        float mask = smoothstep(0.0, 0.03, luma) * (1.0 - 0.75 * luma);

        float3 color = original.rgb + noise * fFilmGrain * mask;
        return float4(saturate(color), original.a);
    }

    // =========================================================================
    // 5. Technique
    // =========================================================================

    technique MilkywayTech <
        ui_label = "Milkyway (Aliened)";
        ui_tooltip = "Pipeline : 1.Etalonnage -> 2.AMD CAS -> 3.Optique -> 4.Grain";
    >
    {
        pass Grading
        {
            VertexShader = PostProcessVS;
            PixelShader = PS_Grading;
        }
        pass CAS
        {
            VertexShader = PostProcessVS;
            PixelShader = PS_CAS;
            SRGBWriteEnable = MILKYWAY_SRGB;
        }
        pass Optics
        {
            VertexShader = PostProcessVS;
            PixelShader = PS_Optics;
            SRGBWriteEnable = MILKYWAY_SRGB;
        }
        pass FilmGrain
        {
            VertexShader = PostProcessVS;
            PixelShader = PS_FilmGrain;
        }
    }

}
