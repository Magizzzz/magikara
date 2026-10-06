import Testing
@testable import MaGiKaraKit

@Suite struct AudioFeatureVADTests {

    @Test func energyVADPreservesClearlySeparatedPhraseIslands() {
        var phraseMask = [Bool](repeating: false, count: 40)
        for _ in 0..<8 {
            phraseMask.append(contentsOf: repeatElement(true, count: 100))
            phraseMask.append(contentsOf: repeatElement(false, count: 35))
        }
        let energyDB: [Float] = phraseMask.map { $0 ? -18.0 : -70.0 }
        let detected = AudioFeatureExtractor.detectVoicedByEnergy(energyDB: energyDB).voiced

        #expect(detected == phraseMask,
                "VAD 应保留时长明确的人声段和句间空白")
    }
}
