import Foundation

enum AppResources {
    static func url(forResource name: String, withExtension extensionName: String) -> URL? {
        // Installed .app bundles keep these in Contents/Resources. SwiftPM
        // development builds keep them in the generated resource bundle.
        Bundle.main.url(forResource: name, withExtension: extensionName)
            ?? Bundle.module.url(forResource: name, withExtension: extensionName)
    }
}
