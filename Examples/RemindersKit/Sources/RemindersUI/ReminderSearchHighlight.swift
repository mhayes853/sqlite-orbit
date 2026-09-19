import Foundation
import SwiftUI

public enum ReminderSearchHighlight {
  public static func attributedString(_ markdown: String) -> AttributedString? {
    guard var text = try? AttributedString(markdown: markdown) else { return nil }
    let highlightedRanges = text.runs.compactMap { run in
      run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        ? run.range
        : nil
    }
    for range in highlightedRanges {
      text[range].backgroundColor = .yellow.opacity(0.35)
    }
    return text
  }
}
