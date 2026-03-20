import SwiftUI
import ARKit

struct ARViewContainer: UIViewRepresentable {
    let sessionManager: ARSessionManager

    func makeUIView(context: Context) -> ARSCNView {
        sessionManager.sceneView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
