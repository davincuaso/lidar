# IndoorNav — AR Indoor Navigation (MVP)

A hardware-free indoor AR navigation app for iOS. An admin maps a physical space by walking through it and dropping named destination markers; a user then loads that map, relocalizes their device, and follows an AR path overlay to their chosen destination.

Built with **SwiftUI**, **ARKit**, and **SceneKit**.

---

## Table of Contents

- [Requirements](#requirements)
- [Getting Started](#getting-started)
- [How It Works](#how-it-works)
  - [1. Map the Space (Admin Mode)](#1-map-the-space-admin-mode)
  - [2. Navigate (User Mode)](#2-navigate-user-mode)
- [Architecture](#architecture)
  - [File Overview](#file-overview)
  - [Key Classes](#key-classes)
  - [Data Flow](#data-flow)
- [Technical Details](#technical-details)
  - [AR Configuration](#ar-configuration)
  - [World Map Persistence](#world-map-persistence)
  - [Custom Anchor Serialization](#custom-anchor-serialization)
  - [Relocalization](#relocalization)
  - [Path Rendering](#path-rendering)
- [Troubleshooting](#troubleshooting)
- [Limitations](#limitations)
- [License](#license)

---

## Requirements

| Requirement | Minimum |
|---|---|
| Xcode | 15.0+ |
| iOS Deployment Target | 16.0 |
| Swift | 5.0 |
| Device | Physical iPhone or iPad with ARKit support (A9 chip or later) |
| Optional | LiDAR-equipped device (iPhone 12 Pro+, iPad Pro 2020+) for mesh-based scene reconstruction |

ARKit does **not** run in the iOS Simulator. You must build and run on a physical device.

---

## Getting Started

### 1. Clone or open the project

```bash
cd /path/to/lidar-project
open IndoorNav.xcodeproj
```

### 2. Accept the Xcode license (if not already done)

```bash
sudo xcodebuild -license accept
```

### 3. Configure signing

1. Open `IndoorNav.xcodeproj` in Xcode.
2. Select the **IndoorNav** target in the project navigator.
3. Go to **Signing & Capabilities**.
4. Set **Team** to your Apple Developer account (free or paid).
5. Optionally change **Bundle Identifier** from `com.example.IndoorNav` to something unique.

### 4. Build and run

1. Connect a physical iOS device via USB or Wi-Fi.
2. Select your device as the run destination in Xcode's toolbar.
3. Press **Cmd+R** (or the Play button) to build and run.
4. On first launch, grant camera access when prompted.

---

## How It Works

The app has two modes, controlled by a segmented toggle at the top of the screen.

### 1. Map the Space (Admin Mode)

This mode is used by an administrator to create a map of the indoor environment.

**Steps:**

1. **Walk the space.** Hold the device and walk slowly through the area you want to map. ARKit tracks visual features (edges, textures, patterns) in the environment and builds an internal world map. Watch the **World Map** status indicator at the bottom of the screen:
   - Red (Not Available) — ARKit is still initializing.
   - Orange (Limited) — Some features detected; keep moving.
   - Yellow (Extending) — Good coverage; the map is growing. You can save now.
   - Green (Mapped) — Excellent coverage. Ideal time to save.

2. **Drop destination anchors.** When you reach a point of interest (a meeting room door, an elevator, a restroom, etc.):
   - Type a name in the text field (e.g., "Meeting Room A").
   - Tap **Drop**. A blue 3D sphere with a floating label appears in AR space at that position.
   - Repeat for every destination. You can remove anchors by tapping the X on their chip.

3. **Save the map.** Once the World Map status reaches **Extending** or **Mapped**, tap **Save Map**. This captures ARKit's `ARWorldMap` (which includes all visual feature points, detected planes, and your custom anchors) and writes it to the device's Documents directory as `IndoorNavWorldMap.arexperience`.

**Tips for good mapping:**
- Walk slowly and steadily. Avoid sudden movements.
- Cover the space from multiple angles — don't just walk a straight line.
- Ensure the environment has visual texture (plain white walls are hard for ARKit to track).
- Good lighting helps significantly.

### 2. Navigate (User Mode)

This mode is used by anyone who needs to find their way through the mapped space.

**Steps:**

1. **Load and relocalize.** When you switch to Navigate mode, the app automatically loads the saved world map and starts an AR session with it. A spinner and "Look around to localize..." message appear. Point the device at the same physical area where the map was created and move slowly. ARKit matches live camera features against the saved map's feature points.

2. **Wait for localization.** When tracking transitions to **Normal**, the UI switches to a green "Localized" badge and presents the destination list. This means ARKit has successfully matched the current environment to the saved map. All saved destination anchors reappear in their original 3D positions as green pulsing spheres.

3. **Select a destination.** Tap one of the destination buttons (e.g., "Meeting Room A"). A dotted AR path immediately appears:
   - Cyan/green dots lead from your current camera position to the destination.
   - The dots update in real-time (~10 FPS) as you move.
   - A color gradient shifts from green (near you) to blue (near the destination).
   - A cone marker indicates the final point.

4. **Follow the path.** Walk toward the destination. The distance readout updates live. When you're within 0.5 meters, a "You have arrived!" badge appears.

5. **Change destination.** Tap a different destination button at any time, or tap **Clear** to dismiss the path.

---

## Architecture

### File Overview

```
IndoorNav.xcodeproj/
  project.pbxproj              Xcode project configuration

IndoorNav/
  IndoorNavApp.swift            @main App entry point (SwiftUI lifecycle)
  ContentView.swift             Full UI: mode picker, mapping controls,
                                navigation controls, status bar
  ARViewContainer.swift         UIViewRepresentable wrapping ARSCNView
  ARSessionManager.swift        AR session lifecycle, world map save/load,
                                relocalization detection, path rendering
  NavigationAnchor.swift        Custom ARAnchor subclass with NSSecureCoding
  Info.plist                    Camera permission, ARKit capability, orientation lock
  Assets.xcassets/              App icon and accent color
```

### Key Classes

**`ARSessionManager`** (`NSObject`, `ObservableObject`)

The central manager that owns the `ARSCNView` and its `ARSession`. It:
- Configures and runs world tracking sessions for both modes.
- Implements `ARSessionDelegate` to track mapping quality and camera tracking state.
- Implements `ARSCNViewDelegate` to render custom 3D nodes for anchors and update the path each frame.
- Publishes all state via `@Published` properties for reactive SwiftUI binding.

**`NavigationAnchor`** (subclass of `ARAnchor`)

A custom anchor that carries a `destinationName` string. Implements `NSSecureCoding` so that it survives serialization inside an `ARWorldMap` when saved to disk and deserialized when loaded back.

**`ContentView`** (SwiftUI `View`)

The root view. Uses a `ZStack` to layer the AR camera feed behind translucent material UI panels. Switches between mapping and navigation control sets based on `appMode`.

**`ARViewContainer`** (`UIViewRepresentable`)

A thin bridge that returns the session manager's `ARSCNView` to SwiftUI.

### Data Flow

```
User interaction (SwiftUI)
        |
        v
  ContentView (@StateObject sessionManager)
        |
        v
  ARSessionManager (@Published state)
        |
        +---> ARSession (ARKit)
        |         |
        |         v
        |     ARSessionDelegate callbacks
        |         |
        |         v
        |     @Published updates --> SwiftUI re-renders
        |
        +---> ARSCNView (SceneKit)
                  |
                  v
              ARSCNViewDelegate
                  |
                  +---> renderer(_:nodeFor:)      — anchor visualization
                  +---> renderer(_:updateAtTime:) — path updates
```

---

## Technical Details

### AR Configuration

Both modes use `ARWorldTrackingConfiguration` with:
- **Plane detection:** horizontal and vertical surfaces.
- **Environment texturing:** automatic (improves visual quality of AR content).
- **Scene reconstruction:** mesh-based, enabled automatically on LiDAR devices via `supportsSceneReconstruction(.mesh)`. This provides denser spatial understanding but is not required.
- **Debug options:** feature points are shown as yellow dots to give the user feedback on tracking quality.

### World Map Persistence

The world map is saved to:

```
<App Documents>/IndoorNavWorldMap.arexperience
```

The save pipeline:
1. `ARSession.getCurrentWorldMap()` — asynchronous callback returning an `ARWorldMap`.
2. `NSKeyedArchiver.archivedData(withRootObject:requiringSecureCoding:)` — serializes the world map (including all anchors) into `Data`.
3. `Data.write(to:options:.atomic)` — writes to disk atomically.

The load pipeline (inverse):
1. `Data(contentsOf:)` — reads the file.
2. `NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from:)` — deserializes.
3. The map is set as `config.initialWorldMap` before running the session.

### Custom Anchor Serialization

`NavigationAnchor` extends `ARAnchor` with a `destinationName` property. For this to survive the `NSKeyedArchiver`/`NSKeyedUnarchiver` round-trip inside the world map:

- `supportsSecureCoding` returns `true`.
- `encode(with:)` calls `super.encode(with:)` and then encodes `destinationName` under a static key.
- `init?(coder:)` decodes `destinationName` and calls `super.init(coder:)`.
- `init(anchor:)` is implemented to satisfy ARKit's internal anchor-copying contract.

### Relocalization

When a world map is loaded via `initialWorldMap`, ARKit enters a relocalization phase:
1. The camera tracking state starts as `.limited(.relocalizing)`.
2. ARKit compares live camera features against the saved map's feature point cloud.
3. When enough features match, tracking transitions to `.normal`.
4. The app detects this transition in `session(_:didUpdate:)` and sets `isRelocalized = true`.

For best results, the user should be in the same physical area where the map was originally captured, with similar lighting conditions.

### Path Rendering

The path is rendered as a series of SceneKit nodes managed by a dedicated `pathContainerNode` attached to the scene root:

- **Update frequency:** ~10 FPS, throttled in `renderer(_:updateAtTime:)` to avoid unnecessary work.
- **Geometry:** small `SCNSphere` nodes (radius 1.5cm) spaced 30cm apart along a straight line from camera to destination. The final node uses an `SCNCone` (arrow shape).
- **Color:** gradient from green-cyan (near user) to blue-cyan (near destination) for directional cues.
- **Lifecycle:** all path nodes are cleared and rebuilt each update cycle. The geometry instances are copied from shared templates to avoid allocation overhead.
- **Distance:** computed as Euclidean distance between camera and anchor positions; published to the UI for the distance readout.

---

## Troubleshooting

| Problem | Solution |
|---|---|
| "AR not available on this device" | ARKit requires an A9 chip or later. Must be a physical device, not the Simulator. |
| World Map status stays red/orange | Move more slowly. Ensure the environment has visual texture and adequate lighting. Plain white walls or dark rooms are problematic. |
| Save Map button is disabled | The world map status must reach at least "Extending" (yellow). Keep walking and scanning. |
| Relocalization fails / stays on spinner | You must be in the same physical area where the map was created. Lighting conditions should be similar. Point at distinctive features (posters, furniture edges, signs). |
| "No saved map found" error | Switch to "Map the Space" mode first and complete a full map+save cycle before attempting navigation. |
| Path appears to float or drift | This can happen if relocalization was marginal. Try moving to revisit more of the originally mapped area. The world map quality during the mapping phase directly affects navigation accuracy. |

---

## Limitations

This is an MVP. Known limitations and areas for future work:

- **Straight-line pathfinding only.** The path is a direct line from camera to destination. It does not account for walls, obstacles, or room layouts. A future version could integrate ARKit's mesh data for obstacle-aware pathfinding (e.g., A* on a navigation mesh).
- **Single map file.** Only one world map is stored at a time. Saving a new map overwrites the previous one. A future version could support multiple named maps.
- **Same-device mapping and navigation.** The world map is saved to the local Documents directory. Sharing maps between devices would require file export/import or a backend.
- **Lighting sensitivity.** ARKit's visual feature matching is sensitive to lighting changes between the mapping and navigation sessions. Maps created in daylight may not relocalize well at night.
- **No floor-level path clamping.** Path dots follow a straight 3D line which may pass through walls or float above/below the floor. Clamping to detected planes or mesh surfaces would improve realism.
- **Portrait orientation only.** The app is locked to portrait for simplicity.

---

## License

This project is provided as-is for educational and prototyping purposes. No license file is included — add your own as needed.
