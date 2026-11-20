import SwiftUI

@MainActor
struct ContentView: View {
    let model: WallModel
    let languageSettings: LanguageSettings

    var body: some View {
        WallView(model: model, languageSettings: languageSettings)
    }
}

@MainActor
struct ContentView_Previews: PreviewProvider {
    private static let languageSettings = LanguageSettings()
    private static let model = WallModel(languageSettings: languageSettings)

    static var previews: some View {
        ContentView(model: model, languageSettings: languageSettings)
            .frame(width: 1536, height: 1024)
    }
}
