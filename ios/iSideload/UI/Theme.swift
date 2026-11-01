import SwiftUI

enum Theme {
    static let gradient = LinearGradient(colors: [Color(red: 1.0, green: 0.27, blue: 0.48),
                                                  Color(red: 0.55, green: 0.29, blue: 1.0),
                                                  Color(red: 0.0, green: 0.72, blue: 1.0)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)
    static let accent = Color(red: 0.55, green: 0.29, blue: 1.0)
    static let palette: [Color] = [.pink, .orange, .yellow, .green, .teal, .blue, .purple]
    static func color(for s: String) -> Color { palette[abs(s.hashValue) % palette.count] }
}

struct GradientButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline).foregroundStyle(.white)
            .padding(.vertical, 12).frame(maxWidth: .infinity)
            .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 14))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct Badge: View {
    var text: String; var color: Color
    var body: some View {
        Text(text).font(.caption.bold()).foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color, in: Capsule())
    }
}

struct LetterIcon: View {
    var name: String
    var body: some View {
        let c = Theme.color(for: name)
        Text(String(name.prefix(1)).uppercased())
            .font(.title2.bold()).foregroundStyle(.white)
            .frame(width: 46, height: 46)
            .background(LinearGradient(colors: [c, c.opacity(0.6)], startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: 11))
    }
}
