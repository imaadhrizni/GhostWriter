import XCTest
@testable import GhostWriter

/// Unit tests for `GroqService.uploadFilename` — the multipart filename
/// normalization. Groq derives the audio format from the filename extension and
/// mishandles spaces/commas/non-ASCII, so we send a clean `audio.<ext>`.
final class GroqServiceTests: XCTestCase {

    private func name(_ path: String) -> String {
        GroqService.uploadFilename(for: URL(fileURLWithPath: path))
    }

    func testPreservesExtensionOnly() {
        XCTAssertEqual(name("/tmp/recording.m4a"), "audio.m4a")
        XCTAssertEqual(name("/tmp/clip.ogg"), "audio.ogg")
    }

    func testNormalizesMessyDisplayName() {
        // A real export name with spaces, commas, and non-ASCII → "audio.m4a".
        XCTAssertEqual(name("/tmp/Jul 26, 10.32 PM_café.m4a"), "audio.m4a")
    }

    func testLowercasesExtension() {
        XCTAssertEqual(name("/tmp/VOICE.WAV"), "audio.wav")
    }

    func testNoExtensionYieldsBareAudio() {
        XCTAssertEqual(name("/tmp/audiodump"), "audio")
    }
}
