import Foundation
import Testing
@testable import MaGiKaraKit

@Suite("运行环境配置单", .serialized)
struct RuntimeSetupTests {

    @Test func separationModelFollowsSelectedMirror() {
        let url = VocalSeparationModelInfo.mdx23cInstVocHQ.downloadURL(endpoint: DownloadSource.china.huggingFace)
        #expect(url.absoluteString.hasPrefix("https://hf-mirror.com/huggingsounds/nubeaudio-mdx/resolve/"))
    }

    @Test func checklistListsAllComponentsWithLicenses() {
        let components = RuntimeSetup.components()
        #expect(components.map(\.id) == RuntimeComponentID.allCases)
        let aligner = components.first { $0.id == .alignerModel }
        #expect(aligner?.license.contains("非商业") == true)
        #expect(aligner?.downloadBytes == 1_261_938_632)
    }

    @Test func requirementsLockIsBundledAndPinned() throws {
        let url = try #require(RuntimeSetup.requirementsURL)
        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }
        #expect(lines.allSatisfy { $0.contains("==") })
        for package in ["torch==", "torchaudio==", "transformers==", "pykakasi=="] {
            #expect(lines.contains { $0.hasPrefix(package) })
        }
    }
}
