import SwiftUI

/// 浮层底衬。26+ 用 `glassEffect`(在 SwiftUICore,不描边);更早仍是材质 + 描边 + 阴影。几何由调用点决定。
struct AdaptiveGlassSurface<S: InsettableShape>: View {
    var shape: S
    /// 26 以下的描边;传 `nil` 表示原来就没有描边(别凭空加一层)。
    var legacyStroke: AnyShapeStyle? = AnyShapeStyle(Color.primary.opacity(0.12))
    /// 投影。`0` = 不加(原来没有投影的调用点传 0,避免多一层离屏合成)。
    var shadowOpacity: Double = 0.16
    var shadowRadius: CGFloat = 8
    var shadowY: CGFloat = 3

    var body: some View {
        if #available(macOS 26.0, *) {
            elevated(Color.clear.glassEffect(.regular, in: shape))
        } else {
            elevated(legacySurface)
        }
    }

    // MARK: 两套观感

    @ViewBuilder
    private var legacySurface: some View {
        let base = shape.fill(.regularMaterial)
        if let legacyStroke {
            base.overlay(shape.strokeBorder(legacyStroke, lineWidth: 0.5))
        } else {
            base
        }
    }

    @ViewBuilder
    private func elevated<V: View>(_ content: V) -> some View {
        if shadowOpacity > 0 {
            content.shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius, y: shadowY)
        } else {
            content
        }
    }
}

/// 按钮底衬,占位仍是 24×20。26+ 静止透明,hover/选中用交互玻璃;更早用纯色填充。
struct AdaptiveButtonFill: View {
    var emphasized: Bool
    var hovering: Bool
    var disabled: Bool
    var cornerRadius: CGFloat
    /// 强调玻璃的 tint 浓度。默认 0.45,与导出按钮一致 ——
    /// 满强度 tint 在纯色内容底下读起来太重。
    var tintStrength: CGFloat = 0.45

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius) }

    var body: some View {
        if #available(macOS 26.0, *) {
            if !disabled && (emphasized || hovering) {
                Color.clear.glassEffect(interactiveGlass, in: shape)
            } else {
                Color.clear
            }
        } else {
            shape.fill(
                emphasized
                    ? Color.accentColor.opacity(0.18)
                    : (hovering && !disabled ? Color.primary.opacity(0.08) : Color.clear)
            )
        }
    }

    /// 选中 = 玻璃 + accent 色调;hover = 素玻璃。
    @available(macOS 26.0, *)
    private var interactiveGlass: Glass {
        if emphasized {
            let tint = Color.accentColor.opacity(tintStrength)
            return .regular.tint(tint).interactive()
        }
        return .regular.interactive()
    }
}
