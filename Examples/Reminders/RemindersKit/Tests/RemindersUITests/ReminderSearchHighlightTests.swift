import Foundation
import Testing

@testable import RemindersUI

struct ReminderSearchHighlightTests {
  @Test
  func highlightedTextUsesBoldTextAndABackgroundColor() throws {
    let text = try #require(
      AttributedString(searchHighlighting: "Call **Blob** today")
    )
    let highlightedRun = try #require(
      text.runs.first {
        $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
      }
    )

    #expect(String(text.characters) == "Call Blob today")
    #expect(highlightedRun.backgroundColor != nil)
  }
}
