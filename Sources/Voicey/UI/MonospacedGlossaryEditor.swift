import AppKit
import SwiftUI

/// Multi-line glossary editor with matching insets for typed text and the empty-state placeholder.
struct MonospacedGlossaryEditor: View {
  @Binding var text: String
  let placeholder: String

  private static let horizontalInset: CGFloat = 8
  private static let verticalInset: CGFloat = 8
  private static let monospacedFont = NSFont.monospacedSystemFont(
    ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize,
    weight: .regular
  )

  var body: some View {
    InsetTextEditor(
      text: $text,
      font: Self.monospacedFont,
      horizontalInset: Self.horizontalInset,
      verticalInset: Self.verticalInset
    )
    .frame(minHeight: 80, maxHeight: 140)
    .overlay(alignment: .topLeading) {
      if text.isEmpty {
        Text(placeholder)
          .font(.system(.body, design: .monospaced))
          .foregroundStyle(.tertiary)
          .padding(.horizontal, Self.horizontalInset)
          .padding(.vertical, Self.verticalInset)
          .allowsHitTesting(false)
      }
    }
  }
}

private struct InsetTextEditor: NSViewRepresentable {
  @Binding var text: String
  let font: NSFont
  let horizontalInset: CGFloat
  let verticalInset: CGFloat

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text)
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSTextView.scrollableTextView()
    configure(scrollView: scrollView, context: context)
    (scrollView.documentView as? NSTextView)?.string = text
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    configure(scrollView: scrollView, context: context)
    guard let textView = scrollView.documentView as? NSTextView else { return }
    if textView.string != text {
      textView.string = text
    }
  }

  private func configure(scrollView: NSScrollView, context: Context) {
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = false

    guard let textView = scrollView.documentView as? NSTextView else { return }
    textView.delegate = context.coordinator
    textView.isRichText = false
    textView.isEditable = true
    textView.isSelectable = true
    textView.font = font
    textView.textContainerInset = NSSize(width: horizontalInset, height: verticalInset)
    textView.backgroundColor = .clear
    textView.drawsBackground = false
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var text: Binding<String>

    init(text: Binding<String>) {
      self.text = text
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      text.wrappedValue = textView.string
    }
  }
}
