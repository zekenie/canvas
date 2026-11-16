import Canvas
import DetailPanel

/// The rules a shape is held to: a type's English rules (LanguageRules) and the constraints a container holds its shapes to
/// (Constraints) are sections of this one tab, so it is declared here, below both. It shows only where a plugin puts a
/// section in it, and comes after a type's Schema and before Style (and Issues, which trails them all).
public enum RulesTab {}

extension RulesTab: DetailTab {
    public static var title: String { ValidationStyle.rulesTab }
    public static var order: Order<Self> { .before(StyleTab.self) }
}
