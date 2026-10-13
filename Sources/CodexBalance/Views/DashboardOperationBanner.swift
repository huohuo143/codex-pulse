import SwiftUI

struct DashboardOperationFeedback: Equatable {
  enum Kind: Equatable { case success, information, failure }
  let kind: Kind
  let message: String

  init(_ kind: Kind, _ message: String) { self.kind = kind; self.message = message }

  var symbol: String {
    switch kind {
    case .success: "checkmark.circle.fill"
    case .information: "info.circle.fill"
    case .failure: "exclamationmark.triangle.fill"
    }
  }
}

struct DashboardOperationBanner: View {
  let feedback: DashboardOperationFeedback
  let dismiss: () -> Void

  private var tint: Color {
    switch feedback.kind {
    case .success: .green
    case .information: .blue
    case .failure: .orange
    }
  }

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: feedback.symbol).foregroundStyle(tint)
      Text(feedback.message)
        .font(.system(size: 11, weight: .medium))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
      Button(action: dismiss) { Image(systemName: "xmark") }
        .buttonStyle(.plain)
        .accessibilityLabel("关闭操作提示")
        .help("关闭操作提示")
    }
    .padding(10)
    .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    .accessibilityElement(children: .contain)
  }
}
