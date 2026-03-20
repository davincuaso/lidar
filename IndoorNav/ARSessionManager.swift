import Foundation
import ARKit
import SceneKit
import Combine

enum AppMode: String, CaseIterable, Identifiable {
    case mapping = "Map the Space"
    case navigation = "Navigate"

    var id: String { rawValue }
}

class ARSessionManager: NSObject, ObservableObject {

    // MARK: - Published State (shared)

    @Published var appMode: AppMode = .mapping
    @Published var worldMappingStatus: ARFrame.WorldMappingStatus = .notAvailable
    @Published var trackingState: ARCamera.TrackingState = .notAvailable
    @Published var sessionInfoText: String = "Initializing AR..."
    @Published var isSceneReconstructionSupported = false

    // MARK: - Published State (mapping)

    @Published var droppedAnchors: [NavigationAnchor] = []
    @Published var isSavingMap = false
    @Published var mapSaveResult: String?

    // MARK: - Published State (navigation)

    @Published var isRelocalized = false
    @Published var loadedDestinations: [NavigationAnchor] = []
    @Published var selectedDestination: NavigationAnchor?
    @Published var isLoadingMap = false
    @Published var navigationError: String?
    @Published var distanceToDestination: Float?

    // MARK: - AR Objects

    let sceneView = ARSCNView()

    // MARK: - Path Rendering

    private let pathContainerNode = SCNNode()
    private var lastPathUpdateTime: TimeInterval = 0
    private let pathSpacing: Float = 0.3

    private lazy var pathDotGeometry: SCNSphere = {
        let s = SCNSphere(radius: 0.015)
        s.segmentCount = 8
        s.firstMaterial?.diffuse.contents = UIColor.systemCyan
        s.firstMaterial?.lightingModel = .constant
        return s
    }()

    private lazy var pathArrowGeometry: SCNCone = {
        let c = SCNCone(topRadius: 0, bottomRadius: 0.03, height: 0.06)
        c.radialSegmentCount = 8
        c.firstMaterial?.diffuse.contents = UIColor.systemCyan
        c.firstMaterial?.lightingModel = .constant
        return c
    }()

    // MARK: - File Storage

    static var worldMapURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("IndoorNavWorldMap.arexperience")
    }

    // MARK: - Init

    override init() {
        super.init()
        sceneView.delegate = self
        sceneView.session.delegate = self
        sceneView.automaticallyUpdatesLighting = true
        sceneView.scene.rootNode.addChildNode(pathContainerNode)
    }

    // MARK: - Session Lifecycle

    func startMappingSession() {
        isRelocalized = false
        loadedDestinations = []
        selectedDestination = nil
        navigationError = nil
        distanceToDestination = nil
        clearPath()

        droppedAnchors = []
        mapSaveResult = nil

        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        config.environmentTexturing = .automatic

        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
            isSceneReconstructionSupported = true
        }

        sceneView.debugOptions = [.showFeaturePoints]
        sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        sessionInfoText = "Mapping — move around slowly"
    }

    func startNavigationSession() {
        isRelocalized = false
        loadedDestinations = []
        selectedDestination = nil
        navigationError = nil
        distanceToDestination = nil
        isLoadingMap = true
        clearPath()

        guard savedMapExists else {
            navigationError = "No saved map found. Map the space first."
            sessionInfoText = "No map available"
            isLoadingMap = false
            return
        }

        do {
            let data = try Data(contentsOf: Self.worldMapURL)
            guard let worldMap = try NSKeyedUnarchiver.unarchivedObject(
                ofClass: ARWorldMap.self, from: data
            ) else {
                navigationError = "Could not decode world map"
                sessionInfoText = "Map load failed"
                isLoadingMap = false
                return
            }

            loadedDestinations = worldMap.anchors.compactMap { $0 as? NavigationAnchor }

            let config = ARWorldTrackingConfiguration()
            config.planeDetection = [.horizontal, .vertical]
            config.environmentTexturing = .automatic
            config.initialWorldMap = worldMap

            if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
                config.sceneReconstruction = .mesh
            }

            sceneView.debugOptions = [.showFeaturePoints]
            sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])

            sessionInfoText = "Look around slowly to localize..."
            isLoadingMap = false
        } catch {
            navigationError = "Failed to load map: \(error.localizedDescription)"
            sessionInfoText = "Map load failed"
            isLoadingMap = false
        }
    }

    func pauseSession() {
        sceneView.session.pause()
    }

    // MARK: - Mapping: Drop Anchor

    func dropAnchor(named name: String) {
        guard let frame = sceneView.session.currentFrame else {
            sessionInfoText = "Cannot drop anchor — no AR frame"
            return
        }
        let anchor = NavigationAnchor(name: name, transform: frame.camera.transform)
        sceneView.session.add(anchor: anchor)
        droppedAnchors.append(anchor)
        sessionInfoText = "Dropped \"\(name)\""
    }

    func removeAnchor(_ anchor: NavigationAnchor) {
        sceneView.session.remove(anchor: anchor)
        droppedAnchors.removeAll { $0.identifier == anchor.identifier }
    }

    // MARK: - Mapping: Save World Map

    func saveWorldMap() {
        isSavingMap = true
        mapSaveResult = nil
        sessionInfoText = "Saving world map..."

        sceneView.session.getCurrentWorldMap { [weak self] worldMap, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isSavingMap = false

                guard let worldMap else {
                    let msg = error?.localizedDescription ?? "Unknown error"
                    self.mapSaveResult = "Save failed: \(msg)"
                    self.sessionInfoText = "Save failed"
                    return
                }

                do {
                    let data = try NSKeyedArchiver.archivedData(
                        withRootObject: worldMap,
                        requiringSecureCoding: true
                    )
                    try data.write(to: Self.worldMapURL, options: [.atomic])

                    let anchorCount = worldMap.anchors.compactMap { $0 as? NavigationAnchor }.count
                    self.mapSaveResult = "Saved (\(anchorCount) destination\(anchorCount == 1 ? "" : "s"))"
                    self.sessionInfoText = "World map saved successfully"
                } catch {
                    self.mapSaveResult = "Save failed: \(error.localizedDescription)"
                    self.sessionInfoText = "Save failed"
                }
            }
        }
    }

    var canSaveMap: Bool {
        worldMappingStatus == .mapped || worldMappingStatus == .extending
    }

    var savedMapExists: Bool {
        FileManager.default.fileExists(atPath: Self.worldMapURL.path)
    }

    // MARK: - Navigation: Destination Selection

    func selectDestination(_ destination: NavigationAnchor) {
        selectedDestination = destination
        sessionInfoText = "Navigating to \"\(destination.destinationName)\""
    }

    func clearNavigation() {
        selectedDestination = nil
        distanceToDestination = nil
        clearPath()
        if isRelocalized {
            sessionInfoText = "Select a destination"
        }
    }

    // MARK: - Path Rendering

    private func clearPath() {
        pathContainerNode.childNodes.forEach { $0.removeFromParentNode() }
    }

    private func rebuildPath(from start: SIMD3<Float>, to end: SIMD3<Float>) {
        clearPath()

        let direction = end - start
        let distance = simd_length(direction)
        guard distance > 0.1 else { return }

        let step = min(pathSpacing, distance)
        let count = max(Int(distance / step), 1)
        let normalized = simd_normalize(direction)

        for i in 1...count {
            let t = Float(i) / Float(count)
            let pos = start + normalized * (Float(i) * step)

            let isLast = i == count
            let node: SCNNode
            if isLast {
                node = SCNNode(geometry: pathArrowGeometry.copy() as? SCNGeometry)
            } else {
                node = SCNNode(geometry: pathDotGeometry.copy() as? SCNGeometry)
            }

            let green = CGFloat(1.0 - t)
            let blue = CGFloat(t)
            node.geometry?.firstMaterial?.diffuse.contents = UIColor(
                red: 0, green: 0.5 + green * 0.3, blue: 0.5 + blue * 0.5, alpha: 0.85
            )

            node.simdWorldPosition = pos
            pathContainerNode.addChildNode(node)
        }
    }

    // MARK: - Helpers

    var worldMappingStatusText: String {
        switch worldMappingStatus {
        case .notAvailable: return "Not Available"
        case .limited:      return "Limited"
        case .extending:    return "Extending"
        case .mapped:       return "Mapped"
        @unknown default:   return "Unknown"
        }
    }

    var trackingStateText: String {
        switch trackingState {
        case .notAvailable:
            return "Not Available"
        case .limited(let reason):
            switch reason {
            case .initializing:         return "Initializing"
            case .excessiveMotion:      return "Slow Down"
            case .insufficientFeatures: return "Low Detail"
            case .relocalizing:         return "Relocalizing"
            @unknown default:           return "Limited"
            }
        case .normal:
            return "Normal"
        }
    }
}

// MARK: - ARSCNViewDelegate

extension ARSessionManager: ARSCNViewDelegate {

    func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
        guard let navAnchor = anchor as? NavigationAnchor else { return nil }

        let isNavMode = appMode == .navigation
        let markerColor: UIColor = isNavMode ? .systemGreen : .systemBlue

        let sphere = SCNSphere(radius: 0.05)
        sphere.firstMaterial?.diffuse.contents = markerColor
        sphere.firstMaterial?.lightingModel = .physicallyBased
        let sphereNode = SCNNode(geometry: sphere)

        let text = SCNText(string: navAnchor.destinationName, extrusionDepth: 0.5)
        text.font = UIFont.systemFont(ofSize: 4, weight: .bold)
        text.firstMaterial?.diffuse.contents = UIColor.white
        text.flatness = 0.1

        let textNode = SCNNode(geometry: text)
        let (min, max) = textNode.boundingBox
        let dx = (max.x - min.x) / 2
        textNode.position = SCNVector3(-dx, 0.06, 0)
        textNode.scale = SCNVector3(0.01, 0.01, 0.01)

        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .Y
        textNode.constraints = [billboard]

        let container = SCNNode()
        container.addChildNode(sphereNode)
        container.addChildNode(textNode)

        if isNavMode {
            let pulse = SCNAction.sequence([
                .scale(to: 1.2, duration: 0.5),
                .scale(to: 1.0, duration: 0.5)
            ])
            sphereNode.runAction(.repeatForever(pulse))
        }

        return container
    }

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        guard appMode == .navigation,
              isRelocalized,
              let destination = selectedDestination,
              let pov = sceneView.pointOfView else {
            if !pathContainerNode.childNodes.isEmpty {
                clearPath()
                DispatchQueue.main.async { [weak self] in
                    self?.distanceToDestination = nil
                }
            }
            return
        }

        guard time - lastPathUpdateTime > 0.1 else { return }
        lastPathUpdateTime = time

        let cameraPos = pov.simdWorldPosition
        let col3 = destination.transform.columns.3
        let destPos = SIMD3<Float>(col3.x, col3.y, col3.z)
        let dist = simd_length(destPos - cameraPos)

        rebuildPath(from: cameraPos, to: destPos)

        DispatchQueue.main.async { [weak self] in
            self?.distanceToDestination = dist
        }
    }
}

// MARK: - ARSessionDelegate

extension ARSessionManager: ARSessionDelegate {

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let mapping = frame.worldMappingStatus
        let tracking = frame.camera.trackingState

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.worldMappingStatus = mapping
            self.trackingState = tracking

            if self.appMode == .navigation && !self.isRelocalized {
                if case .normal = tracking {
                    self.isRelocalized = true
                }
            }

            self.updateSessionInfo()
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.sessionInfoText = "Session error: \(error.localizedDescription)"
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        DispatchQueue.main.async { [weak self] in
            self?.sessionInfoText = "Session interrupted"
        }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        DispatchQueue.main.async { [weak self] in
            self?.sessionInfoText = "Session resumed"
        }
    }

    // MARK: - Private

    private func updateSessionInfo() {
        if isSavingMap { return }

        switch trackingState {
        case .notAvailable:
            sessionInfoText = "AR not available on this device"
        case .limited(let reason):
            switch reason {
            case .initializing:
                sessionInfoText = appMode == .navigation
                    ? "Look around slowly to localize..."
                    : "Initializing — move the device slowly"
            case .excessiveMotion:
                sessionInfoText = "Too much motion — slow down"
            case .insufficientFeatures:
                sessionInfoText = "Not enough detail — point at a textured surface"
            case .relocalizing:
                sessionInfoText = "Relocalizing — revisit a previously mapped area"
            @unknown default:
                sessionInfoText = "Limited tracking"
            }
        case .normal:
            switch appMode {
            case .mapping:
                sessionInfoText = "Tracking: \(worldMappingStatusText)"
            case .navigation:
                if let dest = selectedDestination {
                    if let dist = distanceToDestination {
                        sessionInfoText = String(format: "Navigating to \"%@\" — %.1f m away",
                                                 dest.destinationName, dist)
                    } else {
                        sessionInfoText = "Navigating to \"\(dest.destinationName)\""
                    }
                } else {
                    sessionInfoText = "Localized! Select a destination."
                }
            }
        }
    }
}
