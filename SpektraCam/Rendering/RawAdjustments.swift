import Foundation

/// Shared by the film buffer graph and LUT texture graph. Decode/WB/tint/saturation precede this block.
nonisolated enum RawAdjustments {
    enum Failure: LocalizedError {
        case parameters
        var errorDescription: String? {
            String(
                localized: "render.error.raw_adjustments",
                defaultValue: "The RAW adjustment values are not supported.")
        }
    }
    static func validate(_ tone: EditRecipe.Tone) throws {
        guard
            [tone.exposureEV, tone.contrast, tone.pivot, tone.shadows, tone.highlights].allSatisfy(
                \.isFinite),
            (1...5).contains(tone.algorithm), (-10...10).contains(tone.exposureEV),
            (0.25...2).contains(tone.contrast), (0...1).contains(tone.pivot),
            (-5...5).contains(tone.shadows), (-10...10).contains(tone.highlights)
        else { throw Failure.parameters }
    }
    static func parameters(_ tone: EditRecipe.Tone, normalizationEV: Double = 0) -> [Float] {
        [
            Float(tone.contrast), Float(tone.pivot), Float(tone.shadows), Float(tone.highlights),
            Float(tone.exposureEV), Float(tone.algorithm), Float(normalizationEV), 0,
        ]
    }
    static let shader = """
        float rawEncode(float x) { return x<=0.0031308f ? 12.92f*x : 1.055f*pow(x,1.0f/2.4f)-0.055f; }
        float rawDecode(float x) { return x<=0.04045f ? x/12.92f : pow((x+0.055f)/1.055f,2.4f); }
        float rawCurve(float x, float4 p, float algorithm) {
            if(x<=0.0f || x>=1.0f) return x;
            float pivot=clamp(p.y,0.0001f,0.9999f);
            if(algorithm>=3.5f) {
                float lifted=x<=pivot ? pivot*pow(x/pivot,exp2(-p.z)) : x;
                if(p.x==1.0f) return lifted;
                float slope=p.x/max(2.0f-p.x,0.01f);
                float center=log(pivot/(1-pivot));
                float odds=slope*(log(lifted/(1-lifted))-center)+center;
                return odds>=0 ? 1/(1+exp(-odds)) : exp(odds)/(1+exp(odds));
            }
            if(x<=pivot) { float t=x/pivot; float lifted=algorithm>=2.5f ? pow(t,exp2(-p.z)) : t+p.z*t*(1-t)*(1-t); return pivot*pow(lifted,p.x); }
            float t=(1-x)/(1-pivot), shifted=algorithm<1.5f ? t-p.w*t*(1-t)*(1-t) : t;
            return 1-(1-pivot)*pow(shifted,p.x);
        }
        float3 applyRaw(float3 rgb, constant float4 *p, float normalizationEV) {
            rgb*=exp2(p[1].x);
            if(p[1].y>=4.5f) {
                // A scene-referred luminance curve: no SDR white cutoff, no per-channel hue shifts.
                float y=dot(rgb,float3(0.2126f,0.7152f,0.0722f));
                if(y<=1e-10f) return rgb;
                float x=y*exp2(normalizationEV);
                float width=max(1.0f,abs(p[0].z-p[0].w)/4.0f);
                float odds=exp2(log2(x/0.18f)/width);
                float highlightWeight=odds/(1+odds);
                float stops=p[0].z*(1-highlightWeight)+p[0].w*highlightWeight;
                float lifted=x*exp2(stops);
                float pivot=rawDecode(clamp(p[0].y,0.0001f,0.9999f));
                float distance=log2(max(lifted,1e-20f)/pivot);
                float bend=(p[0].x-1.0f)*4.0f*tanh(distance/4.0f);
                return rgb*exp2(stops+bend);
            }
            bool legacy=p[1].y<1.5f;
            if(!legacy && p[0].w!=0) {
                float y=dot(rgb,float3(0.2126f,0.7152f,0.0722f));
                const float start=0.18f, span=0.5f;
                if(y>start) {
                    float d=y-start, amount=exp2(abs(p[0].w))-1.0f;
                    float lifted=p[0].w<0 ? start+span/amount*asinh(amount*d/span) : start+d*(1+amount*d/(d+span));
                    rgb*=lifted/y;
                }
            }
            float3 code=float3(rawEncode(rgb.r),rawEncode(rgb.g),rawEncode(rgb.b));
            code=float3(rawCurve(code.r,p[0],p[1].y),rawCurve(code.g,p[0],p[1].y),rawCurve(code.b,p[0],p[1].y));
            return float3(rawDecode(code.r),rawDecode(code.g),rawDecode(code.b));
        }
        """
    static let bufferKernel = """
        kernel void raw_adjust_image(device float4 *pixels [[buffer(0)]], constant float4 *p [[buffer(1)]],
                                     constant uint &n [[buffer(2)]], uint i [[thread_position_in_grid]]) {
            if(i<n) pixels[i]=float4(applyRaw(pixels[i].rgb,p,p[1].z),1);
        }
        """
}
