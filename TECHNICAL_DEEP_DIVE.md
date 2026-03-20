# IndoorNav — Technical Deep Dive

A comprehensive guide to understanding how every part of this AR indoor navigation system works, from the physics of how your phone tracks itself in space to the graph algorithm that routes you around walls.

---

## Table of Contents

1. [The Big Picture](#1-the-big-picture)
2. [How ARKit Tracks Your Phone in 3D Space](#2-how-arkit-tracks-your-phone-in-3d-space)
   - [Visual-Inertial Odometry (VIO)](#visual-inertial-odometry-vio)
   - [Feature Points](#feature-points)
   - [Plane Detection](#plane-detection)
   - [LiDAR Scene Reconstruction](#lidar-scene-reconstruction)
3. [The Coordinate System](#3-the-coordinate-system)
   - [World Origin](#world-origin)
   - [The 4x4 Transform Matrix](#the-4x4-transform-matrix)
   - [Reading a Position from a Transform](#reading-a-position-from-a-transform)
4. [Anchors — Pinning Virtual Objects to the Real World](#4-anchors--pinning-virtual-objects-to-the-real-world)
   - [What Is an ARAnchor?](#what-is-an-aranchor)
   - [Our Custom NavigationAnchor](#our-custom-navigationanchor)
   - [NSSecureCoding — Why Serialization Matters](#nssecurecoding--why-serialization-matters)
5. [The ARWorldMap — Capturing a Snapshot of Reality](#5-the-arworldmap--capturing-a-snapshot-of-reality)
   - [What's Inside an ARWorldMap](#whats-inside-an-arworldmap)
   - [Saving the Map to Disk](#saving-the-map-to-disk)
   - [Where Files Are Stored](#where-files-are-stored)
6. [Relocalization — Finding Your Place Again](#6-relocalization--finding-your-place-again)
   - [How It Works](#how-it-works)
   - [Why Lighting Matters](#why-lighting-matters)
   - [How We Detect It in Code](#how-we-detect-it-in-code)
7. [Waypoints — Building a Walkable Network](#7-waypoints--building-a-walkable-network)
   - [Why Straight Lines Don't Work](#why-straight-lines-dont-work)
   - [Auto-Drop Mechanism](#auto-drop-mechanism)
   - [The Waypoint Graph](#the-waypoint-graph)
8. [Pathfinding — Dijkstra's Algorithm](#8-pathfinding--dijkstras-algorithm)
   - [Graph Construction](#graph-construction)
   - [The Algorithm Step by Step](#the-algorithm-step-by-step)
   - [Path Reconstruction](#path-reconstruction)
   - [The Virtual Start Node](#the-virtual-start-node)
   - [Worked Example](#worked-example)
9. [Rendering — Drawing 3D Objects in AR](#9-rendering--drawing-3d-objects-in-ar)
   - [SceneKit and ARSCNView](#scenekit-and-arscnview)
   - [How Anchor Nodes Are Created](#how-anchor-nodes-are-created)
   - [Path Dot Rendering](#path-dot-rendering)
   - [The Render Loop](#the-render-loop)
10. [The SwiftUI ↔ UIKit Bridge](#10-the-swiftui--uikit-bridge)
    - [UIViewRepresentable](#uiviewrepresentable)
    - [ObservableObject and @Published](#observableobject-and-published)
11. [Threading Model](#11-threading-model)
12. [Complete Data Flow: Mapping to Navigation](#12-complete-data-flow-mapping-to-navigation)
13. [File-by-File Code Walkthrough](#13-file-by-file-code-walkthrough)
14. [Key Apple Frameworks Used](#14-key-apple-frameworks-used)
15. [Glossary](#15-glossary)

---

## 1. The Big Picture

The app solves one problem: **getting from point A to point B inside a building where GPS doesn't work.**

GPS signals can't penetrate walls and ceilings reliably enough for indoor use. Instead, this app uses the phone's camera and motion sensors to understand where it is within a room. The core idea is:

1. **An admin walks through the space** while the phone builds a 3D understanding of the environment. The admin drops named markers ("Meeting Room", "Kitchen") and the phone lays down invisible path nodes (waypoints) along every corridor.

2. **That spatial understanding is saved to a file.** The file contains thousands of visual landmarks, the positions of all markers and waypoints, and enough information to recognize the space later.

3. **A user loads that file** and points their phone at the same space. The phone matches what it sees to the saved landmarks, figures out exactly where it is, and can then draw a path through the waypoints to any destination.

The rest of this document explains every piece of that pipeline in detail.

---

## 2. How ARKit Tracks Your Phone in 3D Space

### Visual-Inertial Odometry (VIO)

ARKit's core tracking technology is called **Visual-Inertial Odometry**. It fuses two data sources:

- **Camera (visual):** Each video frame is analyzed for distinctive visual features — corners, edges, textures. By watching how these features move between frames, ARKit calculates how the camera moved.

- **IMU (inertial):** The phone's accelerometer and gyroscope measure linear acceleration and rotational velocity at 1000 Hz. These measurements fill in the gaps between camera frames (which arrive at 30-60 Hz) and handle fast movements where motion blur makes the camera unreliable.

The fusion of both sensors is what makes tracking robust. The camera prevents long-term drift (accelerometers accumulate error over time), while the IMU provides high-frequency updates between frames.

**In code**, this all happens automatically when you run an `ARWorldTrackingConfiguration`:

```swift
let config = ARWorldTrackingConfiguration()
sceneView.session.run(config)
```

From that point on, every `ARFrame` delivered to your delegate contains a `camera.transform` — a 4x4 matrix encoding the phone's exact position and orientation in 3D space, updated 60 times per second.

### Feature Points

Feature points are the visual landmarks ARKit extracts from camera frames. They're distinctive pixels — typically corners or high-contrast edges — that can be reliably identified across multiple frames from different angles.

You can see them as the yellow dots in the camera view:

```swift
sceneView.debugOptions = [.showFeaturePoints]
```

Each feature point has a 3D position computed via triangulation — ARKit sees the same feature from two camera positions and uses the angle difference to calculate its depth.

A well-mapped room might have **thousands** of feature points. Plain white walls generate very few (nothing to track), while a bookshelf or textured wall generates many.

### Plane Detection

ARKit also detects flat surfaces:

```swift
config.planeDetection = [.horizontal, .vertical]
```

This finds floors, tables, walls, etc. by recognizing clusters of coplanar feature points. The app enables this to improve overall scene understanding, though it doesn't directly use the detected planes for navigation (a future improvement could snap path dots to the floor plane).

### LiDAR Scene Reconstruction

On devices with a LiDAR scanner (iPhone 12 Pro and later, iPad Pro 2020+):

```swift
if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
    config.sceneReconstruction = .mesh
}
```

The LiDAR fires infrared laser pulses and measures their return time to build a depth map. This creates a dense 3D mesh of the environment — far more detailed than feature-point triangulation alone. It dramatically improves tracking accuracy, especially in visually sparse environments.

The app enables this automatically when available but doesn't require it.

---

## 3. The Coordinate System

### World Origin

When an AR session starts, ARKit establishes a **world coordinate system**:

- **Origin (0, 0, 0):** The position of the phone when the session started.
- **Y-axis:** Points straight up (opposite to gravity).
- **X and Z axes:** Form the horizontal plane, with Z pointing roughly toward the phone's initial rear-facing camera direction.
- **Units:** Meters. Everything in ARKit is measured in meters.

Every position and orientation in the session is relative to this origin. When you move 3 meters forward and 1 meter to the right, your camera transform reflects that.

### The 4x4 Transform Matrix

Positions and orientations in ARKit are encoded as `simd_float4x4` — a 4-by-4 matrix of floating-point numbers. This is standard in 3D graphics and robotics. The matrix combines:

```
| R R R Tx |
| R R R Ty |
| R R R Tz |
| 0 0 0  1 |
```

- **R (3x3 upper-left):** Rotation matrix — which direction the object is facing.
- **T (right column):** Translation — where the object is in 3D space.
- **Bottom row:** Always `[0, 0, 0, 1]` for a standard rigid-body transform.

### Reading a Position from a Transform

To get the XYZ position from a transform, you read the fourth column:

```swift
let transform = anchor.transform
let x = transform.columns.3.x  // meters right of origin
let y = transform.columns.3.y  // meters above origin
let z = transform.columns.3.z  // meters forward/back from origin
let position = SIMD3<Float>(x, y, z)
```

This is what our `NavigationAnchor.position` property does:

```swift
var position: SIMD3<Float> {
    let col = transform.columns.3
    return SIMD3<Float>(col.x, col.y, col.z)
}
```

When you "drop" an anchor, you're recording the camera's transform at that instant — its exact position and orientation in the world coordinate system.

---

## 4. Anchors — Pinning Virtual Objects to the Real World

### What Is an ARAnchor?

An `ARAnchor` is a fundamental ARKit concept: it represents a **fixed position and orientation in the real world**. When you add an anchor to the AR session, ARKit continuously refines its position as it learns more about the environment. If the tracking system realizes its earlier position estimates were slightly off, all anchors get adjusted together.

An anchor has:
- A `transform` (simd_float4x4) — its position and orientation.
- An `identifier` (UUID) — a unique ID.
- An optional `name` (String).

### Our Custom NavigationAnchor

We subclass `ARAnchor` to carry extra data:

```swift
class NavigationAnchor: ARAnchor, @unchecked Sendable {
    let destinationName: String   // "Meeting Room A" or "WP-14"
    let kind: AnchorKind          // .destination or .waypoint
}
```

Two kinds:
- **Destination:** A named place the user might want to navigate to. Rendered as a large labeled sphere.
- **Waypoint:** An unnamed path node defining a walkable corridor. Rendered as a small yellow dot.

When you tap "Drop" in the UI, this happens:

```swift
func dropDestination(named name: String) {
    guard let frame = sceneView.session.currentFrame else { return }
    let anchor = NavigationAnchor(
        destinationName: name,
        kind: .destination,
        transform: frame.camera.transform  // phone's current position
    )
    sceneView.session.add(anchor: anchor)  // registers with ARKit
}
```

The anchor's transform is the camera's transform at that moment — so the destination marker appears exactly where you were standing when you tapped the button.

### NSSecureCoding — Why Serialization Matters

When we save the world map, ARKit serializes all anchors using Apple's `NSKeyedArchiver` system. For our custom `NavigationAnchor` to survive this process, it must implement `NSSecureCoding`:

```swift
override func encode(with coder: NSCoder) {
    super.encode(with: coder)  // encodes ARAnchor's built-in properties
    coder.encode(destinationName as NSString, forKey: "destinationName")
    coder.encode(kind.rawValue as NSString, forKey: "anchorKind")
}

required init?(coder: NSCoder) {
    self.destinationName = coder.decodeObject(of: NSString.self, forKey: "destinationName") as? String ?? "Unknown"
    let rawKind = coder.decodeObject(of: NSString.self, forKey: "anchorKind") as? String ?? "destination"
    self.kind = AnchorKind(rawValue: rawKind) ?? .destination
    super.init(coder: coder)
}
```

Without this, the `destinationName` and `kind` would be lost when saving and loading the map — the anchors would come back as plain `ARAnchor` objects with no custom data.

`NSSecureCoding` (vs. regular `NSCoding`) also validates class types during deserialization, preventing a class of security vulnerabilities where archived data could instantiate arbitrary objects.

---

## 5. The ARWorldMap — Capturing a Snapshot of Reality

### What's Inside an ARWorldMap

An `ARWorldMap` is ARKit's snapshot of everything it has learned about the physical environment. It contains:

1. **Feature point cloud:** Thousands of 3D points with visual descriptors (what they look like, so they can be recognized later).
2. **Anchors:** All `ARAnchor` objects in the session, including our custom `NavigationAnchor` instances.
3. **Plane anchors:** Detected surfaces.
4. **Raw feature data:** Internal data ARKit uses for relocalization.
5. **Map extent:** The spatial bounds of the mapped area.

Capturing it is asynchronous because ARKit needs to finalize its internal state:

```swift
sceneView.session.getCurrentWorldMap { worldMap, error in
    // worldMap contains the complete spatial snapshot
}
```

This call can only succeed when the world mapping status is `.mapped` or `.extending`. That status reflects how much of the environment ARKit has confidently mapped:

| Status | Meaning |
|---|---|
| `.notAvailable` | Session just started, no data yet |
| `.limited` | Some features detected, but not enough for a reliable map |
| `.extending` | Good map quality; getting better as you explore more |
| `.mapped` | Excellent quality; current view has been thoroughly mapped |

### Saving the Map to Disk

The save pipeline has three steps:

```swift
// 1. Get the world map from ARKit
sceneView.session.getCurrentWorldMap { worldMap, error in

    // 2. Serialize to binary data using NSKeyedArchiver
    let data = try NSKeyedArchiver.archivedData(
        withRootObject: worldMap,
        requiringSecureCoding: true  // enforces NSSecureCoding on all objects
    )

    // 3. Write to a file
    try data.write(to: fileURL, options: [.atomic])
}
```

The `.atomic` option writes to a temporary file first and then renames it, preventing corruption if the app crashes mid-write.

A typical world map file is **5-50 MB** depending on how large the mapped area is and how many feature points were captured.

### Where Files Are Stored

Maps are stored in the app's **sandboxed Documents directory**:

```
/var/mobile/Containers/Data/Application/<APP-UUID>/Documents/IndoorNavMaps/
    Office Floor 3.arexperience
    Building A Lobby.arexperience
    ...
```

Each file is named after the map name you type in the UI, with an `.arexperience` extension.

The `MapStore` class manages this directory:

```swift
enum MapStore {
    private static var mapsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("IndoorNavMaps")
    }

    static func save(_ worldMap: ARWorldMap, name: String) throws { ... }
    static func load(name: String) throws -> ARWorldMap { ... }
    static func list() -> [String] { ... }
    static func delete(name: String) throws { ... }
}
```

This directory is:
- **App-sandboxed:** Only this app can access it.
- **Backed up by iCloud** (unless you opt out) when the user backs up their device.
- **Persists across app launches** but is deleted when the app is uninstalled.

---

## 6. Relocalization — Finding Your Place Again

### How It Works

Relocalization is the process of matching a live camera feed against a saved world map to determine where the device is within the previously mapped space.

When you load a world map and set it as the session's `initialWorldMap`:

```swift
let config = ARWorldTrackingConfiguration()
config.initialWorldMap = savedWorldMap
sceneView.session.run(config)
```

ARKit does the following:

1. **Extracts features from the live camera feed** — the same process as normal tracking.
2. **Compares live features against saved features** — using the visual descriptors stored in the world map. This is essentially a "do I recognize this place?" comparison.
3. **Once enough features match**, ARKit knows where in the saved map the device is looking. It sets the world coordinate system to align with the saved map's coordinate system.
4. **All saved anchors snap into their original positions** — because the coordinate system now matches the one used when the anchors were created.

### Why Lighting Matters

Feature descriptors encode what a visual feature **looks like** — pixel intensities, gradients, etc. If the lighting changes dramatically between mapping and navigation (daylight vs. artificial light, bright vs. dim), the same physical features may produce different descriptors, making matching harder or impossible.

Best practice: map under the same lighting conditions your users will navigate in.

### How We Detect It in Code

ARKit doesn't fire a specific "relocalized!" callback. Instead, we watch the tracking state transition:

```swift
func session(_ session: ARSession, didUpdate frame: ARFrame) {
    let tracking = frame.camera.trackingState

    if self.appMode == .navigation && !self.isRelocalized {
        if case .normal = tracking {
            self.isRelocalized = true
            // tracking went from .limited(.relocalizing) → .normal
        }
    }
}
```

The tracking state progresses through:
- `.limited(.initializing)` — session just started
- `.limited(.relocalizing)` — actively searching for matches in the saved map
- `.normal` — localized! The coordinate system is aligned.

---

## 7. Waypoints — Building a Walkable Network

### Why Straight Lines Don't Work

In a real building, the path between two rooms goes through corridors, around corners, and through doorways. A straight-line path from your position to a destination would cut through walls.

Waypoints solve this. They're invisible path nodes placed along every walkable corridor. When the admin walks a hallway, waypoints are dropped every 1.5 meters, creating a trail of positions that a person can actually walk through.

### Auto-Drop Mechanism

The auto-drop system works in the ARSessionDelegate:

```swift
func session(_ session: ARSession, didUpdate frame: ARFrame) {
    if appMode == .mapping && isAutoWaypointEnabled {
        let cameraPos = /* extract XYZ from frame.camera.transform */

        if let lastPos = lastAutoWaypointPosition {
            let distanceMoved = simd_length(cameraPos - lastPos)
            if distanceMoved >= 1.5 {  // meters
                dropWaypoint(at: frame.camera.transform)
                lastAutoWaypointPosition = cameraPos
            }
        }
    }
}
```

This runs 60 times per second (every frame). It computes the Euclidean distance between the current camera position and the last waypoint's position. When that distance exceeds 1.5 meters, a new waypoint is dropped.

The `simd_length` function computes:

```
distance = sqrt((x2-x1)² + (y2-y1)² + (z2-z1)²)
```

Each waypoint is a `NavigationAnchor` with `kind: .waypoint`:

```swift
private func dropWaypoint(at transform: simd_float4x4) {
    waypointCount += 1
    let anchor = NavigationAnchor(
        destinationName: "WP-\(waypointCount)",
        kind: .waypoint,
        transform: transform
    )
    sceneView.session.add(anchor: anchor)
}
```

### The Waypoint Graph

After mapping, the session might contain something like:

```
Anchors in world map:
  WP-1  @ (0.0, 1.2, 0.0)     ← hallway start
  WP-2  @ (1.4, 1.2, 0.2)     ← 1.5m down the hall
  WP-3  @ (2.8, 1.2, 0.3)     ← further down
  WP-4  @ (4.2, 1.2, 0.1)     ← corner
  WP-5  @ (4.3, 1.2, 1.6)     ← turned left into side corridor
  WP-6  @ (4.2, 1.2, 3.0)     ← further down side corridor
  Kitchen @ (4.3, 1.2, 4.5)   ← destination
  WP-7  @ (5.6, 1.2, 0.0)     ← continued down main hall
  MeetingRoom @ (7.0, 1.2, 0.1) ← destination
```

These positions form a network. Consecutive waypoints are close together (< 5m), so they auto-connect in the pathfinding graph. This creates a walkable network that follows corridors.

---

## 8. Pathfinding — Dijkstra's Algorithm

### Graph Construction

`PathFinder.findPath()` builds a graph where:

- **Nodes:** Every anchor (both waypoints and destinations) plus a virtual "start" node at the user's camera position.
- **Edges:** Two nodes are connected if they're within 5 meters of each other. The edge weight is the Euclidean distance between them.

```swift
for i in 0..<n {
    for j in (i + 1)..<n {
        let d = simd_length(positions[i] - positions[j])
        if d <= 5.0 {  // connectionRadius
            adj[i].append(Edge(to: j, weight: d))
            adj[j].append(Edge(to: i, weight: d))
        }
    }
}
```

Why 5 meters? Because auto-dropped waypoints are 1.5m apart. Consecutive waypoints have a distance of ~1.5m, which is well within 5m. But waypoints on opposite sides of a wall (in different corridors) are typically > 5m apart measured through the wall, so they won't connect. This naturally creates a graph that follows corridors.

### The Algorithm Step by Step

Dijkstra's algorithm finds the shortest path from a source node to all other nodes in a weighted graph. Here's what it does:

1. **Initialize:** Set the distance to the start node as 0, and all other nodes as infinity. Mark all nodes as unvisited.

2. **Visit the nearest unvisited node:** Pick the node with the smallest known distance. Mark it as visited.

3. **Update neighbors:** For each unvisited neighbor of the current node, calculate the distance through the current node. If it's shorter than the previously known distance, update it and record the current node as the predecessor.

4. **Repeat** until you reach the destination (early exit optimization) or all reachable nodes are visited.

```swift
// Initialization
var dist = [Float](repeating: .infinity, count: totalNodes)
var prev = [Int](repeating: -1, count: totalNodes)
var visited = [Bool](repeating: false, count: totalNodes)
dist[startIdx] = 0

// Main loop
for _ in 0..<totalNodes {
    // Find nearest unvisited
    var u = -1
    var best: Float = .infinity
    for v in 0..<totalNodes where !visited[v] && dist[v] < best {
        best = dist[v]
        u = v
    }
    guard u != -1 else { break }
    if u == destIdx { break }  // early exit: reached destination
    visited[u] = true

    // Relax edges
    for edge in adj[u] {
        let newDist = dist[u] + edge.weight
        if newDist < dist[edge.to] {
            dist[edge.to] = newDist
            prev[edge.to] = u
        }
    }
}
```

**Time complexity:** O(n²) where n is the number of nodes. For a typical office mapping with 50-200 waypoints, this completes in microseconds. A priority-queue version would be O((n + e) log n) but isn't needed at this scale.

### Path Reconstruction

After Dijkstra completes, the `prev` array forms a linked list from destination back to start. We follow it:

```swift
var path = [SIMD3<Float>]()
var cur = destIdx
while cur != -1 {
    path.append(positions[cur])
    cur = prev[cur]
}
path.reverse()  // now it's start → waypoint → waypoint → ... → destination
```

The result is an ordered array of 3D positions representing the turn-by-turn route.

### The Virtual Start Node

The user's current position isn't a saved anchor — it changes every frame. So we add a temporary "virtual start node" at the camera position:

```swift
var positions = anchors.map(\.position)
positions.append(start)  // virtual start at index n
```

This node gets connected to all nearby anchors within a generous radius (at least 5m, or 1.5× the distance to the nearest anchor). This ensures the user can always "enter" the waypoint graph from their current position.

### Worked Example

Imagine these anchors after mapping:

```
WP-1 (0,0,0) --- WP-2 (1.5,0,0) --- WP-3 (3,0,0) --- Kitchen (4.5,0,0)
                                          |
                                      WP-4 (3,0,1.5)
                                          |
                                      MeetingRoom (3,0,3)
```

User is at position (0.5, 0, 0.2) and wants to go to MeetingRoom.

1. **Graph construction:** Virtual start → WP-1 (0.5m), WP-1 → WP-2 (1.5m), WP-2 → WP-3 (1.5m), WP-3 → WP-4 (1.5m), WP-4 → MeetingRoom (1.5m), WP-3 → Kitchen (1.5m).

2. **Dijkstra runs:**
   - Start: dist=0
   - Visit WP-1: dist=0.5
   - Visit WP-2: dist=2.0
   - Visit WP-3: dist=3.5
   - Visit WP-4: dist=5.0
   - Visit MeetingRoom: dist=6.5

3. **Path reconstruction:** Start → WP-1 → WP-2 → WP-3 → WP-4 → MeetingRoom

4. **Result:** The path follows the L-shaped corridor, not a straight line through the wall.

---

## 9. Rendering — Drawing 3D Objects in AR

### SceneKit and ARSCNView

The app uses `ARSCNView`, which combines:
- **ARKit:** Tracks the device, manages anchors, provides camera frames.
- **SceneKit:** Apple's 3D rendering engine. Handles geometry, materials, lighting, animations.

SceneKit renders a 3D scene graph — a tree of `SCNNode` objects, each with optional geometry, position, rotation, and child nodes. The root of this tree is `sceneView.scene.rootNode`.

`ARSCNView` automatically:
- Renders the camera feed as the background.
- Moves SceneKit's virtual camera to match the real camera (using the ARKit transform).
- Calls delegate methods when anchors are added, so you can attach 3D content to them.

### How Anchor Nodes Are Created

When ARKit adds an anchor (either from a `session.add()` call or from a loaded world map), it calls:

```swift
func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode?
```

We return a 3D node that gets automatically positioned at the anchor's transform. For destinations:

```swift
// Blue sphere (5cm radius)
let sphere = SCNSphere(radius: 0.05)
sphere.firstMaterial?.diffuse.contents = UIColor.systemBlue

// Floating text label
let text = SCNText(string: "Meeting Room", extrusionDepth: 0.5)
text.font = UIFont.systemFont(ofSize: 4, weight: .bold)
let textNode = SCNNode(geometry: text)
textNode.scale = SCNVector3(0.01, 0.01, 0.01)  // scale down

// Billboard constraint: label always faces the camera
let billboard = SCNBillboardConstraint()
billboard.freeAxes = .Y
textNode.constraints = [billboard]
```

For waypoints: smaller yellow semi-transparent spheres (2.5cm radius).

### Path Dot Rendering

The navigation path is rendered as a series of small spheres following the Dijkstra-computed route. The `renderPath` method:

1. **Walks each segment** of the path (between consecutive waypoints).
2. **Places a dot every 25cm** along the segment, using linear interpolation.
3. **Colors dots with a gradient** — green-cyan near the user, blue-cyan near the destination.
4. **Uses a cone geometry** for the final dot (arrow indicator).

```swift
for i in 0..<(positions.count - 1) {
    let segStart = positions[i]
    let segEnd = positions[i + 1]
    let segDir = segEnd - segStart
    let segNorm = simd_normalize(segDir)

    var offset = pathDotSpacing - accumulated
    while offset <= segLen {
        let pos = segStart + segNorm * offset  // interpolated position
        dotPositions.append(pos)
        offset += pathDotSpacing
    }
}
```

All path dots are children of `pathContainerNode`, which is always attached to the scene root. To redraw the path, we remove all children and add new ones.

### The Render Loop

SceneKit calls `renderer(_:updateAtTime:)` every frame (60 FPS). We use this to update the path:

```swift
func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
    guard time - lastPathUpdateTime > 0.15 else { return }  // throttle to ~7 FPS
    lastPathUpdateTime = time

    let cameraPos = sceneView.pointOfView!.simdWorldPosition
    currentPath = PathFinder.findPath(from: cameraPos, to: dest, through: allLoadedAnchors)
    renderPath(currentPath)
}
```

We throttle to ~7 updates/second because:
- Rebuilding the path every frame (60 FPS) would be wasteful.
- The user doesn't walk fast enough to need sub-150ms updates.
- Graph pathfinding + geometry creation has some overhead.

---

## 10. The SwiftUI ↔ UIKit Bridge

### UIViewRepresentable

`ARSCNView` is a UIKit view. SwiftUI can't use it directly. The bridge is `UIViewRepresentable`:

```swift
struct ARViewContainer: UIViewRepresentable {
    let sessionManager: ARSessionManager

    func makeUIView(context: Context) -> ARSCNView {
        sessionManager.sceneView  // return the existing ARSCNView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
```

This wraps the ARSCNView so SwiftUI can display it. The view is created once (in `ARSessionManager.init()`) and reused — `makeUIView` just returns the existing instance.

### ObservableObject and @Published

The session manager uses the Combine framework's `ObservableObject` protocol to bridge AR state to SwiftUI:

```swift
class ARSessionManager: NSObject, ObservableObject {
    @Published var trackingState: ARCamera.TrackingState = .notAvailable
    @Published var isRelocalized = false
    @Published var distanceToDestination: Float?
    // ...
}
```

Every time a `@Published` property changes, SwiftUI automatically re-renders any view that reads it. For example, when `isRelocalized` changes from `false` to `true`, the ContentView switches from showing the spinner to showing the destination picker — with no manual UI update code.

In `ContentView`:

```swift
@StateObject private var sessionManager = ARSessionManager()
// SwiftUI creates this once and keeps it alive for the view's lifetime
```

---

## 11. Threading Model

ARKit and SceneKit use multiple threads. Understanding the threading is critical for avoiding crashes:

| Context | Thread | What runs here |
|---|---|---|
| SwiftUI views | Main thread | All UI rendering, @Published property updates |
| ARSessionDelegate callbacks | AR session queue (background) | `session(_:didUpdate:)`, `session(_:didFailWithError:)` |
| ARSCNViewDelegate callbacks | SceneKit render thread | `renderer(_:nodeFor:)`, `renderer(_:updateAtTime:)` |

**Rule:** `@Published` properties must only be set from the main thread. That's why delegate callbacks dispatch to main:

```swift
func session(_ session: ARSession, didUpdate frame: ARFrame) {
    let tracking = frame.camera.trackingState  // read on session queue

    DispatchQueue.main.async { [weak self] in
        self?.trackingState = tracking  // write on main queue
    }
}
```

For the render loop (`renderer(_:updateAtTime:)`), scene graph modifications (adding/removing nodes) are safe on the render thread. But publishing distance updates to SwiftUI must go through `DispatchQueue.main.async`.

---

## 12. Complete Data Flow: Mapping to Navigation

### Phase 1: Mapping

```
Admin walks with phone
    │
    ▼
ARKit tracks camera position (VIO)
    │
    ├──▶ Auto-waypoint check every frame
    │    └── If moved ≥ 1.5m → create NavigationAnchor(kind: .waypoint)
    │         └── ARSession.add(anchor:) → anchor stored in session
    │
    ├──▶ Admin taps "Drop" for destination
    │    └── create NavigationAnchor(kind: .destination, name: "Kitchen")
    │         └── ARSession.add(anchor:) → anchor stored in session
    │
    ▼
Admin taps "Save"
    │
    ▼
ARSession.getCurrentWorldMap() → ARWorldMap
    │  Contains: feature points + all anchors (destinations + waypoints)
    │
    ▼
NSKeyedArchiver.archivedData(worldMap) → Data (binary blob)
    │  NavigationAnchor.encode(with:) serializes destinationName + kind
    │
    ▼
Data.write(to: Documents/IndoorNavMaps/MyMap.arexperience)
    │
    ▼
File on disk ✓
```

### Phase 2: Navigation

```
User selects "Navigate" → picks "MyMap" from list
    │
    ▼
Data(contentsOf: .../MyMap.arexperience) → binary Data
    │
    ▼
NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self) → ARWorldMap
    │  NavigationAnchor.init?(coder:) restores destinationName + kind
    │
    ▼
Extract destinations and waypoints from worldMap.anchors
    │
    ▼
ARWorldTrackingConfiguration.initialWorldMap = worldMap
    │
    ▼
ARSession.run(config) → relocalization begins
    │
    ├──▶ User points phone at mapped area
    │    └── ARKit matches live features against saved feature cloud
    │
    ▼
TrackingState transitions: .limited(.relocalizing) → .normal
    │
    ▼
isRelocalized = true → UI shows destination picker
    │
    ▼
User taps "Kitchen"
    │
    ▼
Every 150ms in render loop:
    │
    ├──▶ Read camera position from pointOfView.simdWorldPosition
    │
    ├──▶ PathFinder.findPath(from: cameraPos, to: kitchen, through: allAnchors)
    │    ├── Build graph: nodes within 5m connected
    │    ├── Add virtual start node at camera position
    │    ├── Dijkstra: find shortest path start → kitchen
    │    └── Return: [cameraPos, WP-3, WP-7, WP-12, Kitchen]
    │
    ├──▶ renderPath(): place cyan dots every 25cm along the path segments
    │
    └──▶ Compute walking distance (sum of segment lengths) → publish to UI
```

---

## 13. File-by-File Code Walkthrough

### `IndoorNavApp.swift` (10 lines)
The `@main` entry point. Creates a `WindowGroup` containing `ContentView`. Nothing else — the SwiftUI lifecycle handles app launch, backgrounding, etc.

### `ARViewContainer.swift` (12 lines)
The thinnest possible `UIViewRepresentable`. Returns the session manager's pre-created `ARSCNView`. No state, no updates.

### `NavigationAnchor.swift` (75 lines)
Custom `ARAnchor` subclass. Carries `destinationName` (String) and `kind` (AnchorKind enum). Implements four initializers required by the ARAnchor contract:
- `init(destinationName:kind:transform:)` — primary initializer used by our code.
- `override init(name:transform:)` — required by ARAnchor's designated initializer chain.
- `required init(anchor:)` — ARKit's internal copy contract.
- `required init?(coder:)` — NSSecureCoding deserialization.

### `MapStore.swift` (83 lines)
Stateless utility (enum with static methods). Manages the `IndoorNavMaps` directory. Sorting by modification date so the most recent map appears first in the picker.

### `PathFinder.swift` (115 lines)
Stateless utility. The `findPath` method builds an adjacency list, runs Dijkstra, and reconstructs the path. The `Edge` struct is a simple (destination, weight) pair. Falls back to a straight line if no graph path exists.

### `ARSessionManager.swift` (568 lines)
The largest file and the app's core. Broken into sections:
- **Published state** (~40 lines) — all reactive state for SwiftUI.
- **Session lifecycle** (~70 lines) — `startMappingSession()` and `startNavigationSession()`.
- **Mapping operations** (~50 lines) — drop destinations, drop waypoints, save map.
- **Navigation operations** (~30 lines) — select destination, clear, recompute path.
- **Path rendering** (~50 lines) — `clearPath()` and `renderPath()`.
- **ARSCNViewDelegate** (~100 lines) — 3D node creation for anchors, render loop for path updates.
- **ARSessionDelegate** (~100 lines) — frame updates, auto-waypoint, tracking state, session errors.

### `ContentView.swift` (481 lines)
Pure SwiftUI. Broken into computed view properties:
- `topBar` — segmented mode picker.
- `mappingControls` — auto-waypoint toggle, destination input, map save.
- `destinationList` — horizontal scroll of destination chips with delete buttons.
- `navigationControls` — conditional: map picker → loading → error → relocalization → destination picker.
- `bottomBar` — tracking status, mapping quality, info text.
- Status color helpers — map enum values to SwiftUI colors.

---

## 14. Key Apple Frameworks Used

| Framework | What it provides | How we use it |
|---|---|---|
| **ARKit** | Camera tracking, world mapping, anchor management, relocalization | The foundation — everything spatial |
| **SceneKit** | 3D rendering engine (geometry, materials, animations, scene graph) | Rendering anchor markers and path dots in 3D |
| **SwiftUI** | Declarative UI framework | All 2D UI overlays (buttons, pickers, status indicators) |
| **Combine** | Reactive programming (`@Published`, `ObservableObject`) | Bridging AR state changes to SwiftUI re-renders |
| **simd** | Hardware-accelerated vector/matrix math | 3D position calculations, distance computations |
| **Foundation** | File I/O, `NSKeyedArchiver`, `FileManager` | Saving/loading world map files |

---

## 15. Glossary

| Term | Definition |
|---|---|
| **ARAnchor** | A fixed position/orientation in the real world, tracked by ARKit. Survives coordinate system adjustments. |
| **ARFrame** | A single timestamped snapshot: camera image + camera transform + tracking metadata. Delivered ~60 times/second. |
| **ARSCNView** | A UIKit view that combines ARKit tracking with SceneKit 3D rendering over a live camera feed. |
| **ARSession** | The runtime that manages ARKit tracking. You configure it, run it, and receive delegate callbacks. |
| **ARWorldMap** | A serializable snapshot of ARKit's spatial understanding: feature points, anchors, planes. |
| **ARWorldTrackingConfiguration** | Configuration that enables 6-DOF (six degrees of freedom) tracking using camera + IMU. |
| **Billboard constraint** | A SceneKit constraint that makes a node always face the camera (like a signpost that rotates to face you). |
| **Connection radius** | The maximum distance (5m) between two anchors for them to be connected in the pathfinding graph. |
| **Destination** | A named NavigationAnchor (kind: .destination) representing a place the user might want to navigate to. |
| **Dijkstra's algorithm** | A graph algorithm that finds the shortest weighted path from a source node to all other nodes. |
| **Feature point** | A visually distinctive pixel (corner, edge) that ARKit tracks across frames to determine camera motion. |
| **LiDAR** | Light Detection And Ranging. An infrared laser scanner that measures distances to build a 3D depth map. |
| **NSKeyedArchiver** | Apple's serialization system for converting Objective-C/Swift objects to binary data and back. |
| **NSSecureCoding** | A protocol that ensures type safety during deserialization (prevents type confusion attacks). |
| **Relocalization** | The process of matching a live camera view against a saved world map to determine the device's position within it. |
| **Scene reconstruction** | Using LiDAR data to build a 3D triangle mesh of the physical environment. |
| **simd_float4x4** | A 4×4 matrix of 32-bit floats, used to represent position + rotation (a "transform") in 3D space. |
| **SIMD3\<Float\>** | A 3-component vector (x, y, z) for representing positions and directions in 3D. |
| **UIViewRepresentable** | A SwiftUI protocol for wrapping UIKit views so they can be used in SwiftUI layouts. |
| **VIO** | Visual-Inertial Odometry. ARKit's core tracking technology fusing camera and IMU data. |
| **Waypoint** | A NavigationAnchor (kind: .waypoint) representing a walkable position along a corridor. Not visible to the end user during navigation. |
| **World coordinate system** | The 3D coordinate space ARKit establishes when a session starts. Origin at the device's initial position, Y-up, units in meters. |
| **World mapping status** | ARKit's assessment of how thoroughly the current environment has been mapped (.notAvailable → .limited → .extending → .mapped). |
