//
//  CandidateReranker.swift
//  Squirrel
//

import CryptoKit
import Foundation

struct CandidateRankingContext {
  let input: String
  let precedingText: String
  let application: String
  let candidates: [String]
}

final class CandidateReranker {
  private struct Model: Codable {
    var featureCounts = [String: Double]()
    var recentSelections = [String: Date]()
  }

  private let fileManager = FileManager.default
  private let modelURL: URL
  private var model = Model()
  private var saveTimer: Timer?
  private(set) var isEnabled: Bool

  init() {
    let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    modelURL = appSupport
      .appendingPathComponent("Squirrel", isDirectory: true)
      .appendingPathComponent("AdaptiveRanking", isDirectory: true)
      .appendingPathComponent("model.json")
    if UserDefaults.standard.object(forKey: "adaptive_candidate_ranking") == nil {
      isEnabled = true
    } else {
      isEnabled = UserDefaults.standard.bool(forKey: "adaptive_candidate_ranking")
    }
    load()
  }

  func rankedIndices(
    candidates: [String],
    input: String,
    precedingText: String,
    application: String
  ) -> [Int] {
    guard isEnabled, candidates.count > 1 else { return Array(candidates.indices) }
    let suffixes = contextSuffixes(precedingText)
    let scored = candidates.enumerated().map { index, candidate in
      let candidateID = digest(candidate)
      var adaptiveScore = 0.0
      adaptiveScore += 0.20 * log1p(count("candidate", candidateID))
      adaptiveScore += 1.30 * log1p(count("input", digest(input), candidateID))
      adaptiveScore += 0.25 * log1p(count("app", digest(application), candidateID))
      for (length, suffix) in suffixes {
        adaptiveScore += (0.18 + 0.09 * Double(length)) *
          log1p(count("context", digest(suffix), candidateID))
      }
      if let date = model.recentSelections[candidateID] {
        let age = max(0, Date.now.timeIntervalSince(date))
        adaptiveScore += 0.35 * exp(-age / (24 * 60 * 60))
      }

      // Rime's rank remains the prior. Learned evidence has to overcome a
      // predictable distance penalty, which prevents an immature model from
      // shuffling candidates randomly.
      let score = adaptiveScore - 0.52 * Double(index)
      return (index: index, score: score)
    }
    return scored.sorted {
      if abs($0.score - $1.score) < 0.000_001 {
        return $0.index < $1.index
      }
      return $0.score > $1.score
    }.map(\.index)
  }

  func learn(chosen: String, context: CandidateRankingContext) {
    guard isEnabled, !chosen.isEmpty, !context.input.isEmpty else { return }
    let candidateID = digest(chosen)
    increment("candidate", candidateID)
    increment("input", digest(context.input), candidateID)
    increment("app", digest(context.application), candidateID)
    for (_, suffix) in contextSuffixes(context.precedingText) {
      increment("context", digest(suffix), candidateID)
    }
    model.recentSelections[candidateID] = .now
    pruneIfNeeded()
    scheduleSave()
  }

  func flush() {
    saveTimer?.invalidate()
    saveTimer = nil
    save()
  }

  @discardableResult
  func toggleEnabled() -> Bool {
    isEnabled.toggle()
    UserDefaults.standard.set(isEnabled, forKey: "adaptive_candidate_ranking")
    return isEnabled
  }
}

private extension CandidateReranker {
  func contextSuffixes(_ text: String) -> [(Int, String)] {
    let characters = Array(text.suffix(8))
    guard !characters.isEmpty else { return [] }
    return (1...min(6, characters.count)).map { length in
      (length, String(characters.suffix(length)))
    }
  }

  func count(_ components: String...) -> Double {
    model.featureCounts[featureKey(components)] ?? 0
  }

  func increment(_ components: String...) {
    let key = featureKey(components)
    model.featureCounts[key, default: 0] += 1
  }

  func featureKey(_ components: [String]) -> String {
    digest(components.joined(separator: "\u{0}"))
  }

  func digest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8))
      .prefix(12)
      .map { String(format: "%02x", $0) }
      .joined()
  }

  func scheduleSave() {
    saveTimer?.invalidate()
    saveTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
      self?.saveTimer = nil
      self?.save()
    }
  }

  func pruneIfNeeded() {
    let maximumFeatures = 50_000
    guard model.featureCounts.count > maximumFeatures else { return }
    let keep = model.featureCounts.sorted { $0.value > $1.value }.prefix(maximumFeatures * 4 / 5)
    model.featureCounts = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    let recentCutoff = Date.now.addingTimeInterval(-30 * 24 * 60 * 60)
    model.recentSelections = model.recentSelections.filter { $0.value >= recentCutoff }
  }

  func load() {
    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .millisecondsSince1970
      model = try decoder.decode(Model.self, from: Data(contentsOf: modelURL))
    } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
        error.code == NSFileReadNoSuchFileError {
      model = Model()
    } catch {
      print("Unable to load adaptive ranking model: \(error.localizedDescription)")
      model = Model()
    }
  }

  func save() {
    do {
      try fileManager.createDirectory(
        at: modelURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .millisecondsSince1970
      try encoder.encode(model).write(to: modelURL, options: .atomic)
    } catch {
      print("Unable to save adaptive ranking model: \(error.localizedDescription)")
    }
  }
}
