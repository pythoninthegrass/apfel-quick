import SwiftUI
import Combine

struct OverlayView: View {
    @Bindable var viewModel: QuickViewModel
    @FocusState private var inputFocused: Bool
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            // Input row
            HStack(spacing: 8) {
                TextField("Ask anything…", text: $viewModel.input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($inputFocused)
                    .submitLabel(.send)
                    .onSubmit { Task { await viewModel.submit() } }
                    .disabled(viewModel.isStreaming)

                // Send button — works even if onSubmit doesn't fire on some panel setups
                Button {
                    Task { await viewModel.submit() }
                } label: {
                    Image(systemName: viewModel.isStreaming ? "stop.fill" : "arrow.up.circle.fill")
                        .foregroundStyle(Color(red: 0.55, green: 0.36, blue: 0.96))
                        .font(.system(size: 20))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(viewModel.input.isEmpty && !viewModel.isStreaming)
                .help("Send (or press Return)")

                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gear")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 15))
                }
                .buttonStyle(.plain)
                .help("Settings")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            // Divider + result (only shown when there's output or streaming)
            if !viewModel.output.isEmpty || viewModel.isStreaming {
                Divider()
                ScrollView {
                    Text(viewModel.output + (viewModel.isStreaming ? "▋" : ""))
                        .font(.system(size: 14))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(20)
                }
                .frame(maxHeight: 380)
            }

            // Copied-to-clipboard flash
            if viewModel.justCopied {
                CopiedFlashView()
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.9)),
                        removal: .opacity
                    ))
            }

            // Error message
            if let error = viewModel.errorMessage {
                Divider()
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
            }
        }
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onAppear { inputFocused = true }
        .onKeyPress(.escape) {
            if viewModel.isStreaming {
                viewModel.cancel()
            }
            // AppDelegate handles actual window dismissal
            NotificationCenter.default.post(name: .dismissOverlay, object: nil)
            return .handled
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(viewModel: viewModel)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            showSettings = true
        }
    }
}

extension Notification.Name {
    static let dismissOverlay = Notification.Name("ApfelQuick.dismissOverlay")
    static let openSettings = Notification.Name("ApfelQuick.openSettings")
}

// MARK: - Animated "Copied!" flash

private struct CopiedFlashView: View {
    @State private var scale: CGFloat = 0.6
    @State private var opacity: Double = 0.0

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(red: 0.18, green: 0.74, blue: 0.38))
                .scaleEffect(scale)
                .opacity(opacity)
            Text("Copied to clipboard")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(red: 0.18, green: 0.74, blue: 0.38))
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color(red: 0.18, green: 0.74, blue: 0.38).opacity(0.08))
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) {
                scale = 1.0
                opacity = 1.0
            }
        }
    }
}
