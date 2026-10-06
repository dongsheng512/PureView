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

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius) }

    var body: some View {
        if #available(macOS 26.0, *) {
            if !disabled && (emphasized || hovering) {
                Color.clear
                    .glassEffect(interactiveGlass, in: shape)
                    // 玻璃自带的 rim 在 Menu label 里会被裁掉一段(导出按钮左缘缺一截),
                    // 显式补一条画在形状内侧的完整描边,与系统 rim 观感一致。
                    .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
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

    /// 选中 = 素玻璃(无 tint,与整排按钮同一玻璃语言);hover = 素玻璃。
    @available(macOS 26.0, *)
    private var interactiveGlass: Glass {
        if emphasized {
            return .regular.interactive()
        }
        return .regular.interactive()
    }
}
