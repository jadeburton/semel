import HelloKit
import SwiftUI

@main
struct HelloApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var taps = 0

    var body: some View {
        VStack(spacing: 16) {
            // From the asset catalog: a compiled image and the accent color.
            Image("Cube")
                .resizable()
                .frame(width: 96, height: 96)
            // From the string catalog: localized, so the language decides the text.
            Text("welcome.title")
                .font(.title)
            // From a package product, linked through its module and object trees.
            Text(Greeting.subtitle)
                .font(.subheadline)
            Button(String(format: NSLocalizedString("taps.count", comment: ""), taps)) { taps += 1 }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}
