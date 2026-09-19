import RemindersData
import SwiftUI

struct TagRow: View {
  let tag: Tag

  var body: some View {
    Label(tag.title, systemImage: "number.circle.fill")
      .font(.body)
  }
}
