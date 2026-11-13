#if os(iOS)
import MailCore
import SwiftUI

/// Margin on iPhone and iPad: mailboxes, the conversation list and the open conversation.
/// On iPad they sit side by side; on iPhone they fold into one stack that opens on the inbox.
public struct TouchMailView: View {
    @Bindable var model: MailModel
    @State private var column: NavigationSplitViewColumn = .content
    @State private var isShowingSettings = false
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var barsOnSide = false
    /// The window's width. Under `twoColumnWidth` (an unfolded iPhone Duo, iPad in a narrow
    /// split) three columns don't fit, so the mailboxes step behind their button and the list
    /// and the conversation share the screen, the way a book opens.
    @State private var width: CGFloat = 1024
    @State private var visibility: NavigationSplitViewVisibility = .automatic
    static let twoColumnWidth: CGFloat = 900

    public init(model: MailModel) {
        self.model = model
    }

    /// Shows or hides the mailboxes column.
    private var mailboxesButton: some View {
        Button {
            withAnimation(Motion.present) { visibility = visibility == .all ? .doubleColumn : .all }
        } label: {
            Label(visibility == .all ? "Hide Mailboxes" : "Show Mailboxes", systemImage: "sidebar.left")
        }
    }

    public var body: some View {
        let lookKey = Look.apply(model, systemContrast: systemContrast, systemReduceMotion: systemReduceMotion,
                                 systemReduceTransparency: systemReduceTransparency)
        let narrow = width < Self.twoColumnWidth
        NavigationSplitView(columnVisibility: $visibility, preferredCompactColumn: $column) {
            TouchMailboxes(model: model, isShowingSettings: $isShowingSettings, isStacked: sizeClass == .compact)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 320)
                .toolbar(removing: .sidebarToggle)
                .toolbar {
                    if sizeClass == .regular {
                        ToolbarItem(placement: .topBarTrailing) { mailboxesButton }
                    }
                }
        } content: {
            TouchThreadList(model: model)
                // Narrow: the list keeps about two fifths, the conversation the rest.
                .navigationSplitViewColumnWidth(min: narrow ? 250 : 340, ideal: narrow ? max(250, width * 0.42) : 400, max: 480)
                // Margin's own button: the system's doesn't bring the mailboxes back reliably
                // once the columns were picked for the window's width (an unfolded iPhone Duo).
                .toolbar(removing: .sidebarToggle)
                .toolbar {
                    if sizeClass == .regular && visibility != .all {
                        ToolbarItem(placement: .topBarLeading) { mailboxesButton }
                    }
                }
        } detail: {
            TouchConversation(model: model)
        }
        .tint(Ink.primary)
        .signsInAgain(model: model, account: $model.signingInAgain)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { newWidth in
            let wasNarrow = width < Self.twoColumnWidth
            width = newWidth
            let isNarrow = newWidth < Self.twoColumnWidth
            // Unfolding or resizing picks the columns: all three when there's room, otherwise the
            // list and the conversation, with the mailboxes a tap away.
            if isNarrow != wasNarrow || visibility == .automatic {
                visibility = isNarrow ? .doubleColumn : .all
            }
        }
        // Colours are read from the tokens, so redraw everything when the look changes.
        .id(lookKey)
        .environment(\.mailAccent, Palette.account(model.accentIndex))
        .preferredColorScheme(model.appearance.colorScheme)
        // A message put away while looking at other mail waits at the top.
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.isComposePutAway, let state = model.compose {
                PutAwayDraftChip(model: model, state: state, touch: true).padding(.vertical, 6)
            } else if model.isReplyPutAway, let state = model.reply {
                PutAwayDraftChip(model: model, state: state, isReply: true, touch: true).padding(.vertical, 6)
            }
        }
        .animation(Motion.quick, value: model.isComposePutAway || model.isReplyPutAway)
        // Above the bottom toolbar.
        .overlay(alignment: .bottom) { NoticeBar(model: model).padding(.horizontal, Space.l).padding(.bottom, 60) }
        // Writing takes the whole screen: new messages and forwards, and replies.
        .fullScreenCover(isPresented: Binding(get: { model.isWritingNew && !model.isComposePutAway },
                                              set: { if !$0, !model.isComposePutAway { model.compose = nil } })) {
            TouchComposerHost(model: model, isReply: false)
        }
        .fullScreenCover(isPresented: Binding(get: { model.isWritingReply && !model.isReplyPutAway },
                                              set: { if !$0, !model.isReplyPutAway { model.reply = nil } })) {
            TouchComposerHost(model: model, isReply: true)
        }
        .sheet(isPresented: $model.isAddingAccount) { AccountSetupView(model: model) }
        .sheet(isPresented: $model.isNewMeetingOpen) { NewMeetingView(model: model) }
        .fullScreenCover(isPresented: $model.isShowingOnboarding) { OnboardingView(model: model) }
        .sheet(item: Binding(get: { model.shownMeetingID.map(ShownMeeting.init) }, set: { model.shownMeetingID = $0?.id })) {
            MeetingDetail(model: model, id: $0.id)
        }
        .sheet(isPresented: Binding(get: { model.pendingDeviceLink != nil }, set: { if !$0 { model.pendingDeviceLink = nil } })) {
            DeviceLinkSheet(model: model)
        }
        .sheet(isPresented: $model.isAsking) { AskView(model: model) }
        .sheet(isPresented: $model.isAgentPromptOpen) { AgentPromptSheet(model: model) }
        .overlay(alignment: .bottom) { AgentRunCard(model: model).padding(.horizontal, Space.l).padding(.bottom, 64) }
        .animation(Motion.present, value: model.agentRun?.id)
        .sheet(isPresented: $isShowingSettings) { TouchSettingsView(model: model) }
        // Done, Trash, Snooze and Send are felt as well as seen; errors feel different.
        .sensoryFeedback(trigger: model.notice?.id) { _, _ in
            guard let notice = model.notice else { return nil }
            return notice.isError ? .error : .impact(weight: .light)
        }
        // Some screens (the folded iPhone Duo) keep the camera on the side: the system then puts
        // the bar buttons in a column there and the top bar has nothing in it.
        .background {
            GeometryReader { proxy in
                let side = proxy.safeAreaInsets.top < 1 && max(proxy.safeAreaInsets.leading, proxy.safeAreaInsets.trailing) > 40
                Color.clear
                    .onAppear { barsOnSide = side }
                    .onChange(of: side) { _, value in barsOnSide = value }
            }
        }
        .environment(\.barsOnSide, barsOnSide)
        .task {
            model.opensFirstConversation = sizeClass != .compact
            await model.start()
        }
        .onChange(of: sizeClass) { _, size in model.opensFirstConversation = size != .compact }
    }

    private func isPresented<T>(_ keyPath: ReferenceWritableKeyPath<MailModel, T?>) -> Binding<Bool> {
        Binding(get: { model[keyPath: keyPath] != nil }, set: { if !$0 { model[keyPath: keyPath] = nil } })
    }
}
#endif

#if os(iOS)
extension EnvironmentValues {
    /// The bar buttons sit in a column on the side of the screen, not along the top.
    @Entry var barsOnSide = false
}
/// The message being written on iPhone and iPad. The only view that reads its text, so typing
/// redraws the composer and not the mail behind it (see `ReplyEditorHost`).
struct TouchComposerHost: View {
    @Bindable var model: MailModel
    let isReply: Bool

    var body: some View {
        if let state = Binding(keepingLast: isReply ? $model.reply : $model.compose) {
            TouchComposer(model: model, state: state, isReply: isReply)
        }
    }
}
#endif
