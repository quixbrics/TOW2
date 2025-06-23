import SwiftUI

@main
struct PointCloudDepthSample: App {
    @StateObject private var arProvider = ARProvider()
    @StateObject private var audioModel = AudioReactiveModel()
    @State private var confSelection: Int = 0

    var body: some Scene {
        WindowGroup {
            MetalPointCloud(
                arData: arProvider,
                confSelection: $confSelection,
                scaleMovement: $audioModel.amplitude // Must be a binding
            )
            .ignoresSafeArea()
        }
    }
}
