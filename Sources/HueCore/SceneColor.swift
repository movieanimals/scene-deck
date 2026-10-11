import Foundation

/// Standard sRGB / D65 XYZ conversion. Preview is approximate; bulb gamut varies.
/// Reference: https://www.w3.org/TR/css-color-4/#color-conversion-code
public enum SceneColor {
    public static func xy(red: Double, green: Double, blue: Double) -> SceneXY? {
        guard [red, green, blue].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return nil }
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let r = linear(red), g = linear(green), b = linear(blue)
        let x = 0.4123907993*r + 0.3575843394*g + 0.1804807884*b
        let y = 0.2126390059*r + 0.7151686788*g + 0.0721923154*b
        let z = 0.0193308187*r + 0.1191947798*g + 0.9505321522*b
        guard x+y+z > 0 else { return nil }
        return SceneXY(x: x/(x+y+z), y: y/(x+y+z))
    }
    public static func rgb(_ xy: SceneXY) -> (red: Double, green: Double, blue: Double) {
        guard xy.x.isFinite, xy.y.isFinite, xy.x >= 0, xy.y > 0, xy.x+xy.y <= 1 else { return (1,1,1) }
        let x = xy.x/xy.y, z = (1-xy.x-xy.y)/xy.y
        let r = max(0, 3.2409699419*x - 1.5373831776 - 0.4986107603*z)
        let g = max(0, -0.9692436363*x + 1.8759675015 + 0.0415550574*z)
        let b = max(0, 0.0556300797*x - 0.2039769589 + 1.0569715142*z)
        let scale = max(1, r, g, b)
        func encoded(_ v: Double) -> Double { let v = v/scale; return min(1, max(0, v <= 0.0031308 ? 12.92*v : 1.055*pow(v, 1/2.4)-0.055)) }
        return (encoded(r), encoded(g), encoded(b))
    }
}
