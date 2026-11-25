import XCTest
@testable import Silo
import AetherEngine

/// Silo's AetherEngine fork sets which optional engine components are compiled in.
/// This personal fork turns on the two object-audio components so TrueHD Atmos and
/// DTS:X keep their heights; the Dolby Vision components stay off.
final class AetherOptionalComponentsTests: XCTestCase {

    private static let enabled: Set<String> = ["TrueHDObjectAudio", "DTSXObjectAudio"]

    func testOnlyObjectAudioComponentsAreBuiltIn() {
        for component in AetherEngine.OptionalComponent.allCases {
            XCTAssertEqual(
                component.isBuiltIn,
                Self.enabled.contains(component.traitName),
                "\(component.traitName) built-in state"
            )
        }
    }

    /// The TrueHD Atmos and DTS:X setting is shown and asks for APAC when on.
    func testObjectAudioSettingRequestsRenderingWhenOn() {
        XCTAssertTrue(AetherObjectAudioPolicy.isAvailable)
        XCTAssertEqual(AetherObjectAudioPolicy.rendering(enabled: true), .apac(AetherObjectAudioPolicy.layout))
        XCTAssertEqual(AetherObjectAudioPolicy.rendering(enabled: false), .off)
    }
}
