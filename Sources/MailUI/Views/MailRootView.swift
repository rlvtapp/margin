import MailCore
import SwiftUI

/// The main window: sidebar, conversation list, reader. Everything is reachable from the
/// keyboard; ⌘K finds any command and ? lists the shortcuts.
public struct MailRootView: View {
    @Bindable var model: MailModel
    @FocusState private var listFocused: Bool
    @FocusState private var searchFocused: Bool
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency

    public init(model: MailModel) {
        self.model = model
    }

    private func applyLook() -> String {
        Look.apply(model, systemContrast: systemContrast, systemReduceMotion: systemReduceMotion,
                   systemReduceTransparency: systemReduceTransparency)
    }

    public var body: some View {
        let lookKey = applyLook()
        VStack(spacing: 0) {
            #if os(macOS)
            // Search across the top of the whole window, its line running edge to edge; the
            // window buttons sit at its left end, and every column starts under it.
            WindowBar(model: model, searchFocus: $searchFocused)
                .background(WindowButtonPlacement(barHeight: WindowBar.height))
                // Above the columns, so the "Ask: …" offer under the search field isn't covered.
                .zIndex(1)
            #endif
            HStack(spacing: 0) {
            AccountRail(model: model)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    // The Calendar has the whole width; mailboxes come back with the mail.
                    if !model.isSidebarHidden && model.place != .calendar {
                        SidebarView(model: model)
                            .frame(width: 220)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    // The list and the reader: edge to edge on the window with a hairline where they meet
                    // the sidebar, or in a rounded inset panel (Settings → Appearance → Window). Their
                    // own view, so dragging the list's edge redraws only these two.
                    if model.insetPanel {
                        ListAndReader(model: model, listFocused: $listFocused, searchFocused: $searchFocused)
                            .background(Paper.panel)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Line.edge))
                            .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
                            .padding([.top, .bottom, .trailing], 8)
                            .padding(.leading, model.isSidebarHidden ? 8 : 0)
                    } else {
                        Rectangle().fill(Line.hairline).frame(width: 1)
                        ListAndReader(model: model, listFocused: $listFocused, searchFocused: $searchFocused)
                            .background(Paper.panel)
                    }
                }
            }
        }
        }
        .animation(Motion.present, value: model.isSidebarHidden)
        // Colours are read from the tokens, so redraw everything when the look changes.
        .id(lookKey)
        .background(Paper.sidebar)
        .environment(\.mailAccent, Palette.account(model.accentIndex))
        .preferredColorScheme(model.appearance.colorScheme)
        .onChange(of: model.dropDownAlert?.id) { _, id in
            #if os(macOS)
            guard id != nil, let thread = model.dropDownAlert else { return }
            DropDownAlertWindow.shared.show(thread, model: model)
            #endif
            model.dropDownAlert = nil
        }
        #if os(macOS)
        // The title bar is hidden; the panes run to the top edge and share one top band.
        .ignoresSafeArea(.container, edges: .top)
        #endif
        .onKeyPress(phases: .down) { press in handle(press) }
        .overlay { paletteLayer }
        .overlay(alignment: .bottom) { NoticeBar(model: model).padding(.bottom, Space.l) }
        // The assistant at work ("Sort my mail", "Ask Margin to…"), out of the reader's way.
        .overlay(alignment: .bottomTrailing) { AgentRunCard(model: model).padding(Space.l) }
        .animation(Motion.present, value: model.agentRun?.id)
        // New mail opens in the reading pane (ListAndReader); only Subscriptions, which has
        // its own columns, still writes in a sheet.
        .sheet(isPresented: Binding(get: { model.compose != nil && !model.isComposePutAway && model.place == .subscriptions },
                                    set: { if !$0, !model.isComposePutAway { model.compose = nil } })) {
            if let compose = Binding(keepingLast: $model.compose) { ComposeSheet(model: model, state: compose) }
        }
        .sheet(isPresented: $model.isShowingShortcuts) {
            ShortcutsView(model: model).background { CancelKey { model.isShowingShortcuts = false } }
        }
        .sheet(isPresented: $model.isNewMeetingOpen) { NewMeetingView(model: model) }
        .sheet(isPresented: $model.isShowingOnboarding) { OnboardingView(model: model).interactiveDismissDisabled() }
        .sheet(item: Binding(get: { model.shownMeetingID.map(ShownMeeting.init) }, set: { model.shownMeetingID = $0?.id })) {
            MeetingDetail(model: model, id: $0.id)
        }
        .sheet(isPresented: $model.isAddingAccount) {
            AccountSetupView(model: model)
        }
        .sheet(isPresented: Binding(get: { model.pendingDeviceLink != nil }, set: { if !$0 { model.pendingDeviceLink = nil } })) {
            DeviceLinkSheet(model: model)
        }
        .sheet(isPresented: $model.isAsking) {
            AskView(model: model)
        }
        .task {
            listFocused = true
            // AppKit gives a new window's first focus to its first text field (search, in the
            // bar above); take it back for the list once the window is up, so keys work there.
            try? await Task.sleep(for: .milliseconds(80))
            listFocused = true
            await model.start()
        }
        #if os(macOS)
        .onAppear { TextEditingKeys.install() }
        #endif
        .onChange(of: model.focusRequest) { _, _ in listFocused = true }
        .onChange(of: model.searchRequest) { _, _ in searchFocused = true }
    }

    /// Single keys act only while the list has focus, never while typing.
    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard listFocused, !model.isPaletteOpen, model.compose == nil || model.isComposePutAway else { return .ignored }
        // With a reply being written, the arrows still move through the list, but no single key
        // acts on mail: a letter meant for the reply must never archive or trash something.
        if model.reply != nil, press.key != .downArrow, press.key != .upArrow { return .ignored }
        if press.modifiers == .command && press.characters.lowercased() == "a" {
            model.selectAll()
            return .handled
        }
        if press.modifiers.contains(.command) || press.modifiers.contains(.control) || press.modifiers.contains(.option) {
            return .ignored
        }
        switch press.key {
        case .downArrow: model.moveSelection(1); return .handled
        case .upArrow: model.moveSelection(-1); return .handled
        case .return where model.layout.opensOverList && model.selectedThread != nil:
            model.isReaderOpen = true
            return .handled
        case .escape:
            if model.layout.opensOverList && model.isReaderOpen { model.isReaderOpen = false; return .handled }
            if !model.selection.isEmpty { model.selection = []; return .handled }
            if !model.searchText.isEmpty { model.searchText = ""; return .handled }
            if !model.quickFilters.isEmpty { model.quickFilters = []; return .handled }
            return .ignored
        default: break
        }
        guard let command = MailCommand.forKey(press.characters, model: model) else { return .ignored }
        if command.needsThread && model.selectedThread == nil { return .handled }
        command.run(model)
        return .handled
    }

    @ViewBuilder
    private var paletteLayer: some View {
        if model.isPaletteOpen {
            ZStack(alignment: .top) {
                Color.black.opacity(0.12)
                    .ignoresSafeArea()
                    .onTapGesture {
                        model.isPaletteOpen = false
                        model.focusRequest += 1
                    }
                CommandPalette(model: model)
                    .padding(.top, 96)
                    .transition(.scale(scale: 0.98, anchor: .top).combined(with: .opacity))
            }
        }
    }

    private func isPresented<T>(_ keyPath: ReferenceWritableKeyPath<MailModel, T?>) -> Binding<Bool> {
        Binding(get: { model[keyPath: keyPath] != nil }, set: { if !$0 { model[keyPath: keyPath] = nil } })
    }
}

extension Look {
    /// Settings and the system's accessibility options, applied before anything draws.
    /// Returns a key that changes whenever the look does, to redraw the whole window.
    @MainActor
    static func apply(_ model: MailModel, systemContrast: ColorSchemeContrast, systemReduceMotion: Bool,
                      systemReduceTransparency: Bool = false) -> String {
        colorBlindSafe = model.colorBlindSafe
        highContrast = model.increaseContrast || systemContrast == .increased
        reduceMotion = model.reduceMotion || systemReduceMotion
        underlineLinks = model.underlineLinks
        darkensMail = model.darkensMail
        theme = model.appearance
        LabelColors.chosen = model.labelColors
        reduceTransparency = systemReduceTransparency || ProcessInfo.processInfo.arguments.contains("-reduce-transparency")
        return key
    }
}

extension View {
    /// Floating bars: Liquid Glass on iPhone and iPad, a solid capsule on the Mac.
    @ViewBuilder
    func noticeSurface() -> some View {
        #if os(iOS)
        if #available(iOS 26, *) {
            self.frame(minHeight: 44).glassEffect(.regular, in: Capsule())
        } else {
            self.frame(minHeight: 44).background(.regularMaterial, in: Capsule())
        }
        #else
        self.background(Paper.popover, in: Capsule())
            .overlay(Capsule().strokeBorder(Line.edge))
            .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
        #endif
    }
}

enum MailLayout {
    /// The shared height of the sidebar's top row, the list header and the reader toolbar.
    static let topBand: CGFloat = 52
    static let railWidth: CGFloat = 56
    /// Room the window's close, minimise and zoom buttons take at the top bar's left, past its padding.
    static let windowButtonsWidth: CGFloat = 64
}

/// How long until a message goes out: a thin ring that fills, full the moment it sends.
private struct SendRing: View {
    let countdown: ClosedRange<Date>

    var body: some View {
        TimelineView(.animation) { context in
            let total = countdown.upperBound.timeIntervalSince(countdown.lowerBound)
            let progress = total > 0 ? min(1, max(0, context.date.timeIntervalSince(countdown.lowerBound) / total)) : 1
            ZStack {
                Circle().stroke(Ink.primary.opacity(0.14), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Ink.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 15, height: 15)
        }
        .accessibilityHidden(true)
    }
}

/// "Conversation marked done · Undo Z", and errors, at the bottom of the window.
struct NoticeBar: View {
    @Bindable var model: MailModel

    var body: some View {
        ZStack {
            if let notice = model.notice {
                HStack(spacing: Space.m) {
                    if notice.isError {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(Status.danger)
                    }
                    if let countdown = notice.countdown {
                        SendRing(countdown: countdown)
                    }
                    Text(notice.text)
                        .font(TypeScale.row)
                        .foregroundStyle(Ink.primary)
                        .lineLimit(2)
                    if notice.canUndo {
                        Button { model.undo() } label: {
                            HStack(spacing: 6) {
                                Text("Undo").font(TypeScale.rowStrong)
                                #if os(macOS)
                                KeyCap("Z")
                                #endif
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Ink.primary)
                    }
                }
                .padding(.horizontal, Space.l)
                .frame(minHeight: 38)
                .noticeSurface()
                .frame(maxWidth: 520)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: notice.id) {
                    // A message waiting to go keeps its notice (and Undo) until it's sent.
                    let waits = notice.countdown.map { $0.upperBound.timeIntervalSinceNow + 1 } ?? 0
                    try? await Task.sleep(for: .seconds(max(notice.isError ? 8 : 5, waits)))
                    if model.notice?.id == notice.id { model.notice = nil }
                }
            }
        }
        .animation(Motion.present, value: model.notice)
    }
}

/// The conversation list and the reader beside it, with the edge between them to drag.
private struct ListAndReader: View {
    @Bindable var model: MailModel
    var listFocused: FocusState<Bool>.Binding
    var searchFocused: FocusState<Bool>.Binding
    @State private var listWidth: CGFloat = 380
    @State private var dragStartWidth: CGFloat?
    /// The reader's width, and the width it keeps while the edge is being dragged: an HTML mail
    /// laid out again on every step is what made dragging stutter, so it reflows once, at the end.
    @State private var readerWidth: CGFloat = 0
    @State private var frozenReaderWidth: CGFloat?
    /// The width of the list, reader and Next up together.
    @State private var panelWidth: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            if model.place == .subscriptions {
                // Newsletters in the list column; the chosen one, or one of its emails, beside it.
                #if os(macOS)
                SubscriptionsColumns(model: model, listWidth: listWidth)
                #endif
            } else if model.place == .calendar {
                CalendarPage(model: model)
            } else if model.layout.opensOverList {
                // Wide list: the list fills the panel; a conversation opens over it.
                if let compose = writing {
                    ComposeSheet(model: model, state: compose, inPane: true)
                } else if model.isReaderOpen && model.selectedThread != nil {
                    ReaderView(model: model)
                        .focusable()
                        .focused(listFocused)
                        .focusEffectDisabled()
                } else {
                    ThreadListView(model: model, searchFocus: searchFocused)
                        .focusable()
                        .focused(listFocused)
                        .focusEffectDisabled()
                }
            } else {
                ThreadListView(model: model, searchFocus: searchFocused)
                    .frame(width: listWidth)
                    .focusable()
                    .focused(listFocused)
                    .focusEffectDisabled()
                resizeHandle
                Group {
                    // A new message takes the reading pane: room to write, the list still beside it.
                    if let compose = writing {
                        ComposeSheet(model: model, state: compose, inPane: true)
                    } else {
                        ReaderView(model: model)
                    }
                }
                    .frame(width: frozenReaderWidth, alignment: .leading)
                    // minWidth 0: the area may get narrower than the frozen email, which is
                    // then clipped, instead of pushing the panel wider than the window.
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .clipped()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                        if frozenReaderWidth == nil { readerWidth = width }
                    }
                #if os(macOS)
                if showsNextUp {
                    Rectangle().fill(Line.hairline).frame(width: 1)
                    NextUpColumn(model: model)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                #endif
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { panelWidth = $0 }
        .onChange(of: showsNextUp, initial: true) { _, shown in model.isNextUpOnScreen = shown }
    }

    /// The new message being written, while it isn't put away.
    private var writing: Binding<ComposeState>? {
        guard model.compose != nil, !model.isComposePutAway else { return nil }
        return Binding(keepingLast: Binding(get: { model.compose }, set: { model.compose = $0 }))
    }

    /// Next up shows beside the reader when it's on, the layout has a reader beside the list,
    /// and there's room for all three.
    private var showsNextUp: Bool {
        MailModel.nextUpAvailable && model.showsNextUp && model.layout == .panels && model.place != .subscriptions
            && panelWidth >= NextUpColumn.minimumPanelWidth
    }

    private var resizeHandle: some View {
        Rectangle()
            .fill(Line.hairline)
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    #if os(macOS)
                    .pointerStyle(.columnResize)
                    #endif
                    .gesture(
                        // Measured in the window: the handle moves with the drag, so measuring
                        // against itself made the width jitter back and forth.
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = dragStartWidth ?? listWidth
                                if dragStartWidth == nil, readerWidth > 0 { frozenReaderWidth = readerWidth }
                                dragStartWidth = start
                                listWidth = min(max(start + value.translation.width, 320), 720)
                            }
                            .onEnded { _ in
                                dragStartWidth = nil
                                frozenReaderWidth = nil
                            }
                    )
            }
    }
}
