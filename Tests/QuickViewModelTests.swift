import Testing
import Foundation
import AppKit
@testable import apfel_quick

// These tests are written in the RED phase — QuickViewModel does not yet exist.
// They define the intended API and will compile once QuickViewModel is implemented.

@MainActor
@Suite("QuickViewModel", .serialized)
struct QuickViewModelTests {

    // MARK: - 1. Streaming output accumulates correctly

    @Test func testSubmitStreamsOutput() async throws {
        let service = MockQuickService()
        await service.setResponses([
            StreamDelta(text: "Hello", finishReason: nil),
            StreamDelta(text: " world", finishReason: nil),
            StreamDelta(text: "!", finishReason: .some("stop")),
        ])
        let vm = QuickViewModel(service: service)
        vm.settings.autoCopy = false
        vm.input = "Say hello"
        await vm.submit()
        #expect(vm.output == "Hello world!")
    }

    // MARK: - 2. Error is cleared before streaming starts

    @Test func testSubmitClearsErrorBeforeStreaming() async throws {
        let service = MockQuickService()
        await service.setResponses([
            StreamDelta(text: "ok", finishReason: .some("stop")),
        ])
        let vm = QuickViewModel(service: service)
        vm.settings.autoCopy = false
        vm.input = "prompt"
        // Pre-seed an error
        vm.errorMessage = "previous error"
        await vm.submit()
        #expect(vm.errorMessage == nil)
    }

    // MARK: - 3. Output is cleared before a new stream starts

    @Test func testSubmitClearsOutputBeforeNewStream() async throws {
        let service = MockQuickService()
        await service.setResponses([
            StreamDelta(text: "fresh", finishReason: .some("stop")),
        ])
        let vm = QuickViewModel(service: service)
        vm.settings.autoCopy = false
        vm.input = "first"
        vm.output = "stale result from previous run"
        await vm.submit()
        #expect(vm.output == "fresh")
    }

    // MARK: - 4. isStreaming is true during stream

    @Test func testIsStreamingTrueDuringStream() async throws {
        let service = MockQuickService()
        await service.setResponses([
            StreamDelta(text: "chunk", finishReason: nil),
            StreamDelta(text: " more", finishReason: nil),
        ])
        await service.setDelay(.milliseconds(200))

        let vm = QuickViewModel(service: service)
        vm.input = "long prompt"

        let submitTask = Task { await vm.submit() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(vm.isStreaming == true)
        await submitTask.value
    }

    // MARK: - 5. isStreaming is false after stream finishes

    @Test func testIsStreamingFalseAfterStream() async throws {
        let service = MockQuickService()
        await service.setResponses([
            StreamDelta(text: "done", finishReason: .some("stop")),
        ])
        let vm = QuickViewModel(service: service)
        vm.settings.autoCopy = false
        vm.input = "prompt"
        await vm.submit()
        #expect(vm.isStreaming == false)
    }

    // MARK: - 6. Auto-copy enabled writes to clipboard on completion

    @Test func testAutoCopyOnCompletionWhenEnabled() async throws {
        let service = MockQuickService()
        await service.setResponses([
            StreamDelta(text: "Copied text", finishReason: .some("stop")),
        ])
        let vm = QuickViewModel(service: service)
        vm.settings.autoCopy = true
        vm.input = "Give me something to copy"
        await vm.submit()
        let clipboardValue = NSPasteboard.general.string(forType: .string)
        #expect(clipboardValue == "Copied text")
    }

    // MARK: - 7. Auto-copy disabled leaves clipboard untouched

    @Test func testAutoCopyDisabledSkipsClipboard() async throws {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("sentinel", forType: .string)

        let service = MockQuickService()
        await service.setResponses([
            StreamDelta(text: "Should not be copied", finishReason: .some("stop")),
        ])
        let vm = QuickViewModel(service: service)
        vm.settings.autoCopy = false
        vm.input = "Don't copy this"
        await vm.submit()

        let clipboardValue = NSPasteboard.general.string(forType: .string)
        #expect(clipboardValue == "sentinel")
    }

    // MARK: - 8. cancel() stops isStreaming

    @Test func testCancelStopsStreaming() async throws {
        let service = MockQuickService()
        await service.setResponses([
            StreamDelta(text: "chunk one", finishReason: nil),
            StreamDelta(text: "chunk two", finishReason: nil),
        ])
        await service.setDelay(.milliseconds(200))

        let vm = QuickViewModel(service: service)
        vm.input = "Long running prompt"

        let submitTask = Task { await vm.submit() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(vm.isStreaming == true)

        vm.cancel()
        await submitTask.value

        #expect(vm.isStreaming == false)
    }

    // MARK: - 9. cancel() clears output

    @Test func testCancelClearsOutput() async throws {
        let service = MockQuickService()
        await service.setResponses([
            StreamDelta(text: "partial", finishReason: nil),
            StreamDelta(text: " more", finishReason: nil),
        ])
        await service.setDelay(.milliseconds(200))

        let vm = QuickViewModel(service: service)
        vm.input = "prompt"

        let submitTask = Task { await vm.submit() }
        try await Task.sleep(for: .milliseconds(50))
        vm.cancel()
        await submitTask.value

        #expect(vm.output == "")
    }

    // MARK: - 10. Service error surfaces in errorMessage

    @Test func testServiceErrorSetsErrorMessage() async throws {
        let service = MockQuickService()
        await service.setShouldThrow(true)

        let vm = QuickViewModel(service: service)
        vm.input = "This will fail"
        await vm.submit()

        #expect(vm.errorMessage != nil)
        #expect(vm.isStreaming == false)
    }

    // MARK: - 11. Nil service shows "Not connected" error

    @Test func testServiceNilShowsErrorMessage() async throws {
        let vm = QuickViewModel(service: nil as (any QuickService)?)
        vm.input = "hello"
        await vm.submit()

        #expect(vm.errorMessage != nil)
        let msg = vm.errorMessage ?? ""
        #expect(msg.lowercased().contains("connect") || msg.lowercased().contains("not connected"))
        #expect(vm.isStreaming == false)
    }

    // MARK: - 12. Empty input does not call service

    @Test func testEmptyInputDoesNotSubmit() async throws {
        let service = MockQuickService()
        let vm = QuickViewModel(service: service)
        vm.input = ""
        await vm.submit()
        let callCount = await service.sendCallCount
        #expect(callCount == 0)
    }

    // MARK: - 13. clearOutput() resets output and errorMessage

    @Test func testClearOutputResetsState() async throws {
        let vm = QuickViewModel(service: MockQuickService())
        vm.output = "some result"
        vm.errorMessage = "some error"
        vm.clearOutput()
        #expect(vm.output == "")
        #expect(vm.errorMessage == nil)
    }

    // MARK: - 14. copyOutput() writes to clipboard

    @Test func testCopyOutputWritesToClipboard() async throws {
        NSPasteboard.general.clearContents()
        let vm = QuickViewModel(service: MockQuickService())
        vm.output = "content to copy"
        vm.copyOutput()
        let clipboardValue = NSPasteboard.general.string(forType: .string)
        #expect(clipboardValue == "content to copy")
    }

    // MARK: - 15. copyOutput() with empty output is a no-op

    @Test func testCopyOutputEmptyStringIsNoOp() async throws {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("existing clipboard", forType: .string)

        let vm = QuickViewModel(service: MockQuickService())
        vm.output = ""
        vm.copyOutput()

        let clipboardValue = NSPasteboard.general.string(forType: .string)
        // Either clipboard is unchanged or empty — either is acceptable no-op behaviour
        let isUnchangedOrEmpty = clipboardValue == "existing clipboard" || clipboardValue == nil || clipboardValue == ""
        #expect(isUnchangedOrEmpty)
    }

    // MARK: - 16. Newer remote version sets .updateAvailable

    @Test func testHandleUpdateCheckNewerVersionSetsAvailable() async throws {
        let vm = QuickViewModel(service: MockQuickService(), currentVersion: "1.0.0")
        await vm.handleUpdateCheck(remoteVersion: "1.0.1")
        #expect(vm.updateState == .updateAvailable(newVersion: "1.0.1"))
    }

    // MARK: - 17. Same version sets .upToDate

    @Test func testHandleUpdateCheckSameVersionSetsUpToDate() async throws {
        let vm = QuickViewModel(service: MockQuickService(), currentVersion: "1.0.0")
        await vm.handleUpdateCheck(remoteVersion: "1.0.0")
        #expect(vm.updateState == .upToDate)
    }

    // MARK: - 18. Older remote version sets .upToDate

    @Test func testHandleUpdateCheckOlderVersionSetsUpToDate() async throws {
        let vm = QuickViewModel(service: MockQuickService(), currentVersion: "1.0.1")
        await vm.handleUpdateCheck(remoteVersion: "1.0.0")
        #expect(vm.updateState == .upToDate)
    }

    // MARK: - 19. Major version bump detected as update

    @Test func testHandleUpdateCheckMajorVersionComparison() async throws {
        let vm = QuickViewModel(service: MockQuickService(), currentVersion: "1.9.9")
        await vm.handleUpdateCheck(remoteVersion: "2.0.0")
        #expect(vm.updateState == .updateAvailable(newVersion: "2.0.0"))
    }

    // MARK: - 20. Minor version bump detected as update

    @Test func testHandleUpdateCheckMinorVersionComparison() async throws {
        let vm = QuickViewModel(service: MockQuickService(), currentVersion: "1.0.9")
        await vm.handleUpdateCheck(remoteVersion: "1.1.0")
        #expect(vm.updateState == .updateAvailable(newVersion: "1.1.0"))
    }

    // MARK: - 21. delta with finishReason ends stream, text-nil delta not appended

    @Test func testFinishReasonStopsStream() async throws {
        let service = MockQuickService()
        await service.setResponses([
            StreamDelta(text: "first", finishReason: nil),
            StreamDelta(text: nil, finishReason: "stop"),
        ])
        let vm = QuickViewModel(service: service)
        vm.settings.autoCopy = false
        vm.input = "prompt"
        await vm.submit()
        #expect(vm.isStreaming == false)
        #expect(vm.output == "first")
    }

    // MARK: - 22. delta with nil text is ignored (output unchanged)

    @Test func testOutputWithNilTextDeltasIgnored() async throws {
        let service = MockQuickService()
        await service.setResponses([
            StreamDelta(text: "real text", finishReason: nil),
            StreamDelta(text: nil, finishReason: nil),
            StreamDelta(text: nil, finishReason: "stop"),
        ])
        let vm = QuickViewModel(service: service)
        vm.settings.autoCopy = false
        vm.input = "prompt"
        await vm.submit()
        #expect(vm.output == "real text")
    }

    // MARK: - Legacy: original test kept for compatibility

    @Test func testUpdateAvailableDetected() async throws {
        let vm = QuickViewModel(
            service: MockQuickService(),
            currentVersion: "1.0.0"
        )
        await vm.handleUpdateCheck(remoteVersion: "1.1.0")
        #expect(vm.updateState == .updateAvailable(newVersion: "1.1.0"))
    }
}

// MARK: - MockQuickService helpers (actor-isolated setters, called with await)

extension MockQuickService {
    func setResponses(_ value: [StreamDelta]) {
        responses = value
    }
    func setShouldThrow(_ value: Bool) {
        shouldThrow = value
    }
    func setDelay(_ value: Duration) {
        delay = value
    }
}
