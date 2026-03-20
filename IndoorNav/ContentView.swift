import SwiftUI
import ARKit

struct ContentView: View {
    @StateObject private var sessionManager = ARSessionManager()
    @State private var anchorName = ""

    var body: some View {
        ZStack {
            ARViewContainer(sessionManager: sessionManager)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer()

                if sessionManager.appMode == .mapping {
                    mappingControls
                } else {
                    navigationControls
                }

                bottomBar
            }
        }
        .onAppear {
            sessionManager.startMappingSession()
        }
        .onChange(of: sessionManager.appMode) { newMode in
            switch newMode {
            case .mapping:
                sessionManager.startMappingSession()
            case .navigation:
                sessionManager.startNavigationSession()
            }
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        VStack(spacing: 8) {
            Picker("Mode", selection: $sessionManager.appMode) {
                ForEach(AppMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    // MARK: - Mapping Controls

    private var mappingControls: some View {
        VStack(spacing: 10) {

            if !sessionManager.droppedAnchors.isEmpty {
                anchorList
            }

            HStack(spacing: 10) {
                TextField("Destination name", text: $anchorName)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()

                Button {
                    let name = anchorName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    sessionManager.dropAnchor(named: name)
                    anchorName = ""
                } label: {
                    Image(systemName: "mappin.and.ellipse")
                    Text("Drop")
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(anchorName.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            HStack(spacing: 10) {
                Button {
                    sessionManager.saveWorldMap()
                } label: {
                    HStack {
                        if sessionManager.isSavingMap {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "square.and.arrow.down")
                        }
                        Text("Save Map")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(!sessionManager.canSaveMap || sessionManager.isSavingMap)
            }

            if let result = sessionManager.mapSaveResult {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(result.hasPrefix("Saved") ? .green : .red)
            }

            if !sessionManager.canSaveMap {
                Text("Move around to improve mapping before saving")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    // MARK: - Anchor List (Mapping)

    private var anchorList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Destinations (\(sessionManager.droppedAnchors.count))")
                .font(.caption.bold())
                .foregroundStyle(.primary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(sessionManager.droppedAnchors, id: \.identifier) { anchor in
                        HStack(spacing: 4) {
                            Image(systemName: "mappin.circle.fill")
                                .foregroundStyle(.blue)
                            Text(anchor.destinationName)
                                .font(.caption)
                            Button {
                                sessionManager.removeAnchor(anchor)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                    }
                }
            }
        }
    }

    // MARK: - Navigation Controls

    private var navigationControls: some View {
        VStack(spacing: 10) {
            if sessionManager.isLoadingMap {
                HStack {
                    ProgressView()
                    Text("Loading map...")
                        .font(.subheadline)
                }
            } else if let error = sessionManager.navigationError {
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .font(.title2)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            } else if !sessionManager.isRelocalized {
                relocalizationView
            } else {
                destinationPicker
            }
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    // MARK: - Relocalization View

    private var relocalizationView: some View {
        VStack(spacing: 8) {
            ProgressView()
                .scaleEffect(1.2)

            Text("Look around to localize...")
                .font(.subheadline.bold())
                .foregroundStyle(.primary)

            Text("Point your device at the area you previously mapped. Move slowly and revisit recognizable features.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text("\(sessionManager.loadedDestinations.count) destination\(sessionManager.loadedDestinations.count == 1 ? "" : "s") in saved map")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Destination Picker

    private var destinationPicker: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Localized")
                    .font(.caption.bold())
                    .foregroundStyle(.green)
                Spacer()
                if sessionManager.selectedDestination != nil {
                    Button("Clear") {
                        sessionManager.clearNavigation()
                    }
                    .font(.caption)
                }
            }

            if sessionManager.loadedDestinations.isEmpty {
                Text("No destinations found in the saved map.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Select a destination:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(sessionManager.loadedDestinations, id: \.identifier) { dest in
                            destinationButton(for: dest)
                        }
                    }
                }
            }

            if let dist = sessionManager.distanceToDestination,
               let dest = sessionManager.selectedDestination {
                HStack(spacing: 6) {
                    Image(systemName: "location.fill")
                        .foregroundStyle(.cyan)
                    Text(String(format: "\"%@\" is %.1f m away", dest.destinationName, dist))
                        .font(.caption.bold())
                        .foregroundStyle(.primary)
                }
                .padding(.top, 2)

                if dist < 0.5 {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Text("You have arrived!")
                            .font(.caption.bold())
                            .foregroundStyle(.green)
                    }
                }
            }
        }
    }

    private func destinationButton(for dest: NavigationAnchor) -> some View {
        let isSelected = sessionManager.selectedDestination?.identifier == dest.identifier

        return Button {
            if isSelected {
                sessionManager.clearNavigation()
            } else {
                sessionManager.selectDestination(dest)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isSelected ? "flag.fill" : "mappin.circle.fill")
                Text(dest.destinationName)
                    .font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? Color.cyan.opacity(0.3) : Color.clear)
            .overlay(
                Capsule()
                    .stroke(isSelected ? Color.cyan : Color.secondary.opacity(0.4), lineWidth: 1)
            )
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(trackingColor)
                    .frame(width: 8, height: 8)
                Text("Tracking: \(sessionManager.trackingStateText)")
                    .font(.caption)
                    .foregroundStyle(.primary)
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(mappingColor)
                    .frame(width: 8, height: 8)
                Text("World Map: \(sessionManager.worldMappingStatusText)")
                    .font(.caption)
                    .foregroundStyle(.primary)
            }

            if sessionManager.isSceneReconstructionSupported {
                HStack(spacing: 6) {
                    Image(systemName: "viewfinder")
                        .font(.caption2)
                    Text("LiDAR Scene Reconstruction Active")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Text(sessionManager.sessionInfoText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }

    // MARK: - Status Colors

    private var trackingColor: Color {
        switch sessionManager.trackingState {
        case .normal:       return .green
        case .notAvailable: return .red
        case .limited:      return .yellow
        }
    }

    private var mappingColor: Color {
        switch sessionManager.worldMappingStatus {
        case .mapped:       return .green
        case .extending:    return .yellow
        case .limited:      return .orange
        case .notAvailable: return .red
        @unknown default:   return .gray
        }
    }
}
