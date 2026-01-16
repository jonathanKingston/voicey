import SwiftUI
import AppKit

struct ModelDownloadView: View {
    @ObservedObject var modelManager = ModelManager.shared
    var onDone: (() -> Void)?
    
    init(onDone: (() -> Void)? = nil) {
        self.onDone = onDone
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "cpu")
                    .font(.system(size: 40))
                    .foregroundStyle(.blue)
                
                Text("Whisper Models")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("Download a speech recognition model to enable transcription.\nLarger models are more accurate but require more memory.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 24)
            .padding(.horizontal)
            
            Divider()
            
            // Model list
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(WhisperModel.allCases) { model in
                        ModelDownloadRow(model: model)
                        if model != WhisperModel.allCases.last {
                            Divider()
                                .padding(.leading, 60)
                        }
                    }
                }
            }
            
            Divider()
            
            // Footer
            HStack {
                if let error = modelManager.downloadError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
                
                Spacer()
                
                Button("Done") {
                    onDone?()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!modelManager.hasDownloadedModel)
            }
            .padding()
        }
        .frame(width: 450, height: 500)
        .onAppear {
            // Refresh model status on appear
            modelManager.loadDownloadedModels()
        }
    }
}

struct ModelDownloadRow: View {
    let model: WhisperModel
    @ObservedObject var modelManager = ModelManager.shared
    @State private var deleteError: String?
    @State private var showDeleteError = false
    
    var body: some View {
        HStack(spacing: 16) {
            // Icon
            ZStack {
                Circle()
                    .fill(iconBackground)
                    .frame(width: 44, height: 44)
                
                Image(systemName: iconName)
                    .font(.system(size: 18))
                    .foregroundStyle(iconColor)
            }
            
            // Info
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(model.displayName)
                        .font(.headline)
                    
                    if model.isRecommended {
                        Text("Recommended")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.2))
                            .foregroundStyle(.blue)
                            .cornerRadius(4)
                    }
                }
                
                Text(model.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                // Progress bar during download (indeterminate since WhisperKit doesn't expose progress)
                if modelManager.isDownloading[model, default: false] {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .scaleEffect(x: 1, y: 0.5, anchor: .center)
                }
            }
            
            Spacer()
            
            // Action button
            actionButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
    
    @ViewBuilder
    private var actionButton: some View {
        if modelManager.isDownloading[model, default: false] {
            Button {
                modelManager.cancelDownload(model)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        } else if modelManager.isDownloaded(model) {
            Menu {
                Button("Delete", role: .destructive) {
                    do {
                        try modelManager.deleteModel(model)
                    } catch {
                        deleteError = error.localizedDescription
                        showDeleteError = true
                    }
                }
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.green)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 30)
            .alert("Failed to Delete Model", isPresented: $showDeleteError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(deleteError ?? "Unknown error")
            }
        } else {
            Button {
                modelManager.downloadModel(model)
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
    }
    
    private var iconBackground: Color {
        if modelManager.isDownloaded(model) {
            return .green.opacity(0.15)
        } else if modelManager.isDownloading[model, default: false] {
            return .blue.opacity(0.15)
        }
        return .gray.opacity(0.1)
    }
    
    private var iconName: String {
        switch model {
        case .largeTurbo: return "bolt.fill"
        case .large: return "star.fill"
        case .distilLarge: return "brain.head.profile"
        case .small: return "scalemass"
        case .base: return "gauge.medium"
        case .tiny: return "hare"
        }
    }
    
    private var iconColor: Color {
        if modelManager.isDownloaded(model) {
            return .green
        } else if modelManager.isDownloading[model, default: false] {
            return .blue
        }
        return .secondary
    }
}

#Preview {
    ModelDownloadView()
}
