import Foundation
import SwiftUI

extension AttributedString {
  public init?(searchHighlighting markdown: String) {
    guard var text = try? Self(markdown: markdown) else { return nil }
    let highlightedRanges = text.runs.compactMap { run in
      run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        ? run.range
        : nil
    }
    for range in highlightedRanges {
      text[range].backgroundColor = .yellow.opacity(0.35)
    }
    self = text
  }
}
