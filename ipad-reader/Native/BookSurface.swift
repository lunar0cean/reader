import SwiftUI

/// Portrait clips the same page-pair canvas; crossing strokes remain editable.
struct BookSurface: View {
    @EnvironmentObject private var store: ReaderStore
    @ObservedObject var controls: InkControls
    var start: Int
    var spread: Bool
    var preview = false
    private var pairStart: Int { start - start % 2 }
    private var width: CGFloat { CGFloat(store.layout.width) }
    private var height: CGFloat { CGFloat(store.layout.height) }
    private var visibleOffset: CGFloat { spread ? 0 : CGFloat(start % 2) * width }

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) { leaf(pairStart); leaf(pairStart + 1) }
            if let book = store.book {
                PencilSurface(pageID: store.spreadKey(start: pairStart), bookID: book.id,
                              drawing: store.spreadDrawing(start: pairStart),
                              sourceData: store.spreadData(start: pairStart),
                              editing: !preview && !store.isPaginating && store.isAnnotating && store.showInk,
                              logicalSize: CGSize(width: width * 2, height: height), controls: controls,
                              onChange: store.saveSpreadDrawing)
                    .id("\(book.id):\(store.spreadKey(start: pairStart))")
                    .opacity(store.showInk ? 1 : 0)
                    .frame(width: width * 2, height: height)
            }
        }.frame(width: width * 2, height: height, alignment: .topLeading)
            .offset(x: -visibleOffset)
            .frame(width: spread ? width * 2 : width, height: height, alignment: .topLeading)
            .clipped()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(spread ? "reader-spread" : "reader-single-page")
    }

    @ViewBuilder private func leaf(_ index: Int) -> some View {
        if store.pages.indices.contains(index), let book = store.book {
            let page = store.pages[index]
            PaperContentView(page: page, book: book, layout: store.layout, theme: store.backup.theme,
                             pageNumber: index + 1, reference: store.referenceAnchor, speech: store.speechHighlight,
                             onImage: { store.media = ReaderMedia(image: $0) }, onRead: { store.readAloudText = $0 })
                .frame(width: width, height: height)
        } else {
            Color(uiColor: ReaderPalette.paper(store.backup.theme)).frame(width: width, height: height)
        }
    }
}
