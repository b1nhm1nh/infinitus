import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// SessionFeedScreen's composer field, as a UITextView: a SwiftUI
/// TextField only accepts text pastes, so the iOS keyboard's paste chip
/// ("Photo — Paste from Screenshots") did nothing (user 2026-09-04
/// "pasting an image from the keyboard chip into Reply does nothing").
/// This accepts an image paste via UITextPasteDelegate and hands it to
/// the screen's existing addImage; a text paste falls through untouched.
struct PasteableTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var placeholder: String
    var onPasteImage: (UIImage) -> Void

    static let minHeight: CGFloat = 36
    static let maxHeight: CGFloat = 120 // ~6 lines at body size

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = UIFont.preferredFont(forTextStyle: .body)
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 6, left: 5, bottom: 6, right: 5)
        view.textContainer.lineFragmentPadding = 0
        view.layer.borderWidth = 0.5
        view.layer.borderColor = UIColor.separator.cgColor
        view.layer.cornerRadius = 6
        view.delegate = context.coordinator
        view.pasteDelegate = context.coordinator
        view.pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [
            UTType.image.identifier, UTType.utf8PlainText.identifier, UTType.plainText.identifier
        ])
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text { view.text = text }
        if isFocused, !view.isFirstResponder {
            view.becomeFirstResponder()
        } else if !isFocused, view.isFirstResponder {
            view.resignFirstResponder()
        }
        view.isScrollEnabled = context.coordinator.contentHeight(for: view) > Self.maxHeight
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.bounds.width
        guard width > 0 else { return nil }
        let height = min(max(context.coordinator.contentHeight(for: uiView, width: width), Self.minHeight),
                          Self.maxHeight)
        return CGSize(width: width, height: height)
    }

    final class Coordinator: NSObject, UITextViewDelegate, UITextPasteDelegate {
        var parent: PasteableTextView

        init(_ parent: PasteableTextView) { self.parent = parent }

        func contentHeight(for textView: UITextView, width: CGFloat? = nil) -> CGFloat {
            textView.sizeThatFits(CGSize(width: width ?? textView.bounds.width, height: .infinity)).height
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            DispatchQueue.main.async { self.parent.isFocused = true }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            DispatchQueue.main.async { self.parent.isFocused = false }
        }

        func textPasteConfigurationSupporting(
            _ textPasteConfigurationSupporting: UITextPasteConfigurationSupporting,
            transform item: UITextPasteItem
        ) {
            guard item.itemProvider.canLoadObject(ofClass: UIImage.self) else {
                item.setDefaultResult()
                return
            }
            item.itemProvider.loadObject(ofClass: UIImage.self) { [onPasteImage = parent.onPasteImage] object, _ in
                guard let image = object as? UIImage else { return }
                DispatchQueue.main.async { onPasteImage(image) }
            }
            item.setNoResult()
        }
    }
}
