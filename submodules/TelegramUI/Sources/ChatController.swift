import Foundation
import UIKit
import Postbox
import SwiftSignalKit
import Display
import AsyncDisplayKit
import TelegramCore
import SafariServices
import MobileCoreServices
import Intents
import LegacyComponents
import TelegramPresentationData
import TelegramUIPreferences
import DeviceAccess
import TextFormat
import TelegramBaseController
import AccountContext
import TelegramStringFormatting
import OverlayStatusController
import DeviceLocationManager
import ShareController
import UrlEscaping
import ContextUI
import ComposePollUI
import AlertUI
import PresentationDataUtils
import UndoUI
import TelegramCallsUI
import TelegramNotices
import GameUI
import ScreenCaptureDetection
import GalleryUI
import OpenInExternalAppUI
import LegacyUI
import InstantPageUI
import LocationUI
import BotPaymentsUI
import DeleteChatPeerActionSheetItem
import HashtagSearchUI
import LegacyMediaPickerUI
import Emoji
import PeerAvatarGalleryUI
import PeerInfoUI
import RaiseToListen
import UrlHandling
import AvatarNode
import AppBundle
import LocalizedPeerData
import PhoneNumberFormat
import SettingsUI
import UrlWhitelist
import TelegramIntents
import TooltipUI
import StatisticsUI
import MediaResources
import GalleryData
import ChatInterfaceState
import InviteLinksUI
import Markdown
import TelegramPermissionsUI
import Speak
import TranslateUI
import UniversalMediaPlayer
import WallpaperBackgroundNode
import ChatListUI
import CalendarMessageScreen
import ReactionSelectionNode
import ReactionListContextMenuContent
import AttachmentUI
import AttachmentTextInputPanelNode
import MediaPickerUI
import ChatPresentationInterfaceState
import Pasteboard
import ChatSendMessageActionUI
import ChatTextLinkEditUI
import WebUI
import PremiumUI
import ImageTransparency
import StickerPackPreviewUI
import TextNodeWithEntities
import EntityKeyboard
import ChatTitleView
import EmojiStatusComponent
import ChatTimerScreen
import MediaPasteboardUI
import ChatListHeaderComponent
import ChatControllerInteraction
import FeaturedStickersScreen
import ChatEntityKeyboardInputNode
import StorageUsageScreen
import AvatarEditorScreen
import ChatScheduleTimeController
import ICloudResources
import StoryContainerScreen
import MoreHeaderButton
import VolumeButtons
import ChatAvatarNavigationNode
import ChatContextQuery
import PeerReportScreen
import PeerSelectionController
import SaveToCameraRoll
import ChatMessageDateAndStatusNode
import ReplyAccessoryPanelNode
import TextSelectionNode
import ChatMessagePollBubbleContentNode
import ChatMessageItem
import ChatMessageItemImpl
import ChatMessageItemView
import ChatMessageItemCommon
import ChatMessageAnimatedStickerItemNode
import ChatMessageBubbleItemNode
import ChatNavigationButton
import WebsiteType
import ChatQrCodeScreen
import PeerInfoScreen
import MediaEditorScreen
import WallpaperGalleryScreen
import WallpaperGridScreen
import VideoMessageCameraScreen
import AudioWaveform

public enum ChatControllerPeekActions {
    case standard
    case remove(() -> Void)
}

public final class ChatControllerOverlayPresentationData {
    public let expandData: (ASDisplayNode?, () -> Void)
    public init(expandData: (ASDisplayNode?, () -> Void)) {
        self.expandData = expandData
    }
}

enum ChatLocationInfoData {
    case peer(Promise<PeerView>)
    case replyThread(Promise<Message?>)
    case feed
}

enum ChatRecordingActivity {
    case voice
    case instantVideo
    case none
}

public enum NavigateToMessageLocation {
    case id(MessageId, NavigateToMessageParams)
    case index(MessageIndex)
    case upperBound(PeerId)
    
    var messageId: MessageId? {
        switch self {
            case let .id(id, _):
                return id
            case let .index(index):
                return index.id
            case .upperBound:
                return nil
        }
    }
    
    var peerId: PeerId {
        switch self {
            case let .id(id, _):
                return id.peerId
            case let .index(index):
                return index.id.peerId
            case let .upperBound(peerId):
                return peerId
        }
    }
}

func isTopmostChatController(_ controller: ChatControllerImpl) -> Bool {
    if let _ = controller.navigationController {
        var hasOther = false
        controller.window?.forEachController({ c in
            if c is ChatControllerImpl && controller !== c {
                hasOther = true
            }
        })
        if hasOther {
            return false
        }
    }
    return true
}

func calculateSlowmodeActiveUntilTimestamp(account: Account, untilTimestamp: Int32?) -> Int32? {
    guard let untilTimestamp = untilTimestamp else {
        return nil
    }
    let timestamp = Int32(Date().timeIntervalSince1970)
    let remainingTime = max(0, untilTimestamp - timestamp)
    if remainingTime == 0 {
        return nil
    } else {
        return untilTimestamp
    }
}

struct ScrolledToMessageId: Equatable {
    struct AllowedReplacementDirections: OptionSet {
        var rawValue: Int32
        
        static let up = AllowedReplacementDirections(rawValue: 1 << 0)
        static let down = AllowedReplacementDirections(rawValue: 1 << 1)
    }
    
    var id: MessageId
    var allowedReplacementDirection: AllowedReplacementDirections
}

public final class ChatControllerImpl: TelegramBaseController, ChatController, GalleryHiddenMediaTarget, UIDropInteractionDelegate {
    var validLayout: ContainerViewLayout?
    
    public weak var parentController: ViewController?

    let currentChatListFilter: Int32?
    let chatNavigationStack: [ChatNavigationStackItem]
    
    public var peekActions: ChatControllerPeekActions = .standard
    var didSetup3dTouch: Bool = false
    
    let context: AccountContext
    public let chatLocation: ChatLocation
    public let subject: ChatControllerSubject?
    var botStart: ChatControllerInitialBotStart?
    var attachBotStart: ChatControllerInitialAttachBotStart?
    var botAppStart: ChatControllerInitialBotAppStart?
    
    let peerDisposable = MetaDisposable()
    let titleDisposable = MetaDisposable()
    var accountPeerDisposable: Disposable?
    let navigationActionDisposable = MetaDisposable()
    var networkStateDisposable: Disposable?
    
    let messageIndexDisposable = MetaDisposable()
    
    let _chatLocationInfoReady = Promise<Bool>()
    var didSetChatLocationInfoReady = false
    let chatLocationInfoData: ChatLocationInfoData
    
    let cachedDataReady = Promise<Bool>()
    var didSetCachedDataReady = false

    let wallpaperReady = Promise<Bool>()
    let presentationReady = Promise<Bool>()
    
    var presentationInterfaceState: ChatPresentationInterfaceState
    let presentationInterfaceStatePromise: ValuePromise<ChatPresentationInterfaceState>
    public var presentationInterfaceStateSignal: Signal<Any, NoError> {
        return self.presentationInterfaceStatePromise.get() |> map { $0 }
    }
    
    public var selectedMessageIds: Set<EngineMessage.Id>? {
        return self.presentationInterfaceState.interfaceState.selectionState?.selectedIds
    }
    
    let chatThemeEmoticonPromise = Promise<String?>()
    let chatWallpaperPromise = Promise<TelegramWallpaper?>()
    
    var chatTitleView: ChatTitleView?
    var leftNavigationButton: ChatNavigationButton?
    var rightNavigationButton: ChatNavigationButton?
    var chatInfoNavigationButton: ChatNavigationButton?
    
    var moreBarButton: MoreHeaderButton
    var moreInfoNavigationButton: ChatNavigationButton?
    
    var peerView: PeerView?
    var threadInfo: EngineMessageHistoryThread.Info?
    
    var historyStateDisposable: Disposable?
    
    let galleryHiddenMesageAndMediaDisposable = MetaDisposable()
    let temporaryHiddenGalleryMediaDisposable = MetaDisposable()

    let chatBackgroundNode: WallpaperBackgroundNode
    private(set) var controllerInteraction: ChatControllerInteraction?
    var interfaceInteraction: ChatPanelInterfaceInteraction?
    
    let messageContextDisposable = MetaDisposable()
    let controllerNavigationDisposable = MetaDisposable()
    let sentMessageEventsDisposable = MetaDisposable()
    let failedMessageEventsDisposable = MetaDisposable()
    let sentPeerMediaMessageEventsDisposable = MetaDisposable()
    weak var currentFailedMessagesAlertController: ViewController?
    let messageActionCallbackDisposable = MetaDisposable()
    let messageActionUrlAuthDisposable = MetaDisposable()
    let editMessageDisposable = MetaDisposable()
    let editMessageErrorsDisposable = MetaDisposable()
    let enqueueMediaMessageDisposable = MetaDisposable()
    var resolvePeerByNameDisposable: MetaDisposable?
    var shareStatusDisposable: MetaDisposable?
    var clearCacheDisposable: MetaDisposable?
    var bankCardDisposable: MetaDisposable?
    var hasActiveGroupCallDisposable: Disposable?
    var sendAsPeersDisposable: Disposable?
    var preloadAttachBotIconsDisposables: DisposableSet?
    var keepMessageCountersSyncrhonizedDisposable: Disposable?
    var saveMediaDisposable: MetaDisposable?
    var giveawayStatusDisposable: MetaDisposable?
    var nameColorDisposable: Disposable?
    
    let editingMessage = ValuePromise<Float?>(nil, ignoreRepeated: true)
    let startingBot = ValuePromise<Bool>(false, ignoreRepeated: true)
    let unblockingPeer = ValuePromise<Bool>(false, ignoreRepeated: true)
    let searching = ValuePromise<Bool>(false, ignoreRepeated: true)
    let searchResult = Promise<(SearchMessagesResult, SearchMessagesState, SearchMessagesLocation)?>()
    let loadingMessage = Promise<ChatLoadingMessageSubject?>(nil)
    let performingInlineSearch = ValuePromise<Bool>(false, ignoreRepeated: true)
    
    var stateServiceTasks: [AnyHashable: Disposable] = [:]
    
    var preloadHistoryPeerId: PeerId?
    let preloadHistoryPeerIdDisposable = MetaDisposable()

    var preloadNextChatPeerId: PeerId?
    let preloadNextChatPeerIdDisposable = MetaDisposable()
    
    var preloadSavedMessagesChatsDisposable: Disposable?
    
    let botCallbackAlertMessage = Promise<String?>(nil)
    var botCallbackAlertMessageDisposable: Disposable?
    
    var selectMessagePollOptionDisposables: DisposableDict<MessageId>?
    var selectPollOptionFeedback: HapticFeedback?
    
    var resolveUrlDisposable: MetaDisposable?
    
    var contextQueryStates: [ChatPresentationInputQueryKind: (ChatPresentationInputQuery, Disposable)] = [:]
    var searchQuerySuggestionState: (ChatPresentationInputQuery?, Disposable)?
    var urlPreviewQueryState: (UrlPreviewState?, Disposable)?
    var editingUrlPreviewQueryState: (UrlPreviewState?, Disposable)?
    var replyMessageState: (EngineMessage.Id, Disposable)?
    var searchState: ChatSearchState?
    
    var shakeFeedback: HapticFeedback?
    
    var recordingModeFeedback: HapticFeedback?
    var recorderFeedback: HapticFeedback?
    var audioRecorderValue: ManagedAudioRecorder?
    var audioRecorder = Promise<ManagedAudioRecorder?>()
    var audioRecorderDisposable: Disposable?
    var audioRecorderStatusDisposable: Disposable?
    
    var videoRecorderValue: VideoMessageCameraScreen?
    var videoRecorder = Promise<VideoMessageCameraScreen?>()
    var videoRecorderDisposable: Disposable?
    
    var recorderDataDisposable = MetaDisposable()
    
    var buttonKeyboardMessageDisposable: Disposable?
    var cachedDataDisposable: Disposable?
    var chatUnreadCountDisposable: Disposable?
    var buttonUnreadCountDisposable: Disposable?
    var chatUnreadMentionCountDisposable: Disposable?
    var peerInputActivitiesDisposable: Disposable?
    
    var peerInputActivitiesPromise = Promise<[(Peer, PeerInputActivity)]>()
    var interactiveEmojiSyncDisposable = MetaDisposable()
    
    var recentlyUsedInlineBotsValue: [Peer] = []
    var recentlyUsedInlineBotsDisposable: Disposable?
    
    var unpinMessageDisposable: MetaDisposable?
        
    let typingActivityPromise = Promise<Bool>(false)
    var inputActivityDisposable: Disposable?
    var recordingActivityValue: ChatRecordingActivity = .none
    let recordingActivityPromise = ValuePromise<ChatRecordingActivity>(.none, ignoreRepeated: true)
    var recordingActivityDisposable: Disposable?
    var acquiredRecordingActivityDisposable: Disposable?
    let choosingStickerActivityPromise = ValuePromise<Bool>(false)
    var choosingStickerActivityDisposable: Disposable?
    
    var searchDisposable: MetaDisposable?
    
    var historyNavigationStack = ChatHistoryNavigationStack()
    
    public let canReadHistory = ValuePromise<Bool>(true, ignoreRepeated: true)
    var reminderActivity: NSUserActivity?
    var isReminderActivityEnabled: Bool = false
    
    var canReadHistoryValue = false
    var canReadHistoryDisposable: Disposable?
    
    var themeEmoticonAndDarkAppearancePreviewPromise = Promise<(String?, Bool?)>((nil, nil))
    var didSetPresentationData = false
    var presentationData: PresentationData
    var presentationDataPromise = Promise<PresentationData>()
    override public var updatedPresentationData: (PresentationData, Signal<PresentationData, NoError>) {
        return (self.presentationData, self.presentationDataPromise.get())
    }
    var presentationDataDisposable: Disposable?
    
    var automaticMediaDownloadSettings: MediaAutoDownloadSettings
    var automaticMediaDownloadSettingsDisposable: Disposable?
    
    var disableStickerAnimationsPromise = ValuePromise<Bool>(false)
    var disableStickerAnimationsValue = false
    var disableStickerAnimations: Bool {
        get {
            return self.disableStickerAnimationsValue
        } set {
            self.disableStickerAnimationsPromise.set(newValue)
        }
    }
    var stickerSettings: ChatInterfaceStickerSettings
    var stickerSettingsDisposable: Disposable?
    
    var applicationInForegroundDisposable: Disposable?
    var applicationInFocusDisposable: Disposable?
    
    let checksTooltipDisposable = MetaDisposable()
    var shouldDisplayChecksTooltip = false
    
    let peerSuggestionsDisposable = MetaDisposable()
    let peerSuggestionsDismissDisposable = MetaDisposable()
    var displayedConvertToGigagroupSuggestion = false
    
    var checkedPeerChatServiceActions = false
    
    var willAppear = false
    var didAppear = false
    var scheduledActivateInput: ChatControllerActivateInput?
    
    var raiseToListen: RaiseToListenManager?
    var voicePlaylistDidEndTimestamp: Double = 0.0

    weak var emojiTooltipController: TooltipController?
    weak var sendingOptionsTooltipController: TooltipController?
    weak var searchResultsTooltipController: TooltipController?
    weak var messageTooltipController: TooltipController?
    weak var videoUnmuteTooltipController: TooltipController?
    var didDisplayVideoUnmuteTooltip = false
    var didDisplayGroupEmojiTip = false
    var didDisplaySendWhenOnlineTip = false
    let displaySendWhenOnlineTipDisposable = MetaDisposable()
    
    weak var silentPostTooltipController: TooltipController?
    weak var mediaRecordingModeTooltipController: TooltipController?
    weak var mediaRestrictedTooltipController: TooltipController?
    var mediaRestrictedTooltipControllerMode = true
    weak var checksTooltipController: TooltipController?
    weak var copyProtectionTooltipController: TooltipController?
    
    var currentMessageTooltipScreens: [(TooltipScreen, ListViewItemNode)] = []
    
    weak var slowmodeTooltipController: ChatSlowmodeHintController?
    
    weak var currentContextController: ContextController?
    
    weak var sendMessageActionsController: ChatSendMessageActionSheetController?
    var searchResultsController: ChatSearchResultsController?

    weak var themeScreen: ChatThemeScreen?
    
    weak var currentPinchController: PinchController?
    weak var currentPinchSourceItemNode: ListViewItemNode?
    
    var screenCaptureManager: ScreenCaptureDetectionManager?
    let chatAdditionalDataDisposable = MetaDisposable()
    
    var reportIrrelvantGeoNoticePromise = Promise<Bool?>()
    var reportIrrelvantGeoNotice: Bool?
    var reportIrrelvantGeoDisposable: Disposable?
    
    var hasScheduledMessages: Bool = false
    
    var volumeButtonsListener: VolumeButtonsListener?
    
    var beginMediaRecordingRequestId: Int = 0
    var lockMediaRecordingRequestId: Int?
    
    var updateSlowmodeStatusDisposable = MetaDisposable()
    var updateSlowmodeStatusTimerValue: Int32?
    
    var isDismissed = false
    
    var focusOnSearchAfterAppearance: (ChatSearchDomain, String)?
    
    let keepPeerInfoScreenDataHotDisposable = MetaDisposable()
    let preloadAvatarDisposable = MetaDisposable()
    
    let peekData: ChatPeekTimeout?
    let peekTimerDisposable = MetaDisposable()
    
    let createVoiceChatDisposable = MetaDisposable()
    
    let selectAddMemberDisposable = MetaDisposable()
    let addMemberDisposable = MetaDisposable()
    let joinChannelDisposable = MetaDisposable()
    
    var shouldDisplayDownButton = false

    var hasEmbeddedTitleContent = false
    var isEmbeddedTitleContentHidden = false
    
    let chatLocationContextHolder: Atomic<ChatLocationContextHolder?>
    
    weak var attachmentController: AttachmentController?
    weak var currentMenuWebAppController: ViewController?
    weak var currentWebAppController: ViewController?
    
    weak var currentImportMessageTooltip: UndoOverlayController?

    public override var customData: Any? {
        return self.chatLocation
    }
    
    override public var customNavigationData: CustomViewControllerNavigationData? {
        get {
            if let peerId = self.chatLocation.peerId {
                return ChatControllerNavigationData(peerId: peerId, threadId: self.chatLocation.threadId)
            } else {
                return nil
            }
        }
    }
    
    override public var interactiveNavivationGestureEdgeWidth: InteractiveTransitionGestureRecognizerEdgeWidth? {
        return .widthMultiplier(factor: 0.35, min: 16.0, max: 200.0)
    }
    
    var scheduledScrollToMessageId: (MessageId, NavigateToMessageParams)?
    
    public var purposefulAction: (() -> Void)?
    var updatedClosedPinnedMessageId: ((MessageId) -> Void)?
    var requestedUnpinAllMessages: ((Int, MessageId) -> Void)?
    
    public var isSelectingMessagesUpdated: ((Bool) -> Void)?
    
    let scrolledToMessageId = ValuePromise<ScrolledToMessageId?>(nil, ignoreRepeated: true)
    var scrolledToMessageIdValue: ScrolledToMessageId? = nil {
        didSet {
            self.scrolledToMessageId.set(self.scrolledToMessageIdValue)
        }
    }
    
    var translationStateDisposable: Disposable?
    var premiumGiftSuggestionDisposable: Disposable?
    
    var nextChannelToReadDisposable: Disposable?
    var offerNextChannelToRead = false
    
    var inviteRequestsContext: PeerInvitationImportersContext?
    var inviteRequestsDisposable = MetaDisposable()
    
    var overlayTitle: String? {
        var title: String?
        if let threadInfo = self.threadInfo {
            title = threadInfo.title
        } else if let peerView = self.peerView {
            if let peer = peerViewMainPeer(peerView) {
                title = EnginePeer(peer).displayTitle(strings: self.presentationData.strings, displayOrder: self.presentationData.nameDisplayOrder)
            }
        }
        return title
    }
    
    var currentSpeechHolder: SpeechSynthesizerHolder?
    
    var powerSavingMonitoringDisposable: Disposable?
    
    var avatarNode: ChatAvatarNavigationNode?
    var storyStats: PeerStoryStats?
    
    var performTextSelectionAction: ((Message?, Bool, NSAttributedString, TextSelectionAction) -> Void)?
    var performOpenURL: ((Message?, String, Promise<Bool>?) -> Void)?
    
    public init(context: AccountContext, chatLocation: ChatLocation, chatLocationContextHolder: Atomic<ChatLocationContextHolder?> = Atomic<ChatLocationContextHolder?>(value: nil), subject: ChatControllerSubject? = nil, botStart: ChatControllerInitialBotStart? = nil, attachBotStart: ChatControllerInitialAttachBotStart? = nil, botAppStart: ChatControllerInitialBotAppStart? = nil, mode: ChatControllerPresentationMode = .standard(.default), peekData: ChatPeekTimeout? = nil, peerNearbyData: ChatPeerNearbyData? = nil, chatListFilter: Int32? = nil, chatNavigationStack: [ChatNavigationStackItem] = []) {
        let _ = ChatControllerCount.modify { value in
            return value + 1
        }
        
        self.context = context
        self.chatLocation = chatLocation
        self.chatLocationContextHolder = chatLocationContextHolder
        self.subject = subject
        self.botStart = botStart
        self.attachBotStart = attachBotStart
        self.botAppStart = botAppStart
        self.peekData = peekData
        self.currentChatListFilter = chatListFilter
        self.chatNavigationStack = chatNavigationStack

        var useSharedAnimationPhase = false
        switch mode {
        case .standard(.default):
            useSharedAnimationPhase = true
        default:
            break
        }
        self.chatBackgroundNode = createWallpaperBackgroundNode(context: context, forChatDisplay: true, useSharedAnimationPhase: useSharedAnimationPhase)
        self.wallpaperReady.set(self.chatBackgroundNode.isReady)
        
        var locationBroadcastPanelSource: LocationBroadcastPanelSource
        var groupCallPanelSource: GroupCallPanelSource
        
        switch chatLocation {
        case let .peer(peerId):
            locationBroadcastPanelSource = .peer(peerId)
            switch subject {
            case .message, .none:
                groupCallPanelSource = .peer(peerId)
            default:
                groupCallPanelSource = .none
            }
            self.chatLocationInfoData = .peer(Promise())
        case let .replyThread(replyThreadMessage):
            locationBroadcastPanelSource = .none
            groupCallPanelSource = .none
            let promise = Promise<Message?>()
            if let effectiveMessageId = replyThreadMessage.effectiveMessageId {
                promise.set(context.engine.data.subscribe(TelegramEngine.EngineData.Item.Messages.Message(id: effectiveMessageId))
                            |> map { message -> Message? in
                    guard let message = message else {
                        return nil
                    }
                    return message._asMessage()
                })
            } else {
                promise.set(.single(nil))
            }
            self.chatLocationInfoData = .replyThread(promise)
        case .feed:
            locationBroadcastPanelSource = .none
            groupCallPanelSource = .none
            self.chatLocationInfoData = .feed
        }
        
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        self.automaticMediaDownloadSettings = context.sharedContext.currentAutomaticMediaDownloadSettings
        
        self.stickerSettings = ChatInterfaceStickerSettings()
        
        self.presentationInterfaceState = ChatPresentationInterfaceState(chatWallpaper: self.presentationData.chatWallpaper, theme: self.presentationData.theme, strings: self.presentationData.strings, dateTimeFormat: self.presentationData.dateTimeFormat, nameDisplayOrder: self.presentationData.nameDisplayOrder, limitsConfiguration: context.currentLimitsConfiguration.with { $0 }, fontSize: self.presentationData.chatFontSize, bubbleCorners: self.presentationData.chatBubbleCorners, accountPeerId: context.account.peerId, mode: mode, chatLocation: chatLocation, subject: subject, peerNearbyData: peerNearbyData, greetingData: context.prefetchManager?.preloadedGreetingSticker, pendingUnpinnedAllMessages: false, activeGroupCallInfo: nil, hasActiveGroupCall: false, importState: nil, threadData: nil, isGeneralThreadClosed: nil, replyMessage: nil, accountPeerColor: nil)
        self.presentationInterfaceStatePromise = ValuePromise(self.presentationInterfaceState)
        
        var mediaAccessoryPanelVisibility = MediaAccessoryPanelVisibility.none
        if case .standard = mode {
            mediaAccessoryPanelVisibility = .specific(size: .compact)
        } else {
            locationBroadcastPanelSource = .none
            groupCallPanelSource = .none
        }
        let navigationBarPresentationData: NavigationBarPresentationData?
        switch mode {
        case .inline, .standard(.embedded):
            navigationBarPresentationData = nil
        default:
            navigationBarPresentationData = NavigationBarPresentationData(presentationData: self.presentationData, hideBackground: self.context.sharedContext.immediateExperimentalUISettings.playerEmbedding ? true : false, hideBadge: false)
        }
        
        self.moreBarButton = MoreHeaderButton(color: self.presentationData.theme.rootController.navigationBar.buttonColor)
        self.moreBarButton.isUserInteractionEnabled = true
        
        super.init(context: context, navigationBarPresentationData: navigationBarPresentationData, mediaAccessoryPanelVisibility: mediaAccessoryPanelVisibility, locationBroadcastPanelSource: locationBroadcastPanelSource, groupCallPanelSource: groupCallPanelSource)
        
        self.automaticallyControlPresentationContextLayout = false
        self.blocksBackgroundWhenInOverlay = true
        self.acceptsFocusWhenInOverlay = true
        
        self.navigationItem.backBarButtonItem = UIBarButtonItem(title: self.presentationData.strings.Common_Back, style: .plain, target: nil, action: nil)
        
        self.ready.set(.never())
        
        self.scrollToTop = { [weak self] in
            guard let strongSelf = self, strongSelf.isNodeLoaded else {
                return
            }
            if let attachmentController = strongSelf.attachmentController {
                attachmentController.scrollToTop?()
            } else {
                strongSelf.chatDisplayNode.scrollToTop()
            }
        }
        
        self.attemptNavigation = { [weak self] action in
            guard let strongSelf = self else {
                return true
            }
            
            if let _ = strongSelf.videoRecorderValue {
                return false
            }
            
            strongSelf.chatDisplayNode.messageTransitionNode.dismissMessageReactionContexts()
            
            if strongSelf.presentVoiceMessageDiscardAlert(action: action, performAction: false) {
                return false
            }
            
            if strongSelf.presentRecordedVoiceMessageDiscardAlert(action: action, performAction: false) {
                return false
            }
            
            return true
        }
        
        let controllerInteraction = ChatControllerInteraction(openMessage: { [weak self] message, params in
            guard let strongSelf = self, strongSelf.isNodeLoaded, let message = strongSelf.chatDisplayNode.historyNode.messageInCurrentHistoryView(message.id) else {
                return false
            }
            
            let mode = params.mode
            
            let displayVoiceMessageDiscardAlert: () -> Bool = {
                if strongSelf.presentVoiceMessageDiscardAlert(action: { [weak self] in
                    if let strongSelf = self {
                        Queue.mainQueue().after(0.1, {
                            let _ = strongSelf.controllerInteraction?.openMessage(message, params)
                        })
                    }
                }, performAction: false) {
                    return false
                }
                return true
            }
            
            strongSelf.commitPurposefulAction()
            strongSelf.dismissAllTooltips()
            
            strongSelf.chatDisplayNode.messageTransitionNode.dismissMessageReactionContexts()
            
            var openMessageByAction = false
            var isLocation = false
                        
            for media in message.media {
                if media is TelegramMediaMap {
                    if !displayVoiceMessageDiscardAlert() {
                        return false
                    }
                    isLocation = true
                }
                if let file = media as? TelegramMediaFile {
                    if file.isInstantVideo {
                        if strongSelf.chatDisplayNode.isInputViewFocused {
                            strongSelf.returnInputViewFocus = true
                            strongSelf.chatDisplayNode.dismissInput()
                        }
                    }
                    if file.isMusic || file.isVoice || file.isInstantVideo {
                        if !displayVoiceMessageDiscardAlert() {
                            return false
                        }
                        
                        if (file.isVoice || file.isInstantVideo) && message.minAutoremoveOrClearTimeout == viewOnceTimeout {
                            strongSelf.openViewOnceMediaMessage(message)
                            return false
                        }
                    } else if file.isVideo {
                        if !displayVoiceMessageDiscardAlert() {
                            return false
                        }
                    }
                }
                if let invoice = media as? TelegramMediaInvoice, let extendedMedia = invoice.extendedMedia {
                    switch extendedMedia {
                        case .preview:
                            if displayVoiceMessageDiscardAlert() {
                                strongSelf.controllerInteraction?.openCheckoutOrReceipt(message.id)
                                return true
                            } else {
                                return false
                            }
                        case .full:
                            break
                    }
                } else if media is TelegramMediaGiveaway || media is TelegramMediaGiveawayResults {
                    let progress = params.progress
                    let presentationData = strongSelf.presentationData
                    
                    var signal = strongSelf.context.engine.payments.premiumGiveawayInfo(peerId: message.id.peerId, messageId: message.id)
                    let disposable: MetaDisposable
                    if let current = strongSelf.giveawayStatusDisposable {
                        disposable = current
                    } else {
                        disposable = MetaDisposable()
                        strongSelf.giveawayStatusDisposable = disposable
                    }
                    
                    let progressSignal = Signal<Never, NoError> { [weak self] subscriber in
                        if let progress {
                            progress.set(.single(true))
                            return ActionDisposable {
                                Queue.mainQueue().async() {
                                    progress.set(.single(false))
                                }
                            }
                        } else {
                            let controller = OverlayStatusController(theme: presentationData.theme, type: .loading(cancelled: nil))
                            self?.present(controller, in: .window(.root))
                            return ActionDisposable { [weak controller] in
                                Queue.mainQueue().async() {
                                    controller?.dismiss()
                                }
                            }
                        }
                    }
                    |> runOn(Queue.mainQueue())
                    |> delay(0.25, queue: Queue.mainQueue())
                    let progressDisposable = progressSignal.startStrict()
                    
                    signal = signal
                    |> afterDisposed {
                        Queue.mainQueue().async {
                            progressDisposable.dispose()
                        }
                    }
                    disposable.set((signal
                    |> deliverOnMainQueue).startStrict(next: { [weak self] info in
                        if let strongSelf = self, let info {
                            strongSelf.displayGiveawayStatusInfo(messageId: message.id, giveawayInfo: info)
                        }
                    }))
                    
                    return true
                } else if let action = media as? TelegramMediaAction {
                    if !displayVoiceMessageDiscardAlert() {
                        return false
                    }
                    switch action.action {
                        case .pinnedMessageUpdated, .gameScore, .setSameChatWallpaper, .giveawayResults, .customText:
                            for attribute in message.attributes {
                                if let attribute = attribute as? ReplyMessageAttribute {
                                    strongSelf.navigateToMessage(from: message.id, to: .id(attribute.messageId, NavigateToMessageParams(timestamp: nil, quote: attribute.isQuote ? attribute.quote.flatMap { quote in NavigateToMessageParams.Quote(string: quote.text, offset: quote.offset) } : nil)))
                                    break
                                }
                            }
                        case let .photoUpdated(image):
                            openMessageByAction = image != nil
                        case .groupPhoneCall, .inviteToGroupPhoneCall:
                            if let activeCall = strongSelf.presentationInterfaceState.activeGroupCallInfo?.activeCall {
                                strongSelf.joinGroupCall(peerId: message.id.peerId, invite: nil, activeCall: EngineGroupCallDescription(id: activeCall.id, accessHash: activeCall.accessHash, title: activeCall.title, scheduleTimestamp: activeCall.scheduleTimestamp, subscribedToScheduled: activeCall.subscribedToScheduled, isStream: activeCall.isStream))
                            } else {
                                var canManageGroupCalls = false
                                if let channel = strongSelf.presentationInterfaceState.renderedPeer?.chatMainPeer as? TelegramChannel {
                                    if channel.flags.contains(.isCreator) || channel.hasPermission(.manageCalls) {
                                        canManageGroupCalls = true
                                    }
                                } else if let group = strongSelf.presentationInterfaceState.renderedPeer?.chatMainPeer as? TelegramGroup {
                                    if case .creator = group.role {
                                        canManageGroupCalls = true
                                    } else if case let .admin(rights, _) = group.role {
                                        if rights.rights.contains(.canManageCalls) {
                                            canManageGroupCalls = true
                                        }
                                    }
                                }
                                
                                if canManageGroupCalls {
                                    let text: String
                                    if let channel = strongSelf.presentationInterfaceState.renderedPeer?.chatMainPeer as? TelegramChannel, case .broadcast = channel.info {
                                        text = strongSelf.presentationData.strings.LiveStream_CreateNewVoiceChatText
                                    } else {
                                        text = strongSelf.presentationData.strings.VoiceChat_CreateNewVoiceChatText
                                    }
                                    strongSelf.present(textAlertController(context: strongSelf.context, updatedPresentationData: strongSelf.updatedPresentationData, title: nil, text: text, actions: [TextAlertAction(type: .defaultAction, title: strongSelf.presentationData.strings.VoiceChat_CreateNewVoiceChatStartNow, action: {
                                        if let strongSelf = self {
                                            var dismissStatus: (() -> Void)?
                                            let statusController = OverlayStatusController(theme: strongSelf.presentationData.theme, type: .loading(cancelled: {
                                                dismissStatus?()
                                            }))
                                            dismissStatus = { [weak self, weak statusController] in
                                                self?.createVoiceChatDisposable.set(nil)
                                                statusController?.dismiss()
                                            }
                                            strongSelf.present(statusController, in: .window(.root))
                                            strongSelf.createVoiceChatDisposable.set((strongSelf.context.engine.calls.createGroupCall(peerId: message.id.peerId, title: nil, scheduleDate: nil, isExternalStream: false)
                                            |> deliverOnMainQueue).startStrict(next: { [weak self] info in
                                                guard let strongSelf = self else {
                                                    return
                                                }
                                                strongSelf.joinGroupCall(peerId: message.id.peerId, invite: nil, activeCall: EngineGroupCallDescription(id: info.id, accessHash: info.accessHash, title: info.title, scheduleTimestamp: info.scheduleTimestamp, subscribedToScheduled: info.subscribedToScheduled, isStream: info.isStream))
                                            }, error: { [weak self] error in
                                                dismissStatus?()
                                                
                                                guard let strongSelf = self else {
                                                    return
                                                }
                                            
                                                let text: String
                                                switch error {
                                                case .generic, .scheduledTooLate:
                                                    text = strongSelf.presentationData.strings.Login_UnknownError
                                                case .anonymousNotAllowed:
                                                    if let channel = message.peers[message.id.peerId] as? TelegramChannel, case .broadcast = channel.info {
                                                        text = strongSelf.presentationData.strings.LiveStream_AnonymousDisabledAlertText
                                                    } else {
                                                        text = strongSelf.presentationData.strings.VoiceChat_AnonymousDisabledAlertText
                                                    }
                                                }
                                                strongSelf.present(textAlertController(context: strongSelf.context, updatedPresentationData: strongSelf.updatedPresentationData, title: nil, text: text, actions: [TextAlertAction(type: .defaultAction, title: strongSelf.presentationData.strings.Common_OK, action: {})]), in: .window(.root))
                                            }, completed: {
                                                dismissStatus?()
                                            }))
                                        }
                                    }), TextAlertAction(type: .genericAction, title: strongSelf.presentationData.strings.VoiceChat_CreateNewVoiceChatSchedule, action: {
                                        if let strongSelf = self {
                                            strongSelf.context.scheduleGroupCall(peerId: message.id.peerId)
                                        }
                                    }), TextAlertAction(type: .genericAction, title: strongSelf.presentationData.strings.Common_Cancel, action: {})], actionLayout: .vertical), in: .window(.root))
                                }
                            }
                            return true
                        case .messageAutoremoveTimeoutUpdated:
                            var canSetupAutoremoveTimeout = false
                            
                            if let _ = strongSelf.presentationInterfaceState.renderedPeer?.peer as? TelegramSecretChat {
                                canSetupAutoremoveTimeout = false
                            } else if let group = strongSelf.presentationInterfaceState.renderedPeer?.peer as? TelegramGroup {
                                if !group.hasBannedPermission(.banChangeInfo) {
                                    canSetupAutoremoveTimeout = true
                                }
                            } else if let user = strongSelf.presentationInterfaceState.renderedPeer?.peer as? TelegramUser {
                                if user.id != strongSelf.context.account.peerId && user.botInfo == nil {
                                    canSetupAutoremoveTimeout = true
                                }
                            } else if let channel = strongSelf.presentationInterfaceState.renderedPeer?.peer as? TelegramChannel {
                                if channel.hasPermission(.changeInfo) {
                                    canSetupAutoremoveTimeout = true
                                }
                            }
                            
                            if canSetupAutoremoveTimeout {
                                strongSelf.presentAutoremoveSetup()
                            }
                        case .paymentSent:
                            strongSelf.present(BotReceiptController(context: strongSelf.context, messageId: message.id), in: .window(.root), with: ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
                            /*for attribute in message.attributes {
                                if let attribute = attribute as? ReplyMessageAttribute {
                                    //strongSelf.navigateToMessage(from: message.id, to: .id(attribute.messageId))
                                    break
                                }
                            }*/
                            return true
                        case .setChatTheme:
                            strongSelf.presentThemeSelection()
                            return true
                        case let .setChatWallpaper(wallpaper, _):
                            guard message.effectivelyIncoming(strongSelf.context.account.peerId), let peer = strongSelf.presentationInterfaceState.renderedPeer?.peer else {
                                strongSelf.presentThemeSelection()
                                return true
                            }
                            if peer is TelegramChannel {
                                return true
                            }
                            strongSelf.chatDisplayNode.dismissInput()
                            var options = WallpaperPresentationOptions()
                            var intensity: Int32?
                            if let settings = wallpaper.settings {
                                if settings.blur {
                                    options.insert(.blur)
                                }
                                if settings.motion {
                                    options.insert(.motion)
                                }
                                if case let .file(file) = wallpaper, !file.isPattern {
                                    intensity = settings.intensity
                                }
                            }
                            let wallpaperPreviewController = WallpaperGalleryController(context: strongSelf.context, source: .wallpaper(wallpaper, options, [], intensity, nil, nil), mode: .peer(EnginePeer(peer), true))
                            wallpaperPreviewController.apply = { [weak wallpaperPreviewController] entry, options, _, _, brightness, forBoth in
                                var settings: WallpaperSettings?
                                if case let .wallpaper(wallpaper, _) = entry {
                                    let baseSettings = wallpaper.settings
                                    var intensity: Int32? = baseSettings?.intensity
                                    if case let .file(file) = wallpaper, !file.isPattern {
                                        if let brightness {
                                            intensity = max(0, min(100, Int32(brightness * 100.0)))
                                        }
                                    }
                                    settings = WallpaperSettings(blur: options.contains(.blur), motion: options.contains(.motion), colors: baseSettings?.colors ?? [], intensity: intensity, rotation: baseSettings?.rotation)
                                }
                                let _ = (strongSelf.context.engine.themes.setExistingChatWallpaper(messageId: message.id, settings: settings, forBoth: forBoth)
                                |> deliverOnMainQueue).startStandalone()
                                Queue.mainQueue().after(0.1) {
                                    wallpaperPreviewController?.dismiss()
                                }
                            }
                            strongSelf.push(wallpaperPreviewController)
                            return true
                        case let .giftPremium(_, _, duration, _, _):
                            strongSelf.chatDisplayNode.dismissInput()
                            let fromPeerId: PeerId = message.author?.id == strongSelf.context.account.peerId ? strongSelf.context.account.peerId : message.id.peerId
                            let toPeerId: PeerId = message.author?.id == strongSelf.context.account.peerId ? message.id.peerId : strongSelf.context.account.peerId
                            let controller = PremiumIntroScreen(context: strongSelf.context, source: .gift(from: fromPeerId, to: toPeerId, duration: duration, giftCode: nil))
                            strongSelf.push(controller)
                            return true
                        case let .giftCode(slug, _, _, _, _, _, _, _, _):
                            strongSelf.openResolved(result: .premiumGiftCode(slug: slug), sourceMessageId: message.id, progress: params.progress)
                            return true
                        case let .suggestedProfilePhoto(image):
                            strongSelf.chatDisplayNode.dismissInput()
                            if let image = image {
                                if message.effectivelyIncoming(strongSelf.context.account.peerId) {
                                    if let emojiMarkup = image.emojiMarkup {
                                        let controller = AvatarEditorScreen(context: strongSelf.context, inputData: AvatarEditorScreen.inputData(context: strongSelf.context, isGroup: false), peerType: .user, markup: emojiMarkup)
                                        controller.imageCompletion = { [weak self] image, commit in
                                            if let strongSelf = self {
                                                if let rootController = strongSelf.effectiveNavigationController as? TelegramRootController, let settingsController = rootController.accountSettingsController as? PeerInfoScreenImpl {
                                                    settingsController.updateProfilePhoto(image, mode: .accept)
                                                    commit()
                                                }
                                            }
                                        }
                                        controller.videoCompletion = { [weak self] image, url, adjustments, commit in
                                            if let strongSelf = self {
                                                if let rootController = strongSelf.effectiveNavigationController as? TelegramRootController, let settingsController = rootController.accountSettingsController as? PeerInfoScreenImpl {
                                                    settingsController.updateProfileVideo(image, mode: .accept, asset: AVURLAsset(url: url), adjustments: adjustments)
                                                    commit()
                                                }
                                            }
                                        }
                                        strongSelf.push(controller)
                                    } else {
                                        var selectedNode: (ASDisplayNode, CGRect, () -> (UIView?, UIView?))?
                                        strongSelf.chatDisplayNode.historyNode.forEachItemNode { itemNode in
                                            if let itemNode = itemNode as? ChatMessageItemView {
                                                if let result = itemNode.transitionNode(id: message.id, media: image, adjustRect: false) {
                                                    selectedNode = result
                                                }
                                            }
                                        }
                                        let transitionView = selectedNode?.0.view
                                        
                                        let senderName: String?
                                        if let peer = message.peers[message.id.peerId] {
                                            senderName = EnginePeer(peer).compactDisplayTitle
                                        } else {
                                            senderName = nil
                                        }
                                        
                                        legacyAvatarEditor(context: strongSelf.context, media: .message(message: MessageReference(message), media: image), transitionView: transitionView, senderName: senderName, present: { [weak self] c, a in
                                            self?.present(c, in: .window(.root), with: a)
                                        }, imageCompletion: { [weak self] image in
                                            if let strongSelf = self {
                                                if let rootController = strongSelf.effectiveNavigationController as? TelegramRootController, let settingsController = rootController.accountSettingsController as? PeerInfoScreenImpl {
                                                    settingsController.updateProfilePhoto(image, mode: .accept)
                                                }
                                            }
                                        }, videoCompletion: { [weak self] image, url, adjustments in
                                            if let strongSelf = self {
                                                if let rootController = strongSelf.effectiveNavigationController as? TelegramRootController, let settingsController = rootController.accountSettingsController as? PeerInfoScreenImpl {
                                                    settingsController.updateProfileVideo(image, mode: .accept, asset: AVURLAsset(url: url), adjustments: adjustments)
                                                }
                                            }
                                        })
                                    }
                                } else {
                                    openMessageByAction = true
                                }
                            }
                        case .boostsApplied:
                            strongSelf.controllerInteraction?.openGroupBoostInfo(nil, 0)
                            return true
                        default:
                            break
                    }
                    if !openMessageByAction {
                        return true
                    }
                }
            }
            
            let openChatLocation = strongSelf.chatLocation
            
            return context.sharedContext.openChatMessage(OpenChatMessageParams(context: context, updatedPresentationData: strongSelf.updatedPresentationData, chatLocation: openChatLocation, chatLocationContextHolder: strongSelf.chatLocationContextHolder, message: message, standalone: false, reverseMessageGalleryOrder: false, mode: mode, navigationController: strongSelf.effectiveNavigationController, dismissInput: {
                self?.chatDisplayNode.dismissInput()
            }, present: { c, a in
                self?.present(c, in: .window(.root), with: a, blockInteraction: true)
            }, transitionNode: { messageId, media, adjustRect in
                var selectedNode: (ASDisplayNode, CGRect, () -> (UIView?, UIView?))?
                if let strongSelf = self {
                    strongSelf.chatDisplayNode.historyNode.forEachItemNode { itemNode in
                        if let itemNode = itemNode as? ChatMessageItemView {
                            if let result = itemNode.transitionNode(id: messageId, media: media, adjustRect: adjustRect) {
                                selectedNode = result
                            }
                        }
                    }
                }
                return selectedNode
            }, addToTransitionSurface: { view in
                guard let strongSelf = self else {
                    return
                }
                strongSelf.chatDisplayNode.historyNode.view.superview?.insertSubview(view, aboveSubview: strongSelf.chatDisplayNode.historyNode.view)
            }, openUrl: { url in
                self?.openUrl(url, concealed: false, skipConcealedAlert: isLocation, message: nil)
            }, openPeer: { peer, navigation in
                self?.openPeer(peer: EnginePeer(peer), navigation: navigation, fromMessage: nil)
            }, callPeer: { peerId, isVideo in
                self?.controllerInteraction?.callPeer(peerId, isVideo)
            }, enqueueMessage: { message in
                self?.sendMessages([message])
            }, sendSticker: canSendMessagesToChat(strongSelf.presentationInterfaceState) ? { fileReference, sourceNode, sourceRect in
                return self?.controllerInteraction?.sendSticker(fileReference, false, false, nil, false, sourceNode, sourceRect, nil, []) ?? false
            } : nil, sendEmoji: canSendMessagesToChat(strongSelf.presentationInterfaceState) ? { text, attribute in
                self?.controllerInteraction?.sendEmoji(text, attribute, false)
            } : nil, setupTemporaryHiddenMedia: { signal, centralIndex, galleryMedia in
                if let strongSelf = self {
                    strongSelf.temporaryHiddenGalleryMediaDisposable.set((signal |> deliverOnMainQueue).startStrict(next: { entry in
                        if let strongSelf = self, let controllerInteraction = strongSelf.controllerInteraction {
                            var messageIdAndMedia: [MessageId: [Media]] = [:]
                            
                            if let entry = entry as? InstantPageGalleryEntry, entry.index == centralIndex {
                                messageIdAndMedia[message.id] = [galleryMedia]
                            }
                            
                            controllerInteraction.hiddenMedia = messageIdAndMedia
                            
                            strongSelf.chatDisplayNode.historyNode.forEachItemNode { itemNode in
                                if let itemNode = itemNode as? ChatMessageItemView {
                                    itemNode.updateHiddenMedia()
                                }
                            }
                        }
                    }))
                }
            }, chatAvatarHiddenMedia: { signal, media in
                if let strongSelf = self {
                    strongSelf.temporaryHiddenGalleryMediaDisposable.set((signal |> deliverOnMainQueue).startStrict(next: { messageId in
                        if let strongSelf = self, let controllerInteraction = strongSelf.controllerInteraction {
                            var messageIdAndMedia: [MessageId: [Media]] = [:]
                            
                            if let messageId = messageId {
                                messageIdAndMedia[messageId] = [media]
                            }
                            
                            controllerInteraction.hiddenMedia = messageIdAndMedia
                            
                            strongSelf.chatDisplayNode.historyNode.forEachItemNode { itemNode in
                                if let itemNode = itemNode as? ChatMessageItemView {
                                    itemNode.updateHiddenMedia()
                                }
                            }
                        }
                    }))
                }
            }, actionInteraction: GalleryControllerActionInteraction(
                openUrl: { [weak self] url, concealed in
                    if let strongSelf = self {
                        strongSelf.openUrl(url, concealed: concealed, message: nil)
                    }
                }, openUrlIn: { [weak self] url in
                    if let strongSelf = self {
                        strongSelf.openUrlIn(url)
                    }
                }, openPeerMention: { [weak self] mention in
                    if let strongSelf = self {
                        strongSelf.controllerInteraction?.openPeerMention(mention, nil)
                    }
                }, openPeer: { [weak self] peer in
                    if let strongSelf = self {
                        strongSelf.controllerInteraction?.openPeer(peer, .default, nil, .default)
                    }
                }, openHashtag: { [weak self] peerName, hashtag in
                    if let strongSelf = self {
                        strongSelf.controllerInteraction?.openHashtag(peerName, hashtag)
                    }
                }, openBotCommand: { [weak self] command in
                    if let strongSelf = self {
                        strongSelf.controllerInteraction?.sendBotCommand(nil, command)
                    }
                }, addContact: { [weak self] phoneNumber in
                    if let strongSelf = self {
                        strongSelf.controllerInteraction?.addContact(phoneNumber)
                    }
                }, storeMediaPlaybackState: { [weak self] messageId, timestamp, playbackRate in
                    guard let strongSelf = self else {
                        return
                    }
                    var storedState: MediaPlaybackStoredState?
                    if let timestamp = timestamp {
                        storedState = MediaPlaybackStoredState(timestamp: timestamp, playbackRate: AudioPlaybackRate(playbackRate))
                    }
                    let _ = updateMediaPlaybackStoredStateInteractively(engine: strongSelf.context.engine, messageId: messageId, state: storedState).startStandalone()
                }, editMedia: { [weak self] messageId, snapshots, transitionCompletion in
                    guard let strongSelf = self else {
                        return
                    }
                    
                    let _ = (strongSelf.context.engine.data.get(TelegramEngine.EngineData.Item.Messages.Message(id: messageId))
                    |> deliverOnMainQueue).startStandalone(next: { [weak self] message in
                        guard let strongSelf = self, let message = message else {
                            return
                        }
                        
                        var mediaReference: AnyMediaReference?
                        for media in message.media {
                            if let image = media as? TelegramMediaImage {
                                mediaReference = AnyMediaReference.standalone(media: image)
                            } else if let file = media as? TelegramMediaFile {
                                mediaReference = AnyMediaReference.standalone(media: file)
                            }
                        }
                        
                        if let mediaReference = mediaReference, let peer = message.peers[message.id.peerId] {
                            legacyMediaEditor(context: strongSelf.context, peer: peer, threadTitle: strongSelf.threadInfo?.title, media: mediaReference, mode: .draw, initialCaption: NSAttributedString(), snapshots: snapshots, transitionCompletion: {
                                transitionCompletion()
                            }, getCaptionPanelView: { [weak self] in
                                return self?.getCaptionPanelView()
                            }, sendMessagesWithSignals: { [weak self] signals, _, _ in
                                if let strongSelf = self {
                                    strongSelf.enqueueMediaMessages(signals: signals, silentPosting: false)
                                }
                            }, present: { [weak self] c, a in
                                self?.present(c, in: .window(.root), with: a)
                            })
                        }
                    })
                }, updateCanReadHistory: { [weak self] canReadHistory in
                    self?.canReadHistory.set(canReadHistory)
                }),
                getSourceRect: { [weak self] in
                    guard let strongSelf = self else {
                        return nil
                    }
                    var rect: CGRect?
                    strongSelf.chatDisplayNode.historyNode.forEachVisibleMessageItemNode({ itemNode in
                        if itemNode.item?.message.id == message.id {
                            rect = itemNode.view.convert(itemNode.contentFrame(), to: nil)
                        }
                    })
                    return rect
                }
            ))
        }, openPeer: { [weak self] peer, navigation, fromMessage, source in
            var expandAvatar = false
            if case let .groupParticipant(storyStats, avatarHeaderNode) = source {
                if let storyStats, storyStats.totalCount != 0, let avatarHeaderNode = avatarHeaderNode as? ChatMessageAvatarHeaderNodeImpl {
                    self?.openStories(peerId: peer.id, avatarHeaderNode: avatarHeaderNode, avatarNode: nil)
                    return
                } else {
                    expandAvatar = true
                }
            }
            var fromReactionMessageId: MessageId?
            if case .reaction = source {
                fromReactionMessageId = fromMessage?.id
            }
            self?.openPeer(peer: peer, navigation: navigation, fromMessage: fromMessage, fromReactionMessageId: fromReactionMessageId, expandAvatar: expandAvatar)
        }, openPeerMention: { [weak self] name, progress in
            self?.openPeerMention(name, progress: progress)
        }, openMessageContextMenu: { [weak self] message, selectAll, node, frame, anyRecognizer, location in
            guard let self, self.isNodeLoaded else {
                return
            }
            self.openMessageContextMenu(message: message, selectAll: selectAll, node: node, frame: frame, anyRecognizer: anyRecognizer, location: location)
        }, openMessageReactionContextMenu: { [weak self] message, sourceView, gesture, value in
            guard let self else {
                return
            }
            self.openMessageReactionContextMenu(message: message, sourceView: sourceView, gesture: gesture, value: value)
        }, updateMessageReaction: { [weak self] initialMessage, reaction in
            guard let strongSelf = self else {
                return
            }
            guard let messages = strongSelf.chatDisplayNode.historyNode.messageGroupInCurrentHistoryView(initialMessage.id) else {
                return
            }
            guard let message = messages.first else {
                return
            }
            
            let _ = (peerMessageAllowedReactions(context: strongSelf.context, message: message)
            |> deliverOnMainQueue).startStandalone(next: { allowedReactions in
                guard let strongSelf = self else {
                    return
                }
                
                strongSelf.chatDisplayNode.historyNode.forEachItemNode { itemNode in
                    guard let itemNode = itemNode as? ChatMessageItemView, let item = itemNode.item else {
                        return
                    }
                    guard item.message.id == message.id else {
                        return
                    }
                    
                    if !canAddMessageReactions(message: message) {
                        itemNode.openMessageContextMenu()
                        return
                    }
                    
                    if strongSelf.context.sharedContext.immediateExperimentalUISettings.disableQuickReaction {
                        itemNode.openMessageContextMenu()
                        return
                    }
                    
                    let chosenReaction: MessageReaction.Reaction?
                    
                    switch reaction {
                    case .default:
                        switch item.associatedData.defaultReaction {
                        case .none:
                            chosenReaction = nil
                        case let .builtin(value):
                            chosenReaction = .builtin(value)
                        case let .custom(fileId):
                            chosenReaction = .custom(fileId)
                        }
                    case let .reaction(value):
                        switch value {
                        case let .builtin(value):
                            chosenReaction = .builtin(value)
                        case let .custom(fileId):
                            chosenReaction = .custom(fileId)
                        }
                    }
                    
                    guard let chosenReaction = chosenReaction else {
                        return
                    }
                    
                    var removedReaction: MessageReaction.Reaction?
                    var messageAlreadyHasThisReaction = false
                    
                    let currentReactions = mergedMessageReactions(attributes: message.attributes, isTags: message.areReactionsTags(accountPeerId: context.account.peerId))?.reactions ?? []
                    var updatedReactions: [MessageReaction.Reaction] = currentReactions.filter(\.isSelected).map(\.value)
                    
                    if let index = updatedReactions.firstIndex(where: { $0 == chosenReaction }) {
                        removedReaction = chosenReaction
                        updatedReactions.remove(at: index)
                    } else {
                        updatedReactions.append(chosenReaction)
                        messageAlreadyHasThisReaction = currentReactions.contains(where: { $0.value == chosenReaction })
                    }
                    
                    if removedReaction == nil {
                        guard let allowedReactions = allowedReactions else {
                            itemNode.openMessageContextMenu()
                            return
                        }
                        
                        switch allowedReactions {
                        case let .set(set):
                            if !messageAlreadyHasThisReaction && updatedReactions.contains(where: { !set.contains($0) }) {
                                itemNode.openMessageContextMenu()
                                return
                            }
                        case .all:
                            break
                        }
                    }
                    
                    if removedReaction == nil && !updatedReactions.isEmpty {
                        if strongSelf.selectPollOptionFeedback == nil {
                            strongSelf.selectPollOptionFeedback = HapticFeedback()
                        }
                        strongSelf.selectPollOptionFeedback?.tap()
                        
                        itemNode.awaitingAppliedReaction = (chosenReaction, { [weak itemNode] in
                            guard let strongSelf = self else {
                                return
                            }
                            if let itemNode = itemNode, let item = itemNode.item, let availableReactions = item.associatedData.availableReactions, let targetView = itemNode.targetReactionView(value: chosenReaction) {
                                var reactionItem: ReactionItem?
                                
                                switch chosenReaction {
                                case .builtin:
                                    for reaction in availableReactions.reactions {
                                        guard let centerAnimation = reaction.centerAnimation else {
                                            continue
                                        }
                                        guard let aroundAnimation = reaction.aroundAnimation else {
                                            continue
                                        }
                                        if reaction.value == chosenReaction {
                                            reactionItem = ReactionItem(
                                                reaction: ReactionItem.Reaction(rawValue: reaction.value),
                                                appearAnimation: reaction.appearAnimation,
                                                stillAnimation: reaction.selectAnimation,
                                                listAnimation: centerAnimation,
                                                largeListAnimation: reaction.activateAnimation,
                                                applicationAnimation: aroundAnimation,
                                                largeApplicationAnimation: reaction.effectAnimation,
                                                isCustom: false
                                            )
                                            break
                                        }
                                    }
                                case let .custom(fileId):
                                    if let itemFile = item.message.associatedMedia[MediaId(namespace: Namespaces.Media.CloudFile, id: fileId)] as? TelegramMediaFile {
                                        reactionItem = ReactionItem(
                                            reaction: ReactionItem.Reaction(rawValue: chosenReaction),
                                            appearAnimation: itemFile,
                                            stillAnimation: itemFile,
                                            listAnimation: itemFile,
                                            largeListAnimation: itemFile,
                                            applicationAnimation: nil,
                                            largeApplicationAnimation: nil,
                                            isCustom: true
                                        )
                                    }
                                }
                                
                                if let reactionItem = reactionItem {
                                    let standaloneReactionAnimation = StandaloneReactionAnimation(genericReactionEffect: strongSelf.chatDisplayNode.historyNode.takeGenericReactionEffect())
                                    
                                    strongSelf.chatDisplayNode.messageTransitionNode.addMessageStandaloneReactionAnimation(messageId: item.message.id, standaloneReactionAnimation: standaloneReactionAnimation)
                                    
                                    strongSelf.chatDisplayNode.addSubnode(standaloneReactionAnimation)
                                    standaloneReactionAnimation.frame = strongSelf.chatDisplayNode.bounds
                                    standaloneReactionAnimation.animateReactionSelection(
                                        context: strongSelf.context,
                                        theme: strongSelf.presentationData.theme,
                                        animationCache: strongSelf.controllerInteraction!.presentationContext.animationCache,
                                        reaction: reactionItem,
                                        avatarPeers: [],
                                        playHaptic: false,
                                        isLarge: false,
                                        targetView: targetView,
                                        addStandaloneReactionAnimation: { standaloneReactionAnimation in
                                            guard let strongSelf = self else {
                                                return
                                            }
                                            strongSelf.chatDisplayNode.messageTransitionNode.addMessageStandaloneReactionAnimation(messageId: item.message.id, standaloneReactionAnimation: standaloneReactionAnimation)
                                            standaloneReactionAnimation.frame = strongSelf.chatDisplayNode.bounds
                                            strongSelf.chatDisplayNode.addSubnode(standaloneReactionAnimation)
                                        },
                                        completion: { [weak standaloneReactionAnimation] in
                                            standaloneReactionAnimation?.removeFromSupernode()
                                        }
                                    )
                                }
                            }
                        })
                    } else {
                        strongSelf.chatDisplayNode.messageTransitionNode.dismissMessageReactionContexts(itemNode: itemNode)
                        
                        if let removedReaction = removedReaction, let targetView = itemNode.targetReactionView(value: removedReaction), shouldDisplayInlineDateReactions(message: message, isPremium: strongSelf.presentationInterfaceState.isPremium, forceInline: false) {
                            var hideRemovedReaction: Bool = false
                            if let reactions = mergedMessageReactions(attributes: message.attributes, isTags: message.areReactionsTags(accountPeerId: context.account.peerId)) {
                                for reaction in reactions.reactions {
                                    if reaction.value == removedReaction {
                                        hideRemovedReaction = reaction.count == 1
                                        break
                                    }
                                }
                            }
                            
                            let standaloneDismissAnimation = StandaloneDismissReactionAnimation()
                            standaloneDismissAnimation.frame = strongSelf.chatDisplayNode.bounds
                            strongSelf.chatDisplayNode.addSubnode(standaloneDismissAnimation)
                            standaloneDismissAnimation.animateReactionDismiss(sourceView: targetView, hideNode: hideRemovedReaction, isIncoming: message.effectivelyIncoming(strongSelf.context.account.peerId), completion: { [weak standaloneDismissAnimation] in
                                standaloneDismissAnimation?.removeFromSupernode()
                            })
                        }
                    }
                    
                    let mappedUpdatedReactions = updatedReactions.map { reaction -> UpdateMessageReaction in
                        switch reaction {
                        case let .builtin(value):
                            return .builtin(value)
                        case let .custom(fileId):
                            return .custom(fileId: fileId, file: nil)
                        }
                    }
                    
                    if !strongSelf.presentationInterfaceState.isPremium && mappedUpdatedReactions.count > strongSelf.context.userLimits.maxReactionsPerMessage {
                        let _ = (ApplicationSpecificNotice.incrementMultipleReactionsSuggestion(accountManager: strongSelf.context.sharedContext.accountManager)
                        |> deliverOnMainQueue).startStandalone(next: { [weak self] count in
                            guard let self else {
                                return
                            }
                            if count < 1 {
                                let context = self.context
                                let controller = UndoOverlayController(
                                    presentationData: self.presentationData,
                                    content: .premiumPaywall(title: nil, text: self.presentationData.strings.Chat_Reactions_MultiplePremiumTooltip, customUndoText: nil, timeout: nil, linkAction: nil),
                                    elevatedLayout: false,
                                    action: { [weak self] action in
                                        if case .info = action {
                                            if let self {
                                                let controller = context.sharedContext.makePremiumIntroController(context: context, source: .reactions, forceDark: false, dismissed: nil)
                                                self.push(controller)
                                            }
                                        }
                                        return true
                                    }
                                )
                                self.present(controller, in: .current)
                            }
                        })
                    }
                    
                    let _ = updateMessageReactionsInteractively(account: strongSelf.context.account, messageId: message.id, reactions: mappedUpdatedReactions, isLarge: false, storeAsRecentlyUsed: false).startStandalone()
                }
            })
        }, activateMessagePinch: { [weak self] sourceNode in
            guard let strongSelf = self else {
                return
            }

            var sourceItemNode: ListViewItemNode?
            strongSelf.chatDisplayNode.historyNode.forEachItemNode { itemNode in
                guard let itemNode = itemNode as? ListViewItemNode else {
                    return
                }
                if sourceNode.view.isDescendant(of: itemNode.view) {
                    sourceItemNode = itemNode
                }
            }

            let pinchController = PinchController(sourceNode: sourceNode, getContentAreaInScreenSpace: {
                guard let strongSelf = self else {
                    return CGRect()
                }

                return strongSelf.chatDisplayNode.view.convert(strongSelf.chatDisplayNode.frameForVisibleArea(), to: nil)
            })
            strongSelf.currentPinchController = pinchController
            strongSelf.currentPinchSourceItemNode = sourceItemNode
            strongSelf.window?.presentInGlobalOverlay(pinchController)
        }, openMessageContextActions: { message, node, rect, gesture in
            gesture?.cancel()
        }, navigateToMessage: { [weak self] fromId, id, params in
            guard let self else {
                return
            }
            self.navigateToMessage(fromId: fromId, id: id, params: params)
        }, navigateToMessageStandalone: { [weak self] id in
            self?.navigateToMessage(from: nil, to: .id(id, NavigateToMessageParams(timestamp: nil, quote: nil)), forceInCurrentChat: false)
        }, navigateToThreadMessage: { [weak self] peerId, threadId, messageId in
            if let context = self?.context, let navigationController = self?.effectiveNavigationController {
                let _ = context.sharedContext.navigateToForumThread(context: context, peerId: peerId, threadId: threadId, messageId: messageId, navigationController: navigationController, activateInput: nil, keepStack: .always).startStandalone()
            }
        }, tapMessage: nil, clickThroughMessage: { [weak self] in
            self?.chatDisplayNode.dismissInput()
        }, toggleMessagesSelection: { [weak self] ids, value in
            guard let strongSelf = self, strongSelf.isNodeLoaded else {
                return
            }
            
            if let subject = strongSelf.subject, case .messageOptions = subject, !value {
                let selectedCount = strongSelf.presentationInterfaceState.interfaceState.selectionState?.selectedIds.count ?? 0
                let updatedSelectedCount = selectedCount - ids.count
                if updatedSelectedCount < 1 {
                    return
                }
            }
            
            strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, { $0.updatedInterfaceState { $0.withToggledSelectedMessages(ids, value: value) } })
            if let selectionState = strongSelf.presentationInterfaceState.interfaceState.selectionState {
                let count = selectionState.selectedIds.count
                let text = strongSelf.presentationData.strings.VoiceOver_Chat_MessagesSelected(Int32(count))
                DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.1, execute: {
                    UIAccessibility.post(notification: UIAccessibility.Notification.announcement, argument: text as NSString)
                })
            }
        }, sendCurrentMessage: { [weak self] silentPosting in
            if let strongSelf = self {
                if let _ = strongSelf.presentationInterfaceState.interfaceState.mediaDraftState {
                    strongSelf.sendMediaRecording(silentPosting: silentPosting)
                } else {
                    strongSelf.chatDisplayNode.sendCurrentMessage(silentPosting: silentPosting)
                }
            }
        }, sendMessage: { [weak self] text in
            guard let strongSelf = self, canSendMessagesToChat(strongSelf.presentationInterfaceState) else {
                return
            }
            
            var isScheduledMessages = false
            if case .scheduledMessages = strongSelf.presentationInterfaceState.subject {
                isScheduledMessages = true
            }
            
            guard !isScheduledMessages else {
                strongSelf.present(textAlertController(context: strongSelf.context, updatedPresentationData: strongSelf.updatedPresentationData, title: nil, text: strongSelf.presentationData.strings.ScheduledMessages_BotActionUnavailable, actions: [TextAlertAction(type: .defaultAction, title: strongSelf.presentationData.strings.Common_OK, action: {})]), in: .window(.root))
                return
            }
            strongSelf.chatDisplayNode.setupSendActionOnViewUpdate({
                if let strongSelf = self {
                    strongSelf.chatDisplayNode.collapseInput()
                    
                    strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: false, {
                        $0.updatedInterfaceState { $0.withUpdatedReplyMessageSubject(nil) }
                    })
                }
            }, nil)
            var attributes: [MessageAttribute] = []
            let entities = generateTextEntities(text, enabledTypes: .all)
            if !entities.isEmpty {
                attributes.append(TextEntitiesMessageAttribute(entities: entities))
            }
            
            let peerId = strongSelf.chatLocation.peerId
            if peerId?.namespace != Namespaces.Peer.SecretChat, let interactiveEmojis = strongSelf.chatDisplayNode.interactiveEmojis, interactiveEmojis.emojis.contains(text) {
                strongSelf.sendMessages([.message(text: "", attributes: [], inlineStickers: [:], mediaReference: AnyMediaReference.standalone(media: TelegramMediaDice(emoji: text)), threadId: strongSelf.chatLocation.threadId, replyToMessageId: strongSelf.presentationInterfaceState.interfaceState.replyMessageSubject?.subjectModel, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])])
            } else {
                strongSelf.sendMessages([.message(text: text, attributes: attributes, inlineStickers: [:], mediaReference: nil, threadId: strongSelf.chatLocation.threadId, replyToMessageId: strongSelf.presentationInterfaceState.interfaceState.replyMessageSubject?.subjectModel, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])])
            }
        }, sendSticker: { [weak self] fileReference, silentPosting, schedule, query, clearInput, sourceView, sourceRect, sourceLayer, bubbleUpEmojiOrStickersets in
            guard let strongSelf = self else {
                return false
            }
            
            if let _ = strongSelf.presentationInterfaceState.slowmodeState, strongSelf.presentationInterfaceState.subject != .scheduledMessages {
                strongSelf.interfaceInteraction?.displaySlowmodeTooltip(sourceView, sourceRect)
                return false
            }
            
            var attributes: [MessageAttribute] = []
            if let query = query {
                attributes.append(EmojiSearchQueryMessageAttribute(query: query))
            }

            let correlationId = Int64.random(in: 0 ..< Int64.max)

            var replyPanel: ReplyAccessoryPanelNode?
            if let accessoryPanelNode = strongSelf.chatDisplayNode.accessoryPanelNode as? ReplyAccessoryPanelNode {
                replyPanel = accessoryPanelNode
            }

            var shouldAnimateMessageTransition = strongSelf.chatDisplayNode.shouldAnimateMessageTransition
            if let _ = sourceView.asyncdisplaykit_node as? ChatEmptyNodeStickerContentNode {
                shouldAnimateMessageTransition = true
            }

            strongSelf.chatDisplayNode.setupSendActionOnViewUpdate({
                if let strongSelf = self {
                    strongSelf.chatDisplayNode.collapseInput()
                    
                    strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: false, { current in
                        var current = current
                        current = current.updatedInterfaceState { interfaceState in
                            var interfaceState = interfaceState
                            interfaceState = interfaceState.withUpdatedReplyMessageSubject(nil)
                            if clearInput {
                                interfaceState = interfaceState.withUpdatedComposeInputState(ChatTextInputState(inputText: NSAttributedString()))
                            }
                            return interfaceState
                        }.updatedInputMode { current in
                            if case let .media(mode, maybeExpanded, focused) = current, maybeExpanded != nil {
                                return .media(mode: mode, expanded: nil, focused: focused)
                            }
                            return current
                        }

                        return current
                    })
                }
            }, shouldAnimateMessageTransition ? correlationId : nil)

            if shouldAnimateMessageTransition {
                if let sourceNode = sourceView.asyncdisplaykit_node as? ChatMediaInputStickerGridItemNode {
                    strongSelf.chatDisplayNode.messageTransitionNode.add(correlationId: correlationId, source: .stickerMediaInput(input: .inputPanel(itemNode: sourceNode), replyPanel: replyPanel), initiated: {
                        guard let strongSelf = self else {
                            return
                        }
                        strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: false, { current in
                            var current = current
                            current = current.updatedInputMode { current in
                                if case let .media(mode, maybeExpanded, focused) = current, maybeExpanded != nil {
                                    return .media(mode: mode, expanded: nil, focused: focused)
                                }
                                return current
                            }

                            return current
                        })
                    })
                } else if let sourceNode = sourceView.asyncdisplaykit_node as? HorizontalStickerGridItemNode {
                    strongSelf.chatDisplayNode.messageTransitionNode.add(correlationId: correlationId, source: .stickerMediaInput(input: .mediaPanel(itemNode: sourceNode), replyPanel: replyPanel), initiated: {})
                } else if let sourceNode = sourceView.asyncdisplaykit_node as? ChatEmptyNodeStickerContentNode {
                    strongSelf.chatDisplayNode.messageTransitionNode.add(correlationId: correlationId, source: .stickerMediaInput(input: .emptyPanel(itemNode: sourceNode), replyPanel: nil), initiated: {})
                } else if let sourceLayer = sourceLayer {
                    strongSelf.chatDisplayNode.messageTransitionNode.add(correlationId: correlationId, source: .stickerMediaInput(input: .universal(sourceContainerView: sourceView, sourceRect: sourceRect, sourceLayer: sourceLayer), replyPanel: replyPanel), initiated: {
                        guard let strongSelf = self else {
                            return
                        }
                        strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: false, { current in
                            var current = current
                            current = current.updatedInputMode { current in
                                if case let .media(mode, maybeExpanded, focused) = current, maybeExpanded != nil {
                                    return .media(mode: mode, expanded: nil, focused: focused)
                                }
                                return current
                            }

                            return current
                        })
                    })
                }
            }
            
            let messages: [EnqueueMessage]  = [.message(text: "", attributes: attributes, inlineStickers: [:], mediaReference: fileReference.abstract, threadId: strongSelf.chatLocation.threadId, replyToMessageId: strongSelf.presentationInterfaceState.interfaceState.replyMessageSubject?.subjectModel, replyToStoryId: nil, localGroupingKey: nil, correlationId: correlationId, bubbleUpEmojiOrStickersets: bubbleUpEmojiOrStickersets)]
            if silentPosting {
                let transformedMessages = strongSelf.transformEnqueueMessages(messages, silentPosting: silentPosting)
                strongSelf.sendMessages(transformedMessages)
            } else if schedule {
                strongSelf.presentScheduleTimePicker(completion: { [weak self] scheduleTime in
                    if let strongSelf = self {
                        let transformedMessages = strongSelf.transformEnqueueMessages(messages, silentPosting: false, scheduleTime: scheduleTime)
                        strongSelf.sendMessages(transformedMessages)
                    }
                })
            } else {
                let transformedMessages = strongSelf.transformEnqueueMessages(messages)
                strongSelf.sendMessages(transformedMessages)
            }
            return true
        }, sendEmoji: { [weak self] text, attribute, immediately in
            if let strongSelf = self {
                if immediately {
                    if let file = attribute.file {
                        var bubbleUpEmojiOrStickersets: [ItemCollectionId] = []
                        for attribute in file.attributes {
                            if case let .CustomEmoji(_, _, _, packReference) = attribute {
                                if case let .id(id, _) = packReference {
                                    bubbleUpEmojiOrStickersets.append(ItemCollectionId(namespace: Namespaces.ItemCollection.CloudEmojiPacks, id: id))
                                }
                            }
                        }
                        
                        strongSelf.sendMessages([.message(text: text, attributes: [TextEntitiesMessageAttribute(entities: [MessageTextEntity(range: 0 ..< (text as NSString).length, type: .CustomEmoji(stickerPack: nil, fileId: file.fileId.id))])], inlineStickers: [file.fileId : file], mediaReference: nil, threadId: strongSelf.chatLocation.threadId, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: bubbleUpEmojiOrStickersets)], commit: false)
                    }
                } else {
                    strongSelf.interfaceInteraction?.insertText(NSAttributedString(string: text, attributes: [ChatTextInputAttributes.customEmoji: attribute]))
                    strongSelf.updateChatPresentationInterfaceState(interactive: true, { state in
                        return state.updatedInputMode({ _ in
                            return .text
                        })
                    })
                    
                    let _ = (ApplicationSpecificNotice.getEmojiTooltip(accountManager: strongSelf.context.sharedContext.accountManager)
                    |> deliverOnMainQueue).startStandalone(next: { count in
                        guard let strongSelf = self else {
                            return
                        }
                        if count < 2 {
                            let _ = ApplicationSpecificNotice.incrementEmojiTooltip(accountManager: strongSelf.context.sharedContext.accountManager).startStandalone()
                            
                            Queue.mainQueue().after(0.5, {
                                strongSelf.displayEmojiTooltip()
                            })
                        }
                    })
                }
            }
        }, sendGif: { [weak self] fileReference, sourceView, sourceRect, silentPosting, schedule in
            if let strongSelf = self {
                if let _ = strongSelf.presentationInterfaceState.slowmodeState, strongSelf.presentationInterfaceState.subject != .scheduledMessages {
                    strongSelf.interfaceInteraction?.displaySlowmodeTooltip(sourceView, sourceRect)
                    return false
                }
                
                strongSelf.chatDisplayNode.setupSendActionOnViewUpdate({
                    if let strongSelf = self {
                        strongSelf.chatDisplayNode.collapseInput()
                        
                        strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: false, {
                            $0.updatedInterfaceState { $0.withUpdatedReplyMessageSubject(nil) }.updatedInputMode { current in
                                if case let .media(mode, maybeExpanded, focused) = current, maybeExpanded != nil  {
                                    return .media(mode: mode, expanded: nil, focused: focused)
                                }
                                return current
                            }
                        })
                    }
                }, nil)
                
                var messages = [EnqueueMessage.message(text: "", attributes: [], inlineStickers: [:], mediaReference: fileReference.abstract, threadId: strongSelf.chatLocation.threadId, replyToMessageId: strongSelf.presentationInterfaceState.interfaceState.replyMessageSubject?.subjectModel, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])]
                if silentPosting {
                    messages = strongSelf.transformEnqueueMessages(messages, silentPosting: true)
                    strongSelf.sendMessages(messages)
                } else if schedule {
                    strongSelf.presentScheduleTimePicker(completion: { [weak self] scheduleTime in
                        if let strongSelf = self {
                            let transformedMessages = strongSelf.transformEnqueueMessages(messages, silentPosting: false, scheduleTime: scheduleTime)
                            strongSelf.sendMessages(transformedMessages)
                        }
                    })
                } else {
                    messages = strongSelf.transformEnqueueMessages(messages)
                    strongSelf.sendMessages(messages)
                }
            }
            return true
        }, sendBotContextResultAsGif: { [weak self] collection, result, sourceView, sourceRect, silentPosting, resetTextInputState in
            guard let strongSelf = self else {
                return false
            }
            if case .pinnedMessages = strongSelf.presentationInterfaceState.subject {
                return false
            }
            if let _ = strongSelf.presentationInterfaceState.slowmodeState, strongSelf.presentationInterfaceState.subject != .scheduledMessages {
                strongSelf.interfaceInteraction?.displaySlowmodeTooltip(sourceView, sourceRect)
                return false
            }
            
            strongSelf.enqueueChatContextResult(collection, result, hideVia: true, closeMediaInput: true, silentPosting: silentPosting, resetTextInputState: resetTextInputState)
            
            return true
        }, requestMessageActionCallback: { [weak self] messageId, data, isGame, requiresPassword in
            guard let strongSelf = self else {
                return
            }
            guard strongSelf.presentationInterfaceState.subject != .scheduledMessages else {
                strongSelf.present(textAlertController(context: strongSelf.context, updatedPresentationData: strongSelf.updatedPresentationData, title: nil, text: strongSelf.presentationData.strings.ScheduledMessages_BotActionUnavailable, actions: [TextAlertAction(type: .defaultAction, title: strongSelf.presentationData.strings.Common_OK, action: {})]), in: .window(.root))
                return
            }
            
            let _ = (strongSelf.context.engine.data.get(TelegramEngine.EngineData.Item.Messages.Message(id: messageId))
            |> deliverOnMainQueue).startStandalone(next: { message in
                guard let strongSelf = self, let message = message else {
                    return
                }
                
                strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, {
                    return $0.updatedTitlePanelContext {
                        if !$0.contains(where: {
                            switch $0 {
                                case .requestInProgress:
                                    return true
                                default:
                                    return false
                            }
                        }) {
                            var updatedContexts = $0
                            updatedContexts.append(.requestInProgress)
                            return updatedContexts.sorted()
                        }
                        return $0
                    }
                })
                
                let proceedWithResult: (MessageActionCallbackResult) -> Void = { [weak self] result in
                    guard let strongSelf = self else {
                        return
                    }
                    
                    switch result {
                        case .none:
                            break
                        case let .alert(text):
                            strongSelf.present(textAlertController(context: strongSelf.context, updatedPresentationData: strongSelf.updatedPresentationData, title: nil, text: text, actions: [TextAlertAction(type: .defaultAction, title: strongSelf.presentationData.strings.Common_OK, action: {})]), in: .window(.root))
                        case let .toast(text):
                            let message: Signal<String?, NoError> = .single(text)
                            let noMessage: Signal<String?, NoError> = .single(nil)
                            let delayedNoMessage: Signal<String?, NoError> = noMessage |> delay(1.0, queue: Queue.mainQueue())
                            strongSelf.botCallbackAlertMessage.set(message |> then(delayedNoMessage))
                        case let .url(url):
                            if isGame {
                                let openBot: () -> Void = {
                                    guard let strongSelf = self else {
                                        return
                                    }
                                    
                                    strongSelf.chatDisplayNode.dismissInput()
                                    strongSelf.effectiveNavigationController?.pushViewController(GameController(context: strongSelf.context, url: url, message: message))
                                }

                                var botPeer: TelegramUser?
                                for attribute in message.attributes {
                                    if let attribute = attribute as? InlineBotMessageAttribute {
                                        if let peerId = attribute.peerId {
                                            botPeer = message.peers[peerId] as? TelegramUser
                                        }
                                    }
                                }
                                if botPeer == nil {
                                    if case let .user(peer) = message.author, peer.botInfo != nil {
                                        botPeer = peer
                                    } else if let peer = message.peers[message.id.peerId] as? TelegramUser, peer.botInfo != nil {
                                        botPeer = peer
                                    }
                                }
                                
                                if let botPeer = botPeer {
                                    let _ = (ApplicationSpecificNotice.getBotGameNotice(accountManager: strongSelf.context.sharedContext.accountManager, peerId: botPeer.id)
                                    |> deliverOnMainQueue).startStandalone(next: { value in
                                        guard let strongSelf = self else {
                                            return
                                        }

                                        if value {
                                            openBot()
                                        } else {
                                            strongSelf.present(textAlertController(context: strongSelf.context, updatedPresentationData: strongSelf.updatedPresentationData, title: nil, text: strongSelf.presentationData.strings.Conversation_BotInteractiveUrlAlert(EnginePeer(botPeer).displayTitle(strings: strongSelf.presentationData.strings, displayOrder: strongSelf.presentationData.nameDisplayOrder)).string, actions: [TextAlertAction(type: .genericAction, title: strongSelf.presentationData.strings.Common_Cancel, action: { }), TextAlertAction(type: .defaultAction, title: strongSelf.presentationData.strings.Common_OK, action: {
                                                if let strongSelf = self {
                                                    let _ = ApplicationSpecificNotice.setBotGameNotice(accountManager: strongSelf.context.sharedContext.accountManager, peerId: botPeer.id).startStandalone()
                                                    openBot()
                                                }
                                            })]), in: .window(.root), with: nil)
                                        }
                                    })
                                }
                            } else {
                                strongSelf.openUrl(url, concealed: false)
                            }
                    }
                }
                
                let updateProgress = { [weak self] in
                    Queue.mainQueue().async {
                        if let strongSelf = self {
                            strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, {
                                return $0.updatedTitlePanelContext {
                                    if let index = $0.firstIndex(where: {
                                        switch $0 {
                                            case .requestInProgress:
                                                return true
                                            default:
                                                return false
                                        }
                                    }) {
                                        var updatedContexts = $0
                                        updatedContexts.remove(at: index)
                                        return updatedContexts
                                    }
                                    return $0
                                }
                            })
                        }
                    }
                }
                
                let context = strongSelf.context
                if requiresPassword {
                    strongSelf.messageActionCallbackDisposable.set(((strongSelf.context.engine.messages.requestMessageActionCallbackPasswordCheck(messageId: messageId, isGame: isGame, data: data)
                    |> afterDisposed {
                        updateProgress()
                    })
                    |> deliverOnMainQueue).startStrict(error: { error in
                        let controller = ownershipTransferController(context: context, updatedPresentationData: strongSelf.updatedPresentationData, initialError: error, present: { c, a in
                            strongSelf.present(c, in: .window(.root), with: a)
                        }, commit: { password in
                            return context.engine.messages.requestMessageActionCallback(messageId: messageId, isGame: isGame, password: password, data: data)
                            |> afterDisposed {
                                updateProgress()
                            }
                        }, completion: { result in
                            proceedWithResult(result)
                        })
                        strongSelf.present(controller, in: .window(.root))
                    }))
                } else {
                    strongSelf.messageActionCallbackDisposable.set(((context.engine.messages.requestMessageActionCallback(messageId: messageId, isGame: isGame, password: nil, data: data)
                    |> afterDisposed {
                        updateProgress()
                    })
                    |> deliverOnMainQueue).startStrict(next: { result in
                        proceedWithResult(result)
                    }))
                }
            })
        }, requestMessageActionUrlAuth: { [weak self] defaultUrl, subject in
            if let strongSelf = self {
                guard strongSelf.presentationInterfaceState.subject != .scheduledMessages else {
                    strongSelf.present(textAlertController(context: strongSelf.context, updatedPresentationData: strongSelf.updatedPresentationData, title: nil, text: strongSelf.presentationData.strings.ScheduledMessages_BotActionUnavailable, actions: [TextAlertAction(type: .defaultAction, title: strongSelf.presentationData.strings.Common_OK, action: {})]), in: .window(.root))
                    return
                }
                strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, {
                    return $0.updatedTitlePanelContext {
                        if !$0.contains(where: {
                            switch $0 {
                                case .requestInProgress:
                                    return true
                                default:
                                    return false
                            }
                        }) {
                            var updatedContexts = $0
                            updatedContexts.append(.requestInProgress)
                            return updatedContexts.sorted()
                        }
                        return $0
                    }
                })
                strongSelf.messageActionUrlAuthDisposable.set(((combineLatest(strongSelf.context.account.postbox.loadedPeerWithId(strongSelf.context.account.peerId), strongSelf.context.engine.messages.requestMessageActionUrlAuth(subject: subject) |> afterDisposed {
                    Queue.mainQueue().async {
                        if let strongSelf = self {
                            strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, {
                                return $0.updatedTitlePanelContext {
                                    if let index = $0.firstIndex(where: {
                                        switch $0 {
                                            case .requestInProgress:
                                                return true
                                            default:
                                                return false
                                        }
                                    }) {
                                        var updatedContexts = $0
                                        updatedContexts.remove(at: index)
                                        return updatedContexts
                                    }
                                    return $0
                                }
                            })
                        }
                    }
                })) |> deliverOnMainQueue).startStrict(next: { peer, result in
                    if let strongSelf = self {
                        switch result {
                            case .default:
                                strongSelf.openUrl(defaultUrl, concealed: false, skipUrlAuth: true)
                            case let .request(domain, bot, requestWriteAccess):
                                let controller = chatMessageActionUrlAuthController(context: strongSelf.context, defaultUrl: defaultUrl, domain: domain, bot: bot, requestWriteAccess: requestWriteAccess, displayName: EnginePeer(peer).displayTitle(strings: strongSelf.presentationData.strings, displayOrder: strongSelf.presentationData.nameDisplayOrder), open: { [weak self] authorize, allowWriteAccess in
                                    if let strongSelf = self {
                                        if authorize {
                                            strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, {
                                                return $0.updatedTitlePanelContext {
                                                    if !$0.contains(where: {
                                                        switch $0 {
                                                            case .requestInProgress:
                                                                return true
                                                            default:
                                                                return false
                                                        }
                                                    }) {
                                                        var updatedContexts = $0
                                                        updatedContexts.append(.requestInProgress)
                                                        return updatedContexts.sorted()
                                                    }
                                                    return $0
                                                }
                                            })
                                            
                                            strongSelf.messageActionUrlAuthDisposable.set(((strongSelf.context.engine.messages.acceptMessageActionUrlAuth(subject: subject, allowWriteAccess: allowWriteAccess) |> afterDisposed {
                                                Queue.mainQueue().async {
                                                    if let strongSelf = self {
                                                        strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, {
                                                            return $0.updatedTitlePanelContext {
                                                                if let index = $0.firstIndex(where: {
                                                                    switch $0 {
                                                                        case .requestInProgress:
                                                                            return true
                                                                        default:
                                                                            return false
                                                                    }
                                                                }) {
                                                                    var updatedContexts = $0
                                                                    updatedContexts.remove(at: index)
                                                                    return updatedContexts
                                                                }
                                                                return $0
                                                            }
                                                        })
                                                    }
                                                }
                                            }) |> deliverOnMainQueue).startStrict(next: { [weak self] result in
                                                if let strongSelf = self {
                                                    switch result {
                                                        case let .accepted(url):
                                                            strongSelf.openUrl(url, concealed: false, skipUrlAuth: true)
                                                        default:
                                                            strongSelf.openUrl(defaultUrl, concealed: false, skipUrlAuth: true)
                                                    }
                                                }
                                            }))
                                        } else {
                                            strongSelf.openUrl(defaultUrl, concealed: false, skipUrlAuth: true)
                                        }
                                    }
                                })
                                strongSelf.chatDisplayNode.dismissInput()
                                strongSelf.present(controller, in: .window(.root))
                            case let .accepted(url):
                                strongSelf.openUrl(url, concealed: false, forceExternal: true, skipUrlAuth: true)
                        }
                    }
                }))
            }
        }, activateSwitchInline: { [weak self] peerId, inputString, peerTypes in
            guard let strongSelf = self else {
                return
            }
            guard strongSelf.presentationInterfaceState.subject != .scheduledMessages else {
                strongSelf.present(textAlertController(context: strongSelf.context, updatedPresentationData: strongSelf.updatedPresentationData, title: nil, text: strongSelf.presentationData.strings.ScheduledMessages_BotActionUnavailable, actions: [TextAlertAction(type: .defaultAction, title: strongSelf.presentationData.strings.Common_OK, action: {})]), in: .window(.root))
                return
            }
            if let botStart = strongSelf.botStart, case let .automatic(returnToPeerId, scheduled) = botStart.behavior {
                let _ = (strongSelf.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: returnToPeerId))
                |> deliverOnMainQueue).startStandalone(next: { peer in
                    if let strongSelf = self, let peer = peer {
                        strongSelf.openPeer(peer: peer, navigation: .chat(textInputState: ChatTextInputState(inputText: NSAttributedString(string: inputString)), subject: scheduled ? .scheduledMessages : nil, peekData: nil), fromMessage: nil)
                    }
                })
            } else {
                if let peerId = peerId {
                    let _ = (strongSelf.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
                    |> deliverOnMainQueue).startStandalone(next: { peer in
                        if let strongSelf = self, let peer = peer {
                            strongSelf.openPeer(peer: peer, navigation: .chat(textInputState: ChatTextInputState(inputText: NSAttributedString(string: inputString)), subject: nil, peekData: nil), fromMessage: nil)
                        }
                    })
                } else {
                    strongSelf.openPeer(peer: nil, navigation: .chat(textInputState: ChatTextInputState(inputText: NSAttributedString(string: inputString)), subject: nil, peekData: nil), fromMessage: nil, peerTypes: peerTypes)
                }
            }
        }, openUrl: { [weak self] urlData in
            if let strongSelf = self {
                let url = urlData.url
                let concealed = urlData.concealed
                let message = urlData.message
                let progress = urlData.progress
                let forceExternal = urlData.external ?? false
                
                var skipConcealedAlert = false
                if let author = message?.author, author.isVerified {
                    skipConcealedAlert = true
                }
                
                if let message, let adAttribute = message.attributes.first(where: { $0 is AdMessageAttribute }) as? AdMessageAttribute {
                    strongSelf.chatDisplayNode.historyNode.adMessagesContext?.markAction(opaqueId: adAttribute.opaqueId)
                }
                
                if let performOpenURL = strongSelf.performOpenURL {
                    performOpenURL(message, url, progress)
                } else {
                    strongSelf.openUrl(url, concealed: concealed, forceExternal: forceExternal, skipConcealedAlert: skipConcealedAlert, message: message, allowInlineWebpageResolution: urlData.allowInlineWebpageResolution, progress: progress)
                }
            }
        }, shareCurrentLocation: { [weak self] in
            if let strongSelf = self {
                if case .pinnedMessages = strongSelf.presentationInterfaceState.subject {
                    return
                }
                guard strongSelf.presentationInterfaceState.subject != .scheduledMessages else {
                    strongSelf.present(textAlertController(context: strongSelf.context, updatedPresentationData: strongSelf.updatedPresentationData, title: nil, text: strongSelf.presentationData.strings.ScheduledMessages_BotActionUnavailable, actions: [TextAlertAction(type: .defaultAction, title: strongSelf.presentationData.strings.Common_OK, action: {})]), in: .window(.root))
                    return
                }
                strongSelf.present(textAlertController(context: strongSelf.context, updatedPresentationData: strongSelf.updatedPresentationData, title: strongSelf.presentationData.strings.Conversation_ShareBotLocationConfirmationTitle, text: strongSelf.presentationData.strings.Conversation_ShareBotLocationConfirmation, actions: [TextAlertAction(type: .genericAction, title: strongSelf.presentationData.strings.Common_Cancel, action: {}), TextAlertAction(type: .defaultAction, title: strongSelf.presentationData.strings.Common_OK, action: {
                    if let strongSelf = self, let locationManager = strongSelf.context.sharedContext.locationManager {
                        let _ = (currentLocationManagerCoordinate(manager: locationManager, timeout: 5.0)
                        |> deliverOnMainQueue).startStandalone(next: { coordinate in
                            if let strongSelf = self {
                                if let coordinate = coordinate {
                                    strongSelf.sendMessages([.message(text: "", attributes: [], inlineStickers: [:], mediaReference: .standalone(media: TelegramMediaMap(latitude: coordinate.latitude, longitude: coordinate.longitude, heading: nil, accuracyRadius: nil, geoPlace: nil, venue: nil, liveBroadcastingTimeout: nil, liveProximityNotificationRadius: nil)), threadId: nil, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])])
                                } else {
                                    strongSelf.present(textAlertController(context: strongSelf.context, updatedPresentationData: strongSelf.updatedPresentationData, title: nil, text: strongSelf.presentationData.strings.Login_UnknownError, actions: [TextAlertAction(type: .genericAction, title: strongSelf.presentationData.strings.Common_Cancel, action: {})]), in: .window(.root))
                                }
                            }
                        })
                    }
                })]), in: .window(.root))
            }
        }, shareAccountContact: { [weak self] in
            if let strongSelf = self {
                if case .pinnedMessages = strongSelf.presentationInterfaceState.subject {
                    return
                }
                
                guard strongSelf.presentationInterfaceState.subject != .scheduledMessages else {
                    strongSelf.present(textAlertController(context: strongSelf.context, updatedPresentationData: strongSelf.updatedPresentationData, title: nil, text: strongSelf.presentationData.strings.ScheduledMessages_BotActionUnavailable, actions: [TextAlertAction(type: .defaultAction, title: strongSelf.presentationData.strings.Common_OK, action: {})]), in: .window(.root))
                    return
                }
                strongSelf.present(textAlertController(context: strongSelf.context, updatedPresentationData: strongSelf.updatedPresentationData, title: strongSelf.presentationData.strings.Conversation_ShareBotContactConfirmationTitle, text: strongSelf.presentationData.strings.Conversation_ShareBotContactConfirmation, actions: [TextAlertAction(type: .genericAction, title: strongSelf.presentationData.strings.Common_Cancel, action: {}), TextAlertAction(type: .defaultAction, title: strongSelf.presentationData.strings.Common_OK, action: {
                    if let strongSelf = self {
                        let _ = (strongSelf.context.account.postbox.loadedPeerWithId(strongSelf.context.account.peerId)
                        |> deliverOnMainQueue).startStandalone(next: { peer in
                            if let peer = peer as? TelegramUser, let phone = peer.phone, !phone.isEmpty {
                                strongSelf.sendMessages([.message(text: "", attributes: [], inlineStickers: [:], mediaReference: .standalone(media: TelegramMediaContact(firstName: peer.firstName ?? "", lastName: peer.lastName ?? "", phoneNumber: phone, peerId: peer.id, vCardData: nil)), threadId: strongSelf.chatLocation.threadId, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])])
                            }
                        })
                    }
                })]), in: .window(.root))
            }
        }, sendBotCommand: { [weak self] messageId, command in
            if let strongSelf = self, canSendMessagesToChat(strongSelf.presentationInterfaceState) {
                strongSelf.chatDisplayNode.setupSendActionOnViewUpdate({}, nil)
                var postAsReply = false
                if !command.contains("@") {
                    switch strongSelf.chatLocation {
                        case let .peer(peerId):
                            if (peerId.namespace == Namespaces.Peer.CloudChannel || peerId.namespace == Namespaces.Peer.CloudGroup) {
                                postAsReply = true
                            }
                        case .replyThread:
                            postAsReply = true
                        case .feed:
                            postAsReply = true
                    }
                    
                    if let messageId = messageId, let message = strongSelf.chatDisplayNode.historyNode.messageInCurrentHistoryView(messageId) {
                        if let author = message.author as? TelegramUser, author.botInfo != nil {
                        } else {
                            postAsReply = false
                        }
                    }
                }
                
                strongSelf.chatDisplayNode.setupSendActionOnViewUpdate({
                    if let strongSelf = self {
                        strongSelf.chatDisplayNode.collapseInput()
                        
                        strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: false, {
                            $0.updatedInterfaceState { $0.withUpdatedReplyMessageSubject(nil).withUpdatedComposeInputState(ChatTextInputState(inputText: NSAttributedString(string: ""))).withUpdatedComposeDisableUrlPreviews([]) }
                        })
                    }
                }, nil)
                var attributes: [MessageAttribute] = []
                let entities = generateTextEntities(command, enabledTypes: .all)
                if !entities.isEmpty {
                    attributes.append(TextEntitiesMessageAttribute(entities: entities))
                }
                var replyToMessageId: EngineMessageReplySubject?
                if postAsReply, let messageId {
                    replyToMessageId = EngineMessageReplySubject(messageId: messageId, quote: nil)
                }
                strongSelf.sendMessages([.message(text: command, attributes: attributes, inlineStickers: [:], mediaReference: nil, threadId: strongSelf.chatLocation.threadId, replyToMessageId: replyToMessageId, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])])
            }
        }, openInstantPage: { [weak self] message, associatedData in
            if let strongSelf = self, strongSelf.isNodeLoaded, let navigationController = strongSelf.effectiveNavigationController, let message = strongSelf.chatDisplayNode.historyNode.messageInCurrentHistoryView(message.id) {
                let _ = strongSelf.presentVoiceMessageDiscardAlert(action: {
                    strongSelf.chatDisplayNode.dismissInput()
                    strongSelf.context.sharedContext.openChatInstantPage(context: strongSelf.context, message: message, sourcePeerType: associatedData?.automaticDownloadPeerType, navigationController: navigationController)
                    
                    if case .overlay = strongSelf.presentationInterfaceState.mode {
                        strongSelf.chatDisplayNode.dismissAsOverlay()
                    }
                })
            }
        }, openWallpaper: { [weak self] message in
            if let strongSelf = self, strongSelf.isNodeLoaded, let message = strongSelf.chatDisplayNode.historyNode.messageInCurrentHistoryView(message.id) {
                let _ = strongSelf.presentVoiceMessageDiscardAlert(action: {
                    strongSelf.chatDisplayNode.dismissInput()
                    strongSelf.context.sharedContext.openChatWallpaper(context: strongSelf.context, message: message, present: { [weak self] c, a in
                        self?.push(c)
                    })
                })
            }
        }, openTheme: { [weak self] message in
            if let strongSelf = self, strongSelf.isNodeLoaded, let message = strongSelf.chatDisplayNode.historyNode.messageInCurrentHistoryView(message.id) {
                let _ = strongSelf.presentVoiceMessageDiscardAlert(action: {
                    strongSelf.chatDisplayNode.dismissInput()
                    openChatTheme(context: strongSelf.context, message: message, pushController: { [weak self] c in
                        self?.effectiveNavigationController?.pushViewController(c)
                    }, present: { [weak self] c, a in
                        self?.present(c, in: .window(.root), with: a, blockInteraction: true)
                    })
                })
            }
        }, openHashtag: { [weak self] peerName, hashtag in
            guard let strongSelf = self else {
                return
            }
            strongSelf.openHashtag(hashtag, peerName: peerName)
        }, updateInputState: { [weak self] f in
            if let strongSelf = self {
                strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, {
                    return $0.updatedInterfaceState {
                        let updatedState: ChatTextInputState
                        if canSendMessagesToChat(strongSelf.presentationInterfaceState) {
                            updatedState = f($0.effectiveInputState)
                        } else {
                            updatedState = ChatTextInputState()
                        }
                        return $0.withUpdatedEffectiveInputState(updatedState)
                    }
                })
            }
        }, updateInputMode: { [weak self] f in
            self?.updateChatPresentationInterfaceState(animated: true, interactive: true, {
                return $0.updatedInputMode(f)
            })
        }, openMessageShareMenu: { [weak self] id in
            guard let self else {
                return
            }
            self.openMessageShareMenu(id: id)
        }, presentController: { [weak self] controller, arguments in
            self?.present(controller, in: .window(.root), with: arguments)
        }, presentControllerInCurrent: { [weak self] controller, arguments in
            if controller is UndoOverlayController {
                self?.dismissAllTooltips()
            }
            self?.present(controller, in: .current, with: arguments)
        }, navigationController: { [weak self] in
            return self?.navigationController as? NavigationController
        }, chatControllerNode: { [weak self] in
            return self?.chatDisplayNode
        }, presentGlobalOverlayController: { [weak self] controller, arguments in
            self?.presentInGlobalOverlay(controller, with: arguments)
        }, callPeer: { [weak self] peerId, isVideo in
            if let strongSelf = self {
                let _ = strongSelf.presentVoiceMessageDiscardAlert(action: {
                    strongSelf.commitPurposefulAction()
                    
                    let _ = (context.account.viewTracker.peerView(peerId)
                    |> take(1)
                    |> map { view -> Peer? in
                        return peerViewMainPeer(view)
                    }
                    |> deliverOnMainQueue).startStandalone(next: { peer in
                        guard let peer = peer else {
                            return
                        }
                        
                        if let cachedUserData = strongSelf.peerView?.cachedData as? CachedUserData, cachedUserData.callsPrivate {
                            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                            
                            strongSelf.present(textAlertController(context: strongSelf.context, updatedPresentationData: strongSelf.updatedPresentationData, title: presentationData.strings.Call_ConnectionErrorTitle, text: presentationData.strings.Call_PrivacyErrorMessage(EnginePeer(peer).compactDisplayTitle).string, actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]), in: .window(.root))
                            return
                        }
                        
                        context.requestCall(peerId: peer.id, isVideo: isVideo, completion: {})
                    })
                })
            }
        }, longTap: { [weak self] action, message in
            if let strongSelf = self {
                let presentationData = strongSelf.presentationData
                switch action {
                    case let .url(url):
                        var (cleanUrl, _) = parseUrl(url: url, wasConcealed: false)
                        var canAddToReadingList = true
                        var canOpenIn = availableOpenInOptions(context: strongSelf.context, item: .url(url: url)).count > 1
                        let mailtoString = "mailto:"
                        let telString = "tel:"
                        var openText = strongSelf.presentationData.strings.Conversation_LinkDialogOpen
                        var phoneNumber: String?
                        
                        var isPhoneNumber = false
                        var isEmail = false
                        var hasOpenAction = true
                        
                        if cleanUrl.hasPrefix(mailtoString) {
                            canAddToReadingList = false
                            cleanUrl = String(cleanUrl[cleanUrl.index(cleanUrl.startIndex, offsetBy: mailtoString.distance(from: mailtoString.startIndex, to: mailtoString.endIndex))...])
                            isEmail = true
                        } else if cleanUrl.hasPrefix(telString) {
                            canAddToReadingList = false
                            phoneNumber = String(cleanUrl[cleanUrl.index(cleanUrl.startIndex, offsetBy: telString.distance(from: telString.startIndex, to: telString.endIndex))...])
                            cleanUrl = phoneNumber!
                            openText = strongSelf.presentationData.strings.UserInfo_PhoneCall
                            canOpenIn = false
                            isPhoneNumber = true
                            
                            if cleanUrl.hasPrefix("+888") {
                                hasOpenAction = false
                            }
                        } else if canOpenIn {
                            openText = strongSelf.presentationData.strings.Conversation_FileOpenIn
                        }
                        let actionSheet = ActionSheetController(presentationData: strongSelf.presentationData)
                        
                        var items: [ActionSheetItem] = []
                        items.append(ActionSheetTextItem(title: cleanUrl))
                        if hasOpenAction {
                            items.append(ActionSheetButtonItem(title: openText, color: .accent, action: { [weak actionSheet] in
                                actionSheet?.dismissAnimated()
                                if let strongSelf = self {
                                    if canOpenIn {
                                        strongSelf.openUrlIn(url)
                                    } else {
                                        strongSelf.openUrl(url, concealed: false)
                                    }
                                }
                            }))
                        }
                        if let phoneNumber = phoneNumber {
                            items.append(ActionSheetButtonItem(title: strongSelf.presentationData.strings.Conversation_AddContact, color: .accent, action: { [weak actionSheet] in
                                actionSheet?.dismissAnimated()
                                if let strongSelf = self {
                                    strongSelf.controllerInteraction?.addContact(phoneNumber)
                                }
                            }))
                        }
                        items.append(ActionSheetButtonItem(title: canAddToReadingList ? strongSelf.presentationData.strings.ShareMenu_CopyShareLink : strongSelf.presentationData.strings.Conversation_ContextMenuCopy, color: .accent, action: { [weak actionSheet, weak self] in
                            actionSheet?.dismissAnimated()
                            UIPasteboard.general.string = cleanUrl
                            
                            let content: UndoOverlayContent
                            if isPhoneNumber {
                                content = .copy(text: presentationData.strings.Conversation_PhoneCopied)
                            } else if isEmail {
                                content = .copy(text: presentationData.strings.Conversation_EmailCopied)
                            } else if canAddToReadingList {
                                content = .linkCopied(text: presentationData.strings.Conversation_LinkCopied)
                            } else {
                                content = .copy(text: presentationData.strings.Conversation_TextCopied)
                            }
                            self?.present(UndoOverlayController(presentationData: presentationData, content: content, elevatedLayout: false, animateInAsReplacement: false, action: { _ in return false }), in: .current)
                        }))
                        if canAddToReadingList {
                            items.append(ActionSheetButtonItem(title: strongSelf.presentationData.strings.Conversation_AddToReadingList, color: .accent, action: { [weak actionSheet] in
                                actionSheet?.dismissAnimated()
                                if let link = URL(string: url) {
                                    let _ = try? SSReadingList.default()?.addItem(with: link, title: nil, previewText: nil)
                                }
                            }))
                        }
                        actionSheet.setItemGroups([ActionSheetItemGroup(items: items), ActionSheetItemGroup(items: [
                            ActionSheetButtonItem(title: strongSelf.presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                                actionSheet?.dismissAnimated()
                            })
                        ])])
                        strongSelf.chatDisplayNode.dismissInput()
                        strongSelf.present(actionSheet, in: .window(.root))
                    case let .peerMention(peerId, mention):
                        let actionSheet = ActionSheetController(presentationData: strongSelf.presentationData)
                        var items: [ActionSheetItem] = []
                        if !mention.isEmpty {
                            items.append(ActionSheetTextItem(title: mention))
                        }
                        items.append(ActionSheetButtonItem(title: strongSelf.presentationData.strings.Conversation_LinkDialogOpen, color: .accent, action: { [weak actionSheet] in
                            actionSheet?.dismissAnimated()
                            if let strongSelf = self {
                                let _ = (strongSelf.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
                                |> deliverOnMainQueue).startStandalone(next: { peer in
                                    if let strongSelf = self, let peer = peer {
                                        strongSelf.openPeer(peer: peer, navigation: .chat(textInputState: nil, subject: nil, peekData: nil), fromMessage: nil)
                                    }
                                })
                            }
                        }))
                        if !mention.isEmpty {
                            items.append(ActionSheetButtonItem(title: strongSelf.presentationData.strings.Conversation_LinkDialogCopy, color: .accent, action: { [weak actionSheet] in
                                actionSheet?.dismissAnimated()
                                UIPasteboard.general.string = mention
                                
                                let content: UndoOverlayContent = .copy(text: presentationData.strings.Conversation_TextCopied)
                                self?.present(UndoOverlayController(presentationData: presentationData, content: content, elevatedLayout: false, animateInAsReplacement: false, action: { _ in return false }), in: .current)
                            }))
                        }
                        actionSheet.setItemGroups([ActionSheetItemGroup(items: items), ActionSheetItemGroup(items: [
                            ActionSheetButtonItem(title: strongSelf.presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                                actionSheet?.dismissAnimated()
                            })
                        ])])
                        strongSelf.chatDisplayNode.dismissInput()
                        strongSelf.present(actionSheet, in: .window(.root))
                    case let .mention(mention):
                        let actionSheet = ActionSheetController(presentationData: strongSelf.presentationData)
                        actionSheet.setItemGroups([ActionSheetItemGroup(items: [
                            ActionSheetTextItem(title: mention),
                            ActionSheetButtonItem(title: strongSelf.presentationData.strings.Conversation_LinkDialogOpen, color: .accent, action: { [weak actionSheet] in
                                actionSheet?.dismissAnimated()
                                if let strongSelf = self {
                                    strongSelf.openPeerMention(mention, sourceMessageId: message?.id)
                                }
                            }),
                            ActionSheetButtonItem(title: strongSelf.presentationData.strings.Conversation_LinkDialogCopy, color: .accent, action: { [weak actionSheet] in
                                actionSheet?.dismissAnimated()
                                UIPasteboard.general.string = mention
                                
                                let content: UndoOverlayContent = .copy(text: presentationData.strings.Conversation_UsernameCopied)
                                self?.present(UndoOverlayController(presentationData: presentationData, content: content, elevatedLayout: false, animateInAsReplacement: false, action: { _ in return false }), in: .current)
                            })
                        ]), ActionSheetItemGroup(items: [
                            ActionSheetButtonItem(title: strongSelf.presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                                actionSheet?.dismissAnimated()
                            })
                        ])])
                        strongSelf.chatDisplayNode.dismissInput()
                        strongSelf.present(actionSheet, in: .window(.root))
                    case let .command(command):
                        let actionSheet = ActionSheetController(presentationData: strongSelf.presentationData)
                        var items: [ActionSheetItem] = []
                        items.append(ActionSheetTextItem(title: command))
                        if canSendMessagesToChat(strongSelf.presentationInterfaceState) {
                            items.append(ActionSheetButtonItem(title: strongSelf.presentationData.strings.ShareMenu_Send, color: .accent, action: { [weak actionSheet] in
                                actionSheet?.dismissAnimated()
                                if let strongSelf = self {
                                    strongSelf.sendMessages([.message(text: command, attributes: [], inlineStickers: [:], mediaReference: nil, threadId: strongSelf.chatLocation.threadId, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])])
                                }
                            }))
                        }
                        items.append(ActionSheetButtonItem(title: strongSelf.presentationData.strings.Conversation_LinkDialogCopy, color: .accent, action: { [weak actionSheet] in
                            actionSheet?.dismissAnimated()
                            UIPasteboard.general.string = command
                            
                            let content: UndoOverlayContent = .copy(text: presentationData.strings.Conversation_TextCopied)
                            self?.present(UndoOverlayController(presentationData: presentationData, content: content, elevatedLayout: false, animateInAsReplacement: false, action: { _ in return false }), in: .current)
                        }))
                        actionSheet.setItemGroups([ActionSheetItemGroup(items: items), ActionSheetItemGroup(items: [
                            ActionSheetButtonItem(title: strongSelf.presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                                actionSheet?.dismissAnimated()
                            })
                        ])])
                        strongSelf.chatDisplayNode.dismissInput()
                        strongSelf.present(actionSheet, in: .window(.root))
                    case let .hashtag(hashtag):
                        let actionSheet = ActionSheetController(presentationData: strongSelf.presentationData)
                        actionSheet.setItemGroups([ActionSheetItemGroup(items: [
                            ActionSheetTextItem(title: hashtag),
                            ActionSheetButtonItem(title: strongSelf.presentationData.strings.Conversation_LinkDialogOpen, color: .accent, action: { [weak actionSheet] in
                                actionSheet?.dismissAnimated()
                                if let strongSelf = self {
                                    let peerSignal: Signal<Peer?, NoError>
                                    guard let peerId = strongSelf.chatLocation.peerId else {
                                        return
                                    }
                                    peerSignal = strongSelf.context.account.postbox.loadedPeerWithId(peerId)
                                    |> map(Optional.init)
                                    let _ = (peerSignal
                                    |> deliverOnMainQueue).startStandalone(next: { peer in
                                        if let strongSelf = self {
                                            let searchController = HashtagSearchController(context: strongSelf.context, peer: peer.flatMap(EnginePeer.init), query: hashtag)
                                            strongSelf.effectiveNavigationController?.pushViewController(searchController)
                                        }
                                    })
                                }
                            }),
                            ActionSheetButtonItem(title: strongSelf.presentationData.strings.Conversation_LinkDialogCopy, color: .accent, action: { [weak actionSheet] in
                                actionSheet?.dismissAnimated()
                                UIPasteboard.general.string = hashtag
                                
                                let content: UndoOverlayContent = .copy(text: presentationData.strings.Conversation_HashtagCopied)
                                self?.present(UndoOverlayController(presentationData: presentationData, content: content, elevatedLayout: false, animateInAsReplacement: false, action: { _ in return false }), in: .current)
                            })
                        ]), ActionSheetItemGroup(items: [
                            ActionSheetButtonItem(title: strongSelf.presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                                actionSheet?.dismissAnimated()
                            })
                        ])])
                        strongSelf.chatDisplayNode.dismissInput()
                        strongSelf.present(actionSheet, in: .window(.root))
                    case let .timecode(timecode, text):
                        guard let message = message else {
                            return
                        }
                    
                        let context = strongSelf.context
                        let chatPresentationInterfaceState = strongSelf.presentationInterfaceState
                        let actionSheet = ActionSheetController(presentationData: strongSelf.presentationData)
                        
                        var isCopyLink = false
                        var isForward = false
                        if message.id.namespace == Namespaces.Message.Cloud, let _ = message.peers[message.id.peerId] as? TelegramChannel, !(message.media.first is TelegramMediaAction) {
                            isCopyLink = true
                        } else if let forwardInfo = message.forwardInfo, let _ = forwardInfo.author as? TelegramChannel {
                            isCopyLink = true
                            isForward = true
                        }
                        
                        actionSheet.setItemGroups([ActionSheetItemGroup(items: [
                            ActionSheetTextItem(title: text),
                            ActionSheetButtonItem(title: strongSelf.presentationData.strings.Conversation_LinkDialogOpen, color: .accent, action: { [weak actionSheet] in
                                actionSheet?.dismissAnimated()
                                if let strongSelf = self {
                                    strongSelf.controllerInteraction?.seekToTimecode(message, timecode, true)
                                }
                            }),
                            ActionSheetButtonItem(title: isCopyLink ? strongSelf.presentationData.strings.Conversation_ContextMenuCopyLink : strongSelf.presentationData.strings.Conversation_LinkDialogCopy, color: .accent, action: { [weak actionSheet] in
                                actionSheet?.dismissAnimated()
                                
                                var messageId = message.id
                                var channel = message.peers[message.id.peerId]
                                if isForward, let forwardMessageId = message.forwardInfo?.sourceMessageId, let forwardAuthor = message.forwardInfo?.author as? TelegramChannel {
                                    messageId = forwardMessageId
                                    channel = forwardAuthor
                                }
                                
                                if isCopyLink, let channel = channel as? TelegramChannel {
                                    var threadId: Int64?
                                   
                                    if case let .replyThread(replyThreadMessage) = chatPresentationInterfaceState.chatLocation {
                                        threadId = replyThreadMessage.threadId
                                    }
                                    let _ = (context.engine.messages.exportMessageLink(peerId: messageId.peerId, messageId: messageId, isThread: threadId != nil)
                                    |> map { result -> String? in
                                        return result
                                    }
                                    |> deliverOnMainQueue).startStandalone(next: { link in
                                        if let link = link {
                                            UIPasteboard.general.string = link + "?t=\(Int32(timecode))"
                                            
                                            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                                            
                                            var warnAboutPrivate = false
                                            if case .peer = chatPresentationInterfaceState.chatLocation {
                                                if channel.addressName == nil {
                                                    warnAboutPrivate = true
                                                }
                                            }
                                            Queue.mainQueue().after(0.2, {
                                                let content: UndoOverlayContent
                                                if warnAboutPrivate {
                                                    content = .linkCopied(text: presentationData.strings.Conversation_PrivateMessageLinkCopiedLong)
                                                } else {
                                                    content = .linkCopied(text: presentationData.strings.Conversation_LinkCopied)
                                                }
                                                self?.present(UndoOverlayController(presentationData: presentationData, content: content, elevatedLayout: false, animateInAsReplacement: false, action: { _ in return false }), in: .current)
                                            })
                                        } else {
                                            UIPasteboard.general.string = text
                                            
                                            let content: UndoOverlayContent = .copy(text: presentationData.strings.Conversation_TextCopied)
                                            self?.present(UndoOverlayController(presentationData: presentationData, content: content, elevatedLayout: false, animateInAsReplacement: false, action: { _ in return false }), in: .current)
                                        }
                                    })
                                } else {
                                    UIPasteboard.general.string = text
                                    
                                    let content: UndoOverlayContent = .copy(text: presentationData.strings.Conversation_TextCopied)
                                    self?.present(UndoOverlayController(presentationData: presentationData, content: content, elevatedLayout: false, animateInAsReplacement: false, action: { _ in return false }), in: .current)
                                }
                            })
                            ]), ActionSheetItemGroup(items: [
                                ActionSheetButtonItem(title: strongSelf.presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                                    actionSheet?.dismissAnimated()
                                })
                            ])])
                        strongSelf.chatDisplayNode.dismissInput()
                        strongSelf.present(actionSheet, in: .window(.root))
                    case let .bankCard(number):
                        guard let message = message else {
                            return
                        }
                        
                        var signal = strongSelf.context.engine.payments.getBankCardInfo(cardNumber: number)
                        let disposable: MetaDisposable
                        if let current = strongSelf.bankCardDisposable {
                            disposable = current
                        } else {
                            disposable = MetaDisposable()
                            strongSelf.bankCardDisposable = disposable
                        }
                        
                        var cancelImpl: (() -> Void)?
                        let presentationData = strongSelf.context.sharedContext.currentPresentationData.with { $0 }
                        let progressSignal = Signal<Never, NoError> { subscriber in
                            let controller = OverlayStatusController(theme: presentationData.theme, type: .loading(cancelled: {
                                cancelImpl?()
                            }))
                            strongSelf.present(controller, in: .window(.root), with: ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
                            return ActionDisposable { [weak controller] in
                                Queue.mainQueue().async() {
                                    controller?.dismiss()
                                }
                            }
                        }
                        |> runOn(Queue.mainQueue())
                        |> delay(0.15, queue: Queue.mainQueue())
                        let progressDisposable = progressSignal.startStrict()
                        
                        signal = signal
                        |> afterDisposed {
                            Queue.mainQueue().async {
                                progressDisposable.dispose()
                            }
                        }
                        cancelImpl = {
                            disposable.set(nil)
                        }
                        disposable.set((signal
                        |> deliverOnMainQueue).startStrict(next: { [weak self] info in
                            if let strongSelf = self, let info = info {
                                let actionSheet = ActionSheetController(presentationData: strongSelf.presentationData)
                                var items: [ActionSheetItem] = []
                                items.append(ActionSheetTextItem(title: info.title))
                                for url in info.urls {
                                    items.append(ActionSheetButtonItem(title: url.title, color: .accent, action: { [weak actionSheet] in
                                        actionSheet?.dismissAnimated()
                                        if let strongSelf = self {
                                            strongSelf.controllerInteraction?.openUrl(ChatControllerInteraction.OpenUrl(url: url.url, concealed: false, external: false, message: message))
                                        }
                                    }))
                                }
                                items.append(ActionSheetButtonItem(title: strongSelf.presentationData.strings.Conversation_LinkDialogCopy, color: .accent, action: { [weak actionSheet] in
                                    actionSheet?.dismissAnimated()
                                    UIPasteboard.general.string = number
                                    
                                    let content: UndoOverlayContent = .copy(text: presentationData.strings.Conversation_CardNumberCopied)
                                    self?.present(UndoOverlayController(presentationData: presentationData, content: content, elevatedLayout: false, animateInAsReplacement: false, action: { _ in return false }), in: .current)
                                }))
                                actionSheet.setItemGroups([ActionSheetItemGroup(items: items), ActionSheetItemGroup(items: [
                                    ActionSheetButtonItem(title: strongSelf.presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                                        actionSheet?.dismissAnimated()
                                    })
                                ])])
                                strongSelf.present(actionSheet, in: .window(.root))
                            }
                        }))
                        
                        strongSelf.chatDisplayNode.dismissInput()
                }
            }
        }, openCheckoutOrReceipt: { [weak self] messageId in
            guard let strongSelf = self else {
                return
            }
            strongSelf.commitPurposefulAction()
            
            var isScheduledMessages = false
            if case .scheduledMessages = strongSelf.presentationInterfaceState.subject {
                isScheduledMessages = true
            }
            
            guard !isScheduledMessages else {
                strongSelf.present(textAlertController(context: strongSelf.context, updatedPresentationData: strongSelf.updatedPresentationData, title: nil, text: strongSelf.presentationData.strings.ScheduledMessages_BotActionUnavailable, actions: [TextAlertAction(type: .defaultAction, title: strongSelf.presentationData.strings.Common_OK, action: {})]), in: .window(.root))
                return
            }
            
            let _ = (strongSelf.context.engine.data.get(TelegramEngine.EngineData.Item.Messages.Message(id: messageId))
            |> deliverOnMainQueue).startStandalone(next: { message in
                guard let strongSelf = self, let message = message else {
                    return
                }
                
                for media in message.media {
                    if let invoice = media as? TelegramMediaInvoice {
                        strongSelf.chatDisplayNode.dismissInput()
                        if let receiptMessageId = invoice.receiptMessageId {
                            strongSelf.present(BotReceiptController(context: strongSelf.context, messageId: receiptMessageId), in: .window(.root), with: ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
                        } else {
                            let inputData = Promise<BotCheckoutController.InputData?>()
                            inputData.set(BotCheckoutController.InputData.fetch(context: strongSelf.context, source: .message(message.id))
                            |> map(Optional.init)
                            |> `catch` { _ -> Signal<BotCheckoutController.InputData?, NoError> in
                                return .single(nil)
                            })
                            strongSelf.present(BotCheckoutController(context: strongSelf.context, invoice: invoice, source: .message(messageId), inputData: inputData, completed: { currencyValue, receiptMessageId in
                                guard let strongSelf = self else {
                                    return
                                }
                                strongSelf.present(UndoOverlayController(presentationData: strongSelf.presentationData, content: .paymentSent(currencyValue: currencyValue, itemTitle: invoice.title), elevatedLayout: false, action: { action in
                                    guard let strongSelf = self, let receiptMessageId = receiptMessageId else {
                                        return false
                                    }

                                    if case .info = action {
                                        strongSelf.present(BotReceiptController(context: strongSelf.context, messageId: receiptMessageId), in: .window(.root), with: ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
                                        return true
                                    }
                                    return false
                                }), in: .current)
                            }), in: .window(.root), with: ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
                        }
                    }
                }
            })
        }, openSearch: {
        }, setupReply: { [weak self] messageId in
            self?.interfaceInteraction?.setupReplyMessage(messageId, { _, f in f() })
        }, canSetupReply: { [weak self] message in
            if message.adAttribute != nil {
                return .none
            }
            if !message.flags.contains(.Incoming) {
                if !message.flags.intersection([.Failed, .Sending, .Unsent]).isEmpty {
                    return .none
                }
            }
            if let strongSelf = self {
                if case let .replyThread(replyThreadMessage) = strongSelf.chatLocation, replyThreadMessage.effectiveMessageId == message.id {
                    return .none
                }
                if case let .replyThread(replyThreadMessage) = strongSelf.chatLocation, replyThreadMessage.peerId == strongSelf.context.account.peerId {
                    return .none
                }
                if case .peer = strongSelf.chatLocation, let channel = strongSelf.presentationInterfaceState.renderedPeer?.peer as? TelegramChannel, channel.flags.contains(.isForum) {
                    if message.threadId == nil {
                        return .none
                    }
                }
                
                if canReplyInChat(strongSelf.presentationInterfaceState, accountPeerId: strongSelf.context.account.peerId) {
                    return .reply
                } else if let channel = message.peers[message.id.peerId] as? TelegramChannel, case .broadcast = channel.info {
                }
            }
            return .none
        }, canSendMessages: { [weak self] in
            guard let self else {
                return false
            }
            return canSendMessagesToChat(self.presentationInterfaceState)
        }, navigateToFirstDateMessage: { [weak self] timestamp, alreadyThere in
            guard let strongSelf = self else {
                return
            }
            switch strongSelf.chatLocation {
            case let .peer(peerId):
                if alreadyThere {
                    strongSelf.openCalendarSearch(timestamp: timestamp)
                } else {
                    strongSelf.navigateToMessage(from: nil, to: .index(MessageIndex(id: MessageId(peerId: peerId, namespace: 0, id: 0), timestamp: timestamp - Int32(NSTimeZone.local.secondsFromGMT()))), scrollPosition: .bottom(0.0), rememberInStack: false, animated: true, completion: nil)
                }
            case let .replyThread(replyThreadMessage):
                let peerId = replyThreadMessage.peerId
                strongSelf.navigateToMessage(from: nil, to: .index(MessageIndex(id: MessageId(peerId: peerId, namespace: 0, id: 0), timestamp: timestamp - Int32(NSTimeZone.local.secondsFromGMT()))), scrollPosition: .bottom(0.0), rememberInStack: false, forceInCurrentChat: true, animated: true, completion: nil)
            case .feed:
                break
            }
        }, requestRedeliveryOfFailedMessages: { [weak self] id in
            guard let strongSelf = self else {
                return
            }
            if id.namespace == Namespaces.Message.ScheduledCloud {
                let _ = (strongSelf.context.engine.data.get(TelegramEngine.EngineData.Item.Messages.MessageGroup(id: id))
                |> deliverOnMainQueue).startStandalone(next: { messages in
                    guard let strongSelf = self, let message = messages.filter({ $0.id == id }).first else {
                        return
                    }
                    
                    var actions: [ContextMenuItem] = []
                    actions.append(.action(ContextMenuActionItem(text: strongSelf.presentationData.strings.ScheduledMessages_SendNow, icon: { theme in
                        return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Resend"), color: theme.actionSheet.primaryTextColor)
                    }, action: { [weak self] _, f in
                        if let strongSelf = self {
                            strongSelf.controllerInteraction?.sendScheduledMessagesNow(messages.map { $0.id })
                        }
                        f(.dismissWithoutContent)
                    })))
                    actions.append(.action(ContextMenuActionItem(text: strongSelf.presentationData.strings.ScheduledMessages_EditTime, icon: { theme in
                        return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Schedule"), color: theme.actionSheet.primaryTextColor)
                    }, action: { [weak self] _, f in
                        if let strongSelf = self {
                            strongSelf.controllerInteraction?.editScheduledMessagesTime(messages.map { $0.id })
                        }
                        f(.dismissWithoutContent)
                    })))
                    actions.append(.action(ContextMenuActionItem(text: strongSelf.presentationData.strings.Conversation_ContextMenuDelete, textColor: .destructive, icon: { theme in
                        return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Delete"), color: theme.actionSheet.destructiveActionTextColor)
                    }, action: { [weak self] controller, f in
                        if let strongSelf = self {
                            strongSelf.interfaceInteraction?.deleteMessages(messages.map { $0._asMessage() }, controller, f)
                        }
                    })))
                    
                    strongSelf.chatDisplayNode.messageTransitionNode.dismissMessageReactionContexts()
                    
                    let controller = ContextController(presentationData: strongSelf.presentationData, source: .extracted(ChatMessageContextExtractedContentSource(chatNode: strongSelf.chatDisplayNode, engine: strongSelf.context.engine, message: message._asMessage(), selectAll: true)), items: .single(ContextController.Items(content: .list(actions))), recognizer: nil)
                    strongSelf.currentContextController = controller
                    strongSelf.forEachController({ controller in
                        if let controller = controller as? TooltipScreen {
                            controller.dismiss()
                        }
                        return true
                    })
                    strongSelf.window?.presentInGlobalOverlay(controller)
                })
            } else {
                let _ = (strongSelf.context.engine.messages.failedMessageGroup(id: id)
                |> deliverOnMainQueue).startStandalone(next: { messages in
                    guard let strongSelf = self else {
                        return
                    }
                    var groups: [UInt32: [Message]] = [:]
                    var notGrouped: [Message] = []
                    for message in messages {
                        if let groupInfo = message.groupInfo {
                            if groups[groupInfo.stableId] == nil {
                                groups[groupInfo.stableId] = []
                            }
                            groups[groupInfo.stableId]?.append(message._asMessage())
                        } else {
                            notGrouped.append(message._asMessage())
                        }
                    }
                    
                    let totalGroupCount = notGrouped.count + groups.count
                    
                    var maybeSelectedGroup: [Message]?
                    for (_, group) in groups {
                        if group.contains(where: { $0.id == id}) {
                            maybeSelectedGroup = group
                            break
                        }
                    }
                    for message in notGrouped {
                        if message.id == id {
                            maybeSelectedGroup = [message]
                        }
                    }
                    
                    guard let selectedGroup = maybeSelectedGroup, let topMessage = selectedGroup.first else {
                        return
                    }
                    
                    var actions: [ContextMenuItem] = []
                    actions.append(.action(ContextMenuActionItem(text: strongSelf.presentationData.strings.Conversation_MessageDialogRetry, icon: { theme in
                        return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Resend"), color: theme.actionSheet.primaryTextColor)
                    }, action: { [weak self] _, f in
                        if let strongSelf = self {
                            let _ = resendMessages(account: strongSelf.context.account, messageIds: selectedGroup.map({ $0.id })).startStandalone()
                        }
                        f(.dismissWithoutContent)
                    })))
                    if totalGroupCount != 1 {
                        actions.append(.action(ContextMenuActionItem(text: strongSelf.presentationData.strings.Conversation_MessageDialogRetryAll(totalGroupCount).string, icon: { theme in
                            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Resend"), color: theme.actionSheet.primaryTextColor)
                        }, action: { [weak self] _, f in
                            if let strongSelf = self {
                                let _ = resendMessages(account: strongSelf.context.account, messageIds: messages.map({ $0.id })).startStandalone()
                            }
                            f(.dismissWithoutContent)
                        })))
                    }
                    actions.append(.action(ContextMenuActionItem(text: strongSelf.presentationData.strings.Conversation_ContextMenuDelete, textColor: .destructive, icon: { theme in
                        return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Delete"), color: theme.actionSheet.destructiveActionTextColor)
                    }, action: { [weak self] controller, f in
                        if let strongSelf = self {
                            let _ = strongSelf.context.engine.messages.deleteMessagesInteractively(messageIds: [id], type: .forLocalPeer).startStandalone()
                        }
                        f(.dismissWithoutContent)
                    })))
                    
                    strongSelf.chatDisplayNode.messageTransitionNode.dismissMessageReactionContexts()
                    
                    let controller = ContextController(presentationData: strongSelf.presentationData, source: .extracted(ChatMessageContextExtractedContentSource(chatNode: strongSelf.chatDisplayNode, engine: strongSelf.context.engine, message: topMessage, selectAll: true)), items: .single(ContextController.Items(content: .list(actions))), recognizer: nil)
                    strongSelf.currentContextController = controller
                    strongSelf.forEachController({ controller in
                        if let controller = controller as? TooltipScreen {
                            controller.dismiss()
                        }
                        return true
                    })
                    strongSelf.window?.presentInGlobalOverlay(controller)
                })
            }
        }, addContact: { [weak self] phoneNumber in
            if let strongSelf = self {
                let _ = strongSelf.presentVoiceMessageDiscardAlert(action: {
                    strongSelf.context.sharedContext.openAddContact(context: strongSelf.context, firstName: "", lastName: "", phoneNumber: phoneNumber, label: defaultContactLabel, present: { [weak self] controller, arguments in
                        self?.present(controller, in: .window(.root), with: arguments)
                    }, pushController: { [weak self] controller in
                        if let strongSelf = self {
                            strongSelf.effectiveNavigationController?.pushViewController(controller)
                        }
                    }, completed: {})
                })
            }
        }, rateCall: { [weak self] message, callId, isVideo in
            if let strongSelf = self {
                let controller = callRatingController(sharedContext: strongSelf.context.sharedContext, account: strongSelf.context.account, callId: callId, userInitiated: true, isVideo: isVideo, present: { [weak self] c, a in
                    if let strongSelf = self {
                        strongSelf.present(c, in: .window(.root), with: a)
                    }
                }, push: { [weak self] c in
                    if let strongSelf = self {
                        strongSelf.push(c)
                    }
                })
                strongSelf.chatDisplayNode.dismissInput()
                strongSelf.present(controller, in: .window(.root))
            }
        }, requestSelectMessagePollOptions: { [weak self] id, opaqueIdentifiers in
            guard let strongSelf = self, let controllerInteraction = strongSelf.controllerInteraction else {
                return
            }
            
            guard strongSelf.presentationInterfaceState.subject != .scheduledMessages else {
                strongSelf.present(textAlertController(context: strongSelf.context, updatedPresentationData: strongSelf.updatedPresentationData, title: nil, text: strongSelf.presentationData.strings.ScheduledMessages_PollUnavailable, actions: [TextAlertAction(type: .defaultAction, title: strongSelf.presentationData.strings.Common_OK, action: {})]), in: .window(.root))
                return
            }
            if controllerInteraction.pollActionState.pollMessageIdsInProgress[id] == nil {
                controllerInteraction.pollActionState.pollMessageIdsInProgress[id] = opaqueIdentifiers
                strongSelf.chatDisplayNode.historyNode.requestMessageUpdate(id)
                let disposables: DisposableDict<MessageId>
                if let current = strongSelf.selectMessagePollOptionDisposables {
                    disposables = current
                } else {
                    disposables = DisposableDict()
                    strongSelf.selectMessagePollOptionDisposables = disposables
                }
                let signal = strongSelf.context.engine.messages.requestMessageSelectPollOption(messageId: id, opaqueIdentifiers: opaqueIdentifiers)
                disposables.set((signal
                |> deliverOnMainQueue).startStrict(next: { resultPoll in
                    guard let strongSelf = self, let resultPoll = resultPoll else {
                        return
                    }
                    guard let _ = strongSelf.chatDisplayNode.historyNode.messageInCurrentHistoryView(id) else {
                        return
                    }
                    
                    switch resultPoll.kind {
                    case .poll:
                        if strongSelf.selectPollOptionFeedback == nil {
                            strongSelf.selectPollOptionFeedback = HapticFeedback()
                        }
                        strongSelf.selectPollOptionFeedback?.success()
                    case .quiz:
                        if let voters = resultPoll.results.voters {
                            for voter in voters {
                                if voter.selected {
                                    if voter.isCorrect {
                                        if strongSelf.selectPollOptionFeedback == nil {
                                            strongSelf.selectPollOptionFeedback = HapticFeedback()
                                        }
                                        strongSelf.selectPollOptionFeedback?.success()
                                        
                                        strongSelf.chatDisplayNode.animateQuizCorrectOptionSelected()
                                    } else {
                                        var found = false
                                        strongSelf.chatDisplayNode.historyNode.forEachVisibleItemNode { itemNode in
                                            if !found, let itemNode = itemNode as? ChatMessageBubbleItemNode, itemNode.item?.message.id == id {
                                                found = true
                                                if strongSelf.selectPollOptionFeedback == nil {
                                                    strongSelf.selectPollOptionFeedback = HapticFeedback()
                                                }
                                                strongSelf.selectPollOptionFeedback?.error()
                                                
                                                itemNode.animateQuizInvalidOptionSelected()
                                                
                                                if let solution = resultPoll.results.solution {
                                                    for contentNode in itemNode.contentNodes {
                                                        if let contentNode = contentNode as? ChatMessagePollBubbleContentNode {
                                                            let sourceNode = contentNode.solutionTipSourceNode
                                                            strongSelf.displayPollSolution(solution: solution, sourceNode: sourceNode, isAutomatic: true)
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    break
                                }
                            }
                        }
                    }
                }, error: { _ in
                    guard let strongSelf = self, let controllerInteraction = strongSelf.controllerInteraction else {
                        return
                    }
                    if controllerInteraction.pollActionState.pollMessageIdsInProgress.removeValue(forKey: id) != nil {
                        strongSelf.chatDisplayNode.historyNode.requestMessageUpdate(id)
                    }
                }, completed: {
                    guard let strongSelf = self, let controllerInteraction = strongSelf.controllerInteraction else {
                        return
                    }
                    if controllerInteraction.pollActionState.pollMessageIdsInProgress.removeValue(forKey: id) != nil {
                        Queue.mainQueue().after(1.0, {
                            
                            strongSelf.chatDisplayNode.historyNode.requestMessageUpdate(id)
                        })
                    }
                }), forKey: id)
            }
        }, requestOpenMessagePollResults: { [weak self] messageId, pollId in
            guard let strongSelf = self, pollId.namespace == Namespaces.Media.CloudPoll else {
                return
            }
            let _ = strongSelf.presentVoiceMessageDiscardAlert(action: {
                let _ = (strongSelf.context.engine.data.get(TelegramEngine.EngineData.Item.Messages.Message(id: messageId))
                |> deliverOnMainQueue).startStandalone(next: { message in
                    guard let message = message else {
                        return
                    }
                    for media in message.media {
                        if let poll = media as? TelegramMediaPoll, poll.pollId == pollId {
                            strongSelf.push(pollResultsController(context: strongSelf.context, messageId: messageId, poll: poll))
                            break
                        }
                    }
                })
            }, delay: true)
        }, openAppStorePage: { [weak self] in
            if let strongSelf = self {
                strongSelf.context.sharedContext.applicationBindings.openAppStorePage()
            }
        }, displayMessageTooltip: { [weak self] messageId, text, node, nodeRect in
            if let strongSelf = self {
                if let node = node {
                    strongSelf.messageTooltipController?.dismiss()
                    let tooltipController = TooltipController(content: .text(text), baseFontSize: strongSelf.presentationData.listsFontSize.baseDisplaySize, dismissByTapOutside: true, dismissImmediatelyOnLayoutUpdate: true)
                    strongSelf.messageTooltipController = tooltipController
                    tooltipController.dismissed = { [weak tooltipController] _ in
                        if let strongSelf = self, let tooltipController = tooltipController, strongSelf.messageTooltipController === tooltipController {
                            strongSelf.messageTooltipController = nil
                        }
                    }
                    strongSelf.present(tooltipController, in: .window(.root), with: TooltipControllerPresentationArguments(sourceNodeAndRect: {
                        if let strongSelf = self {
                            var rect = node.view.convert(node.view.bounds, to: strongSelf.chatDisplayNode.view)
                            if let nodeRect = nodeRect {
                                rect = CGRect(origin: rect.origin.offsetBy(dx: nodeRect.minX, dy: nodeRect.minY - node.bounds.minY), size: nodeRect.size)
                            }
                            return (strongSelf.chatDisplayNode, rect)
                        }
                        return nil
                    }))
                }
            }
        }, seekToTimecode: { [weak self] message, timestamp, forceOpen in
            if let strongSelf = self {
                var found = false
                if !forceOpen {
                    strongSelf.chatDisplayNode.historyNode.forEachVisibleItemNode { itemNode in
                        if !found, let itemNode = itemNode as? ChatMessageItemView, itemNode.item?.message.id == message.id, let (action, _, _, _, _) = itemNode.playMediaWithSound() {
                            if case let .visible(fraction, _) = itemNode.visibility, fraction > 0.7 {
                                action(Double(timestamp))
                            } else {
                                let _ = strongSelf.controllerInteraction?.openMessage(message, OpenMessageParams(mode: .timecode(Double(timestamp))))
                            }
                            found = true
                        }
                    }
                }
                if !found {
                    var messageId = message.id
                    if let forwardInfo = message.forwardInfo, let sourceMessageId = forwardInfo.sourceMessageId, case let .replyThread(threadMessage) = strongSelf.chatLocation, threadMessage.isChannelPost {
                        messageId = sourceMessageId
                    }
                    if let message = strongSelf.chatDisplayNode.historyNode.messageInCurrentHistoryView(messageId) {
                        let _ = strongSelf.controllerInteraction?.openMessage(message, OpenMessageParams(mode: .timecode(Double(timestamp))))
                    } else {
                        strongSelf.navigateToMessage(messageLocation: .id(messageId, NavigateToMessageParams(timestamp: Double(timestamp), quote: nil)), animated: true, forceInCurrentChat: true)
                    }
                }
            }
        }, scheduleCurrentMessage: { [weak self] in
            if let strongSelf = self {
                strongSelf.presentScheduleTimePicker(completion: { [weak self] time in
                    if let strongSelf = self {
                        if let _ = strongSelf.presentationInterfaceState.interfaceState.mediaDraftState {
                            strongSelf.sendMediaRecording(scheduleTime: time)
                        } else {
                            strongSelf.chatDisplayNode.sendCurrentMessage(scheduleTime: time) { [weak self] in
                                if let strongSelf = self {
                                    strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: false, saveInterfaceState: strongSelf.presentationInterfaceState.subject != .scheduledMessages, {
                                        $0.updatedInterfaceState { $0.withUpdatedReplyMessageSubject(nil).withUpdatedForwardMessageIds(nil).withUpdatedForwardOptionsState(nil).withUpdatedComposeInputState(ChatTextInputState(inputText: NSAttributedString(string: ""))) }
                                    })
                                    
                                    if strongSelf.presentationInterfaceState.subject != .scheduledMessages && time != scheduleWhenOnlineTimestamp {
                                        strongSelf.openScheduledMessages()
                                    }
                                }
                            }
                        }
                    }
                })
            }
        }, sendScheduledMessagesNow: { [weak self] messageIds in
            if let strongSelf = self {
                if let _ = strongSelf.presentationInterfaceState.slowmodeState {
                    if let rect = strongSelf.chatDisplayNode.frameForInputActionButton() {
                        strongSelf.interfaceInteraction?.displaySlowmodeTooltip(strongSelf.chatDisplayNode.view, rect)
                    }
                    return
                } else {
                    let _ = strongSelf.context.engine.messages.sendScheduledMessageNowInteractively(messageId: messageIds.first!).startStandalone()
                }
            }
        }, editScheduledMessagesTime: { [weak self] messageIds in
            if let strongSelf = self, let messageId = messageIds.first {
                let _ = strongSelf.presentVoiceMessageDiscardAlert(action: {
                    let _ = (strongSelf.context.engine.data.get(TelegramEngine.EngineData.Item.Messages.Message(id: messageId))
                    |> deliverOnMainQueue).startStandalone(next: { [weak self] message in
                        guard let strongSelf = self, let message = message else {
                            return
                        }
                        strongSelf.presentScheduleTimePicker(selectedTime: message.timestamp, completion: { [weak self] time in
                            if let strongSelf = self {
                                var entities: TextEntitiesMessageAttribute?
                                for attribute in message.attributes {
                                    if let attribute = attribute as? TextEntitiesMessageAttribute {
                                        entities = attribute
                                        break
                                    }
                                }
                                
                                let inlineStickers: [MediaId: TelegramMediaFile] = [:]
                                strongSelf.editMessageDisposable.set((strongSelf.context.engine.messages.requestEditMessage(messageId: messageId, text: message.text, media: .keep, entities: entities, inlineStickers: inlineStickers, webpagePreviewAttribute: nil, disableUrlPreview: false, scheduleTime: time) |> deliverOnMainQueue).startStrict(next: { result in
                                }, error: { error in
                                }))
                            }
                        })
                    })
                }, delay: true)
            }
        }, performTextSelectionAction: { [weak self] message, canCopy, text, action in
            guard let strongSelf = self else {
                return
            }
            
            if let performTextSelectionAction = strongSelf.performTextSelectionAction {
                performTextSelectionAction(message, canCopy, text, action)
                return
            }
            
            switch action {
            case .copy:
                storeAttributedTextInPasteboard(text)
            case .share:
                let f = {
                    guard let strongSelf = self else {
                        return
                    }
                    let shareController = ShareController(context: strongSelf.context, subject: .text(text.string), externalShare: true, immediateExternalShare: false, updatedPresentationData: strongSelf.updatedPresentationData)
                    strongSelf.chatDisplayNode.dismissInput()
                    strongSelf.present(shareController, in: .window(.root))
                }
                if let currentContextController = strongSelf.currentContextController {
                    currentContextController.dismiss(completion: {
                        f()
                    })
                } else {
                    f()
                }
            case .lookup:
                let controller = UIReferenceLibraryViewController(term: text.string)
                if let window = strongSelf.effectiveNavigationController?.view.window {
                    controller.popoverPresentationController?.sourceView = window
                    controller.popoverPresentationController?.sourceRect = CGRect(origin: CGPoint(x: window.bounds.width / 2.0, y: window.bounds.size.height - 1.0), size: CGSize(width: 1.0, height: 1.0))
                    window.rootViewController?.present(controller, animated: true)
                }
            case .speak:
                if let speechHolder = speakText(context: strongSelf.context, text: text.string) {
                    speechHolder.completion = { [weak self, weak speechHolder] in
                        if let strongSelf = self, strongSelf.currentSpeechHolder == speechHolder {
                            strongSelf.currentSpeechHolder = nil
                        }
                    }
                    strongSelf.currentSpeechHolder = speechHolder
                }
            case .translate:
                strongSelf.chatDisplayNode.dismissInput()
                let f = {
                    let _ = (context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.translationSettings])
                    |> take(1)
                    |> deliverOnMainQueue).startStandalone(next: { [weak self] sharedData in
                        guard let strongSelf = self else {
                            return
                        }
                        let translationSettings: TranslationSettings
                        if let current = sharedData.entries[ApplicationSpecificSharedDataKeys.translationSettings]?.get(TranslationSettings.self) {
                            translationSettings = current
                        } else {
                            translationSettings = TranslationSettings.defaultSettings
                        }
                        
                        var showTranslateIfTopical = false
                        if let peer = strongSelf.presentationInterfaceState.renderedPeer?.chatMainPeer as? TelegramChannel, !(peer.addressName ?? "").isEmpty {
                            showTranslateIfTopical = true
                        }
                        
                        let (_, language) = canTranslateText(context: context, text: text.string, showTranslate: translationSettings.showTranslate, showTranslateIfTopical: showTranslateIfTopical, ignoredLanguages: translationSettings.ignoredLanguages)
                        
                        let _ = ApplicationSpecificNotice.incrementTranslationSuggestion(accountManager: context.sharedContext.accountManager, timestamp: Int32(Date().timeIntervalSince1970)).startStandalone()
                        
                        let controller = TranslateScreen(context: context, text: text.string, canCopy: canCopy, fromLanguage: language, ignoredLanguages: translationSettings.ignoredLanguages)
                        controller.pushController = { [weak self] c in
                            self?.effectiveNavigationController?._keepModalDismissProgress = true
                            self?.push(c)
                        }
                        controller.presentController = { [weak self] c in
                            self?.present(c, in: .window(.root))
                        }
                        strongSelf.present(controller, in: .window(.root))
                    })
                }
                if let currentContextController = strongSelf.currentContextController {
                    currentContextController.dismiss(completion: {
                        f()
                    })
                } else {
                    f()
                }
            case let .quote(range):
                let completion: (ContainedViewLayoutTransition?) -> Void = { transition in
                    guard let self else {
                        return
                    }
                    if let currentContextController = self.currentContextController {
                        self.currentContextController = nil
                        
                        if let transition {
                            currentContextController.dismissWithCustomTransition(transition: transition)
                        } else {
                            currentContextController.dismiss(completion: {})
                        }
                    }
                }
                if let messageId = message?.id, let message = strongSelf.chatDisplayNode.historyNode.messageInCurrentHistoryView(messageId) ?? message {
                    var quoteData: EngineMessageReplyQuote?
                    
                    let nsRange = NSRange(location: range.lowerBound, length: range.upperBound - range.lowerBound)
                    let quoteText = (message.text as NSString).substring(with: nsRange)
                    
                    let trimmedText = trimStringWithEntities(string: quoteText, entities: messageTextEntitiesInRange(entities: message.textEntitiesAttribute?.entities ?? [], range: nsRange, onlyQuoteable: true), maxLength: quoteMaxLength(appConfig: strongSelf.context.currentAppConfiguration.with({ $0 })))
                    if !trimmedText.string.isEmpty {
                        quoteData = EngineMessageReplyQuote(text: trimmedText.string, offset: nsRange.location, entities: trimmedText.entities, media: nil)
                    }
                    
                    let replySubject = ChatInterfaceState.ReplyMessageSubject(
                        messageId: message.id,
                        quote: quoteData
                    )
                    
                    if canSendMessagesToChat(strongSelf.presentationInterfaceState) {
                        let _ = strongSelf.presentVoiceMessageDiscardAlert(action: {
                            strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, { $0.updatedInterfaceState({ $0.withUpdatedReplyMessageSubject(replySubject) }).updatedSearch(nil).updatedShowCommands(false) }, completion: completion)
                            strongSelf.updateItemNodesSearchTextHighlightStates()
                            strongSelf.chatDisplayNode.ensureInputViewFocused()
                        }, alertAction: {
                            completion(nil)
                        }, delay: true)
                    } else {
                        moveReplyMessageToAnotherChat(selfController: strongSelf, replySubject: replySubject)
                        completion(nil)
                    }
                } else {
                    strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, { $0.updatedInterfaceState({ $0.withUpdatedReplyMessageSubject(nil) }) }, completion: completion)
                }
            }
        }, displayImportedMessageTooltip: { [weak self] _ in
            guard let strongSelf = self else {
                return
            }
            if let _ = strongSelf.currentImportMessageTooltip {
            } else {
                let controller = UndoOverlayController(presentationData: strongSelf.presentationData, content: .importedMessage(text: strongSelf.presentationData.strings.Conversation_ImportedMessageHint), elevatedLayout: false, action: { _ in return false })
                strongSelf.currentImportMessageTooltip = controller
                strongSelf.present(controller, in: .current)
            }
        }, displaySwipeToReplyHint: {  [weak self] in
            if let strongSelf = self, let validLayout = strongSelf.validLayout, min(validLayout.size.width, validLayout.size.height) > 320.0 {
                strongSelf.present(UndoOverlayController(presentationData: strongSelf.presentationData, content: .swipeToReply(title: strongSelf.presentationData.strings.Conversation_SwipeToReplyHintTitle, text: strongSelf.presentationData.strings.Conversation_SwipeToReplyHintText), elevatedLayout: false, position: .top, action: { _ in return false }), in: .current)
            }
        }, dismissReplyMarkupMessage: { [weak self] message in
            guard let strongSelf = self, strongSelf.presentationInterfaceState.keyboardButtonsMessage?.id == message.id else {
                return
            }
            strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, {
                return $0.updatedInputMode({ _ in .text }).updatedInterfaceState({
                    $0.withUpdatedMessageActionsState({ value in
                        var value = value
                        value.closedButtonKeyboardMessageId = message.id
                        value.dismissedButtonKeyboardMessageId = message.id
                        return value
                    })
                })
            })
        }, openMessagePollResults: { [weak self] messageId, optionOpaqueIdentifier in
            guard let strongSelf = self else {
                return
            }
            let _ = strongSelf.presentVoiceMessageDiscardAlert(action: {
                let _ = (strongSelf.context.engine.data.get(TelegramEngine.EngineData.Item.Messages.Message(id: messageId))
                |> deliverOnMainQueue).startStandalone(next: { message in
                    guard let message = message else {
                        return
                    }
                    for media in message.media {
                        if let poll = media as? TelegramMediaPoll, poll.pollId.namespace == Namespaces.Media.CloudPoll {
                            strongSelf.push(pollResultsController(context: strongSelf.context, messageId: messageId, poll: poll, focusOnOptionWithOpaqueIdentifier: optionOpaqueIdentifier))
                            break
                        }
                    }
                })
            })
        }, openPollCreation: { [weak self] isQuiz in
            guard let strongSelf = self else {
                return
            }
            let _ = strongSelf.presentVoiceMessageDiscardAlert(action: {
                if let controller = strongSelf.configurePollCreation(isQuiz: isQuiz) {
                    strongSelf.effectiveNavigationController?.pushViewController(controller)
                }
            })
        }, displayPollSolution: { [weak self] solution, sourceNode in
            self?.displayPollSolution(solution: solution, sourceNode: sourceNode, isAutomatic: false)
        }, displayPsa: { [weak self] type, sourceNode in
            self?.displayPsa(type: type, sourceNode: sourceNode, isAutomatic: false)
        }, displayDiceTooltip: { [weak self] dice in
            self?.displayDiceTooltip(dice: dice)
        }, animateDiceSuccess: { [weak self] haptic, confetti in
            guard let strongSelf = self else {
                return
            }
            if strongSelf.selectPollOptionFeedback == nil {
                strongSelf.selectPollOptionFeedback = HapticFeedback()
            }
            if haptic {
                strongSelf.selectPollOptionFeedback?.success()
            }
            if confetti {
                strongSelf.chatDisplayNode.animateQuizCorrectOptionSelected()
            }
        }, displayPremiumStickerTooltip: { [weak self] file, message in
            self?.displayPremiumStickerTooltip(file: file, message: message)
        }, displayEmojiPackTooltip: { [weak self] file, message in
            self?.displayEmojiPackTooltip(file: file, message: message)
        }, openPeerContextMenu: { [weak self] peer, messageId, node, rect, gesture in
            guard let strongSelf = self else {
                return
            }
            
            if strongSelf.presentationInterfaceState.interfaceState.selectionState != nil {
                return
            }
            
            strongSelf.dismissAllTooltips()
            
            let context = strongSelf.context
            
            let dataSignal: Signal<(EnginePeer?, EngineMessage?), NoError>
            if let messageId = messageId {
                dataSignal = context.engine.data.get(
                    TelegramEngine.EngineData.Item.Peer.Peer(id: peer.id),
                    TelegramEngine.EngineData.Item.Messages.Message(id: messageId)
                )
            } else {
                dataSignal = context.engine.data.get(
                    TelegramEngine.EngineData.Item.Peer.Peer(id: peer.id)
                )
                |> map { peer -> (EnginePeer?, EngineMessage?) in
                    return (peer, nil)
                }
            }
            
            let _ = (dataSignal
            |> deliverOnMainQueue).startStandalone(next: { [weak self] peer, message in
                guard let strongSelf = self, let peer = peer, peer.smallProfileImage != nil else {
                    return
                }
              
                let galleryController = AvatarGalleryController(context: context, peer: peer, remoteEntries: nil, replaceRootController: { controller, ready in
                }, synchronousLoad: true)
                galleryController.setHintWillBePresentedInPreviewingContext(true)
                
                var isChannel = false
                if case let .channel(peer) = peer, case .broadcast = peer.info {
                    isChannel = true
                }
                var items: [ContextMenuItem] = [
                    .action(ContextMenuActionItem(text: isChannel ? strongSelf.presentationData.strings.Conversation_ContextMenuOpenChannelProfile : strongSelf.presentationData.strings.Conversation_ContextMenuOpenProfile, icon: { theme in
                        return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/User"), color: theme.actionSheet.primaryTextColor)
                    }, action: { _, f in
                        f(.dismissWithoutContent)
                        self?.openPeer(peer: peer, navigation: .info(nil), fromMessage: nil)
                    }))
                ]
                items.append(.action(ContextMenuActionItem(text: isChannel ? strongSelf.presentationData.strings.Conversation_ContextMenuOpenChannel : strongSelf.presentationData.strings.Conversation_ContextMenuSendMessage, icon: { theme in
                    return generateTintedImage(image: UIImage(bundleImageName: isChannel ? "Chat/Context Menu/Channels" : "Chat/Context Menu/Message"), color: theme.actionSheet.primaryTextColor)
                }, action: { _, f in
                    f(.dismissWithoutContent)
                    self?.openPeer(peer: peer, navigation: .chat(textInputState: nil, subject: nil, peekData: nil), fromMessage: nil)
                })))
                if !isChannel && canSendMessagesToChat(strongSelf.presentationInterfaceState) {
                    items.append(.action(ContextMenuActionItem(text: strongSelf.presentationData.strings.Conversation_ContextMenuMention, icon: { theme in
                        return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Mention"), color: theme.actionSheet.primaryTextColor)
                    }, action: { _, f in
                        f(.dismissWithoutContent)
                        
                        guard let strongSelf = self else {
                            return
                        }
                        
                        let _ = strongSelf.presentVoiceMessageDiscardAlert(action: {
                            strongSelf.interfaceInteraction?.updateTextInputStateAndMode { current, inputMode in
                                var inputMode = inputMode
                                if inputMode == .none {
                                    inputMode = .text
                                }
                                return (chatTextInputAddMentionAttribute(current, peer: peer), inputMode)
                            }
                        }, delay: true)
                    })))
                }
                
                strongSelf.chatDisplayNode.messageTransitionNode.dismissMessageReactionContexts()
                
                strongSelf.canReadHistory.set(false)
                
                let contextController = ContextController(presentationData: strongSelf.presentationData, source: .controller(ChatContextControllerContentSourceImpl(controller: galleryController, sourceNode: node, passthroughTouches: false)), items: .single(ContextController.Items(content: .list(items))), gesture: gesture)
                contextController.dismissed = { [weak self] in
                    self?.canReadHistory.set(true)
                }
                strongSelf.presentInGlobalOverlay(contextController)
            })
        }, openMessageReplies: { [weak self] messageId, isChannelPost, displayModalProgress in
            guard let strongSelf = self else {
                return
            }
            
            strongSelf.openMessageReplies(messageId: messageId, displayProgressInMessage: displayModalProgress ? nil : messageId, isChannelPost: isChannelPost, atMessage: nil, displayModalProgress: displayModalProgress)
        }, openReplyThreadOriginalMessage: { [weak self] message in
            guard let strongSelf = self else {
                return
            }
            var threadMessageId: MessageId?
            for attribute in message.attributes {
                if let attribute = attribute as? ReplyMessageAttribute {
                    threadMessageId = attribute.threadMessageId
                    break
                }
            }
            for attribute in message.attributes {
                if let attribute = attribute as? SourceReferenceMessageAttribute {
                    if let threadMessageId = threadMessageId {
                        if let _ = strongSelf.navigationController as? NavigationController {
                            strongSelf.openMessageReplies(messageId: threadMessageId, displayProgressInMessage: message.id, isChannelPost: true, atMessage: attribute.messageId, displayModalProgress: false)
                        }
                    } else {
                        strongSelf.navigateToMessage(from: nil, to: .id(attribute.messageId, NavigateToMessageParams(timestamp: nil, quote: nil)))
                    }
                    break
                }
            }
        }, openMessageStats: { [weak self] id in
            guard let strongSelf = self else {
                return
            }
            
            let _ = strongSelf.presentVoiceMessageDiscardAlert(action: {
                let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Messages.Message(id: id))
                |> mapToSignal { message -> Signal<EngineMessage.Id?, NoError> in
                    if let message {
                        return .single(message.id)
                    } else {
                        return .complete()
                    }
                }
                |> deliverOnMainQueue).startStandalone(next: { [weak self] messageId in
                    guard let strongSelf = self, let messageId else {
                        return
                    }
                    strongSelf.push(messageStatsController(context: context, subject: .message(id: messageId)))
                })
            }, delay: true)
        }, editMessageMedia: { [weak self] messageId, draw in
            guard let strongSelf = self else {
                return
            }
            
            strongSelf.chatDisplayNode.dismissInput()
            
            if draw {
                let _ = (strongSelf.context.engine.data.get(TelegramEngine.EngineData.Item.Messages.Message(id: messageId))
                |> deliverOnMainQueue).startStandalone(next: { [weak self] message in
                    guard let strongSelf = self, let message = message else {
                        return
                    }
                    
                    var mediaReference: AnyMediaReference?
                    for m in message.media {
                        if let image = m as? TelegramMediaImage {
                            mediaReference = AnyMediaReference.standalone(media: image)
                        }
                    }
                    
                    if let mediaReference = mediaReference, let peer = message.peers[message.id.peerId] {
                        let inputText = strongSelf.presentationInterfaceState.interfaceState.effectiveInputState.inputText
                        legacyMediaEditor(context: strongSelf.context, peer: peer, threadTitle: strongSelf.threadInfo?.title, media: mediaReference, mode: .draw, initialCaption: inputText, snapshots: [], transitionCompletion: nil, getCaptionPanelView: { [weak self] in
                            return self?.getCaptionPanelView()
                        }, sendMessagesWithSignals: { [weak self] signals, _, _ in
                            if let strongSelf = self {
                                strongSelf.interfaceInteraction?.setupEditMessage(messageId, { _ in })
                                strongSelf.editMessageMediaWithLegacySignals(signals!)
                            }
                        }, present: { [weak self] c, a in
                            self?.present(c, in: .window(.root), with: a)
                        })
                    }
                })
            } else {
                strongSelf.presentOldMediaPicker(fileMode: false, editingMedia: true, completion: { signals, _, _ in
                    self?.interfaceInteraction?.setupEditMessage(messageId, { _ in })
                    self?.editMessageMediaWithLegacySignals(signals)
                })
            }
        }, copyText: { [weak self] text in
            if let strongSelf = self {
                storeMessageTextInPasteboard(text, entities: nil)
                
                let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                strongSelf.present(UndoOverlayController(presentationData: presentationData, content: .copy(text: presentationData.strings.Conversation_TextCopied), elevatedLayout: false, animateInAsReplacement: false, action: { _ in
                        return true
                }), in: .current)
            }
        }, displayUndo: { [weak self] content in
            if let strongSelf = self {
                let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                
                strongSelf.window?.forEachController({ controller in
                    if let controller = controller as? UndoOverlayController {
                        controller.dismiss()
                    }
                })
                strongSelf.forEachController({ controller in
                    if let controller = controller as? UndoOverlayController {
                        controller.dismiss()
                    }
                    return true
                })
                
                strongSelf.present(UndoOverlayController(presentationData: presentationData, content: content, elevatedLayout: false, animateInAsReplacement: false, action: { _ in
                        return true
                }), in: .current)
            }
        }, isAnimatingMessage: { [weak self] stableId in
            guard let strongSelf = self else {
                return false
            }
            return strongSelf.chatDisplayNode.messageTransitionNode.isAnimatingMessage(stableId: stableId)
        }, getMessageTransitionNode: { [weak self] in
            guard let strongSelf = self else {
                return nil
            }
            return strongSelf.chatDisplayNode.messageTransitionNode
        }, updateChoosingSticker: { [weak self] value in
            if let strongSelf = self {
                strongSelf.choosingStickerActivityPromise.set(value)
            }
        }, commitEmojiInteraction: { [weak self] messageId, emoji, interaction, file in
            guard let strongSelf = self, let peer = strongSelf.presentationInterfaceState.renderedPeer?.chatMainPeer, peer.id != strongSelf.context.account.peerId else {
                return
            }
            
            strongSelf.context.account.updateLocalInputActivity(peerId: PeerActivitySpace(peerId: messageId.peerId, category: .global), activity: .interactingWithEmoji(emoticon: emoji, messageId: messageId, interaction: interaction), isPresent: true)
            
            let currentTimestamp = Int32(Date().timeIntervalSince1970)
            let _ = (ApplicationSpecificNotice.getInteractiveEmojiSyncTip(accountManager: strongSelf.context.sharedContext.accountManager)
            |> deliverOnMainQueue).startStandalone(next: { [weak self] count, timestamp in
                if let strongSelf = self, count < 3 && currentTimestamp > timestamp + 24 * 60 * 60 {
                    strongSelf.interactiveEmojiSyncDisposable.set(
                        (strongSelf.peerInputActivitiesPromise.get()
                        |> filter { activities -> Bool in
                            var found = false
                            for (_, activity) in activities {
                                if case .seeingEmojiInteraction(emoji) = activity {
                                    found = true
                                    break
                                }
                            }
                            return found
                        }
                        |> map { _ -> Bool in
                            return true
                        }
                        |> timeout(2.0, queue: Queue.mainQueue(), alternate: .single(false))).startStrict(next: { [weak self] responded in
                            if let strongSelf = self {
                                if !responded {
                                    strongSelf.present(UndoOverlayController(presentationData: strongSelf.presentationData, content: .sticker(context: strongSelf.context, file: file, loop: true, title: nil, text: strongSelf.presentationData.strings.Conversation_InteractiveEmojiSyncTip(EnginePeer(peer).compactDisplayTitle).string, undoText: nil, customAction: nil), elevatedLayout: false, action: { _ in return false }), in: .current)
                                    
                                    let _ = ApplicationSpecificNotice.incrementInteractiveEmojiSyncTip(accountManager: strongSelf.context.sharedContext.accountManager, timestamp: currentTimestamp).startStandalone()
                                }
                            }
                        })
                    )
                }
            })
        }, openLargeEmojiInfo: { [weak self] _, fitz, file in
            guard let strongSelf = self else {
                return
            }
            let actionSheet = ActionSheetController(presentationData: strongSelf.presentationData)
            actionSheet.setItemGroups([ActionSheetItemGroup(items: [
                LargeEmojiActionSheetItem(context: strongSelf.context, text: strongSelf.presentationData.strings.Conversation_LargeEmojiDisabledInfo, fitz: fitz, file: file),
                ActionSheetButtonItem(title: strongSelf.presentationData.strings.Conversation_LargeEmojiEnable, color: .accent, action: { [weak actionSheet, weak self] in
                    actionSheet?.dismissAnimated()
                    guard let strongSelf = self else {
                        return
                    }
                    let _ = updatePresentationThemeSettingsInteractively(accountManager: strongSelf.context.sharedContext.accountManager, { current in
                        return current.withUpdatedLargeEmoji(true)
                    }).startStandalone()
                    
                    strongSelf.present(UndoOverlayController(presentationData: strongSelf.presentationData, content: .emoji(name: "TwoFactorSetupRememberSuccess", text: strongSelf.presentationData.strings.Conversation_LargeEmojiEnabled), elevatedLayout: false, action: { _ in return false }), in: .current)
                })
            ]), ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: strongSelf.presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                })
            ])])
            strongSelf.chatDisplayNode.dismissInput()
            strongSelf.present(actionSheet, in: .window(.root))
        }, openJoinLink: { [weak self] joinHash in
            guard let strongSelf = self else {
                return
            }
            strongSelf.openResolved(result: .join(joinHash), sourceMessageId: nil)
        }, openWebView: { [weak self] buttonText, url, simple, source in
            guard let strongSelf = self, let peerId = strongSelf.chatLocation.peerId, let peer = strongSelf.presentationInterfaceState.renderedPeer?.peer else {
                return
            }
            
            strongSelf.chatDisplayNode.dismissInput()
            
            let botName: String
            let botAddress: String
            if case let .inline(bot) = source {
                botName = bot.compactDisplayTitle
                botAddress = bot.addressName ?? ""
            } else {
                botName = EnginePeer(peer).displayTitle(strings: strongSelf.presentationData.strings, displayOrder: strongSelf.presentationData.nameDisplayOrder)
                botAddress = peer.addressName ?? ""
            }
            
            if source == .generic {
                strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, {
                    return $0.updatedTitlePanelContext {
                        if !$0.contains(where: {
                            switch $0 {
                                case .requestInProgress:
                                    return true
                                default:
                                    return false
                            }
                        }) {
                            var updatedContexts = $0
                            updatedContexts.append(.requestInProgress)
                            return updatedContexts.sorted()
                        }
                        return $0
                    }
                })
            }
            
            let updateProgress = { [weak self] in
                Queue.mainQueue().async {
                    if let strongSelf = self {
                        strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, {
                            return $0.updatedTitlePanelContext {
                                if let index = $0.firstIndex(where: {
                                    switch $0 {
                                        case .requestInProgress:
                                            return true
                                        default:
                                            return false
                                    }
                                }) {
                                    var updatedContexts = $0
                                    updatedContexts.remove(at: index)
                                    return updatedContexts
                                }
                                return $0
                            }
                        })
                    }
                }
            }
            
            let openWebView = {
                if source == .menu {
                    strongSelf.updateChatPresentationInterfaceState(interactive: false) { state in
                        return state.updatedShowWebView(true).updatedForceInputCommandsHidden(true)
                    }
                    
                    let params = WebAppParameters(source: .menu, peerId: peerId, botId: peerId, botName: botName, url: url, queryId: nil, payload: nil, buttonText: buttonText, keepAliveSignal: nil, forceHasSettings: false)
                    let controller = standaloneWebAppController(context: strongSelf.context, updatedPresentationData: strongSelf.updatedPresentationData, params: params, threadId: strongSelf.chatLocation.threadId, openUrl: { [weak self] url, concealed, commit in
                        self?.openUrl(url, concealed: concealed, forceExternal: true, commit: commit)
                    }, requestSwitchInline: { [weak self] query, chatTypes, completion in
                        if let strongSelf = self {
                            if let chatTypes {
                                let controller = strongSelf.context.sharedContext.makePeerSelectionController(PeerSelectionControllerParams(context: strongSelf.context, filter: [.excludeRecent, .doNotSearchMessages], requestPeerType: chatTypes, hasContactSelector: false, hasCreation: false))
                                controller.peerSelected = { [weak self, weak controller] peer, _ in
                                    if let strongSelf = self {
                                        completion()
                                        controller?.dismiss()
                                        strongSelf.controllerInteraction?.activateSwitchInline(peer.id, "@\(botAddress) \(query)", nil)
                                    }
                                }
                                strongSelf.push(controller)
                            } else {
                                strongSelf.controllerInteraction?.activateSwitchInline(peerId, "@\(botAddress) \(query)", nil)
                            }
                        }
                    }, getInputContainerNode: { [weak self] in
                        if let strongSelf = self, let layout = strongSelf.validLayout, case .compact = layout.metrics.widthClass {
                            return (strongSelf.chatDisplayNode.getWindowInputAccessoryHeight(), strongSelf.chatDisplayNode.inputPanelContainerNode, {
                                return strongSelf.chatDisplayNode.textInputPanelNode?.makeAttachmentMenuTransition(accessoryPanelNode: nil)
                            })
                        } else {
                            return nil
                        }
                    }, completion: { [weak self] in
                        self?.chatDisplayNode.historyNode.scrollToEndOfHistory()
                    }, willDismiss: { [weak self] in
                        self?.interfaceInteraction?.updateShowWebView { _ in
                            return false
                        }
                    }, didDismiss: { [weak self] in
                        if let strongSelf = self {
                            let isFocused = strongSelf.chatDisplayNode.textInputPanelNode?.isFocused ?? false
                            strongSelf.chatDisplayNode.insertSubnode(strongSelf.chatDisplayNode.inputPanelContainerNode, aboveSubnode: strongSelf.chatDisplayNode.inputContextPanelContainer)
                            if isFocused {
                                strongSelf.chatDisplayNode.textInputPanelNode?.ensureFocused()
                            }
                            
                            strongSelf.updateChatPresentationInterfaceState(interactive: false) { state in
                                return state.updatedForceInputCommandsHidden(false)
                            }
                        }
                    }, getNavigationController: { [weak self] in
                        return self?.effectiveNavigationController
                    })
                    controller.navigationPresentation = .flatModal
                    strongSelf.push(controller)
                    strongSelf.currentMenuWebAppController = controller
                } else if simple {
                    var isInline = false
                    var botId = peerId
                    var botName = botName
                    var botAddress = ""
                    if case let .inline(bot) = source {
                        isInline = true
                        botId = bot.id
                        botName = bot.displayTitle(strings: strongSelf.presentationData.strings, displayOrder: strongSelf.presentationData.nameDisplayOrder)
                        botAddress = bot.addressName ?? ""
                    }
                    
                    strongSelf.messageActionCallbackDisposable.set(((strongSelf.context.engine.messages.requestSimpleWebView(botId: botId, url: url, source: isInline ? .inline : .generic, themeParams: generateWebAppThemeParams(strongSelf.presentationData.theme))
                    |> afterDisposed {
                        updateProgress()
                    })
                    |> deliverOnMainQueue).startStrict(next: { [weak self] url in
                        guard let strongSelf = self else {
                            return
                        }
                        let params = WebAppParameters(source: isInline ? .inline : .simple, peerId: peerId, botId: botId, botName: botName, url: url, queryId: nil, payload: nil, buttonText: buttonText, keepAliveSignal: nil, forceHasSettings: false)
                        let controller = standaloneWebAppController(context: strongSelf.context, updatedPresentationData: strongSelf.updatedPresentationData, params: params, threadId: strongSelf.chatLocation.threadId, openUrl: { [weak self] url, concealed, commit in
                            self?.openUrl(url, concealed: concealed, forceExternal: true, commit: commit)
                        }, requestSwitchInline: { [weak self] query, chatTypes, completion in
                            if let strongSelf = self {
                                if let chatTypes {
                                    let controller = strongSelf.context.sharedContext.makePeerSelectionController(PeerSelectionControllerParams(context: strongSelf.context, filter: [.excludeRecent, .doNotSearchMessages], requestPeerType: chatTypes, hasContactSelector: false, hasCreation: false))
                                    controller.peerSelected = { [weak self, weak controller] peer, _ in
                                        if let strongSelf = self {
                                            completion()
                                            controller?.dismiss()
                                            strongSelf.controllerInteraction?.activateSwitchInline(peer.id, "@\(botAddress) \(query)", nil)
                                        }
                                    }
                                    strongSelf.push(controller)
                                } else {
                                    strongSelf.controllerInteraction?.activateSwitchInline(peerId, "@\(botAddress) \(query)", nil)
                                }
                            }
                        }, getNavigationController: { [weak self] in
                            return self?.effectiveNavigationController
                        })
                        controller.navigationPresentation = .flatModal
                        strongSelf.currentWebAppController = controller
                        strongSelf.push(controller)
                    }, error: { [weak self] error in
                        if let strongSelf = self {
                            strongSelf.present(textAlertController(context: strongSelf.context, updatedPresentationData: strongSelf.updatedPresentationData, title: nil, text: strongSelf.presentationData.strings.Login_UnknownError, actions: [TextAlertAction(type: .defaultAction, title: strongSelf.presentationData.strings.Common_OK, action: {
                            })]), in: .window(.root))
                        }
                    }))
                } else {
                    strongSelf.messageActionCallbackDisposable.set(((strongSelf.context.engine.messages.requestWebView(peerId: peerId, botId: peerId, url: !url.isEmpty ? url : nil, payload: nil, themeParams: generateWebAppThemeParams(strongSelf.presentationData.theme), fromMenu: buttonText == "Menu", replyToMessageId: nil, threadId: strongSelf.chatLocation.threadId)
                    |> afterDisposed {
                        updateProgress()
                    })
                    |> deliverOnMainQueue).startStrict(next: { [weak self] result in
                        guard let strongSelf = self else {
                            return
                        }
                        let params = WebAppParameters(source: .generic, peerId: peerId, botId: peerId, botName: botName, url: result.url, queryId: result.queryId, payload: nil, buttonText: buttonText, keepAliveSignal: result.keepAliveSignal, forceHasSettings: false)
                        let controller = standaloneWebAppController(context: strongSelf.context, updatedPresentationData: strongSelf.updatedPresentationData, params: params, threadId: strongSelf.chatLocation.threadId, openUrl: { [weak self] url, concealed, commit in
                            self?.openUrl(url, concealed: concealed, forceExternal: true, commit: commit)
                        }, completion: { [weak self] in
                            self?.chatDisplayNode.historyNode.scrollToEndOfHistory()
                        }, getNavigationController: { [weak self] in
                            return self?.effectiveNavigationController
                        })
                        controller.navigationPresentation = .flatModal
                        strongSelf.currentWebAppController = controller
                        strongSelf.push(controller)
                    }, error: { [weak self] error in
                        if let strongSelf = self {
                            strongSelf.present(textAlertController(context: strongSelf.context, updatedPresentationData: strongSelf.updatedPresentationData, title: nil, text: strongSelf.presentationData.strings.Login_UnknownError, actions: [TextAlertAction(type: .defaultAction, title: strongSelf.presentationData.strings.Common_OK, action: {
                            })]), in: .window(.root))
                        }
                    }))
                }
            }
            
            var botPeer = EnginePeer(peer)
            if case let .inline(bot) = source {
                botPeer = bot
            }
            let _ = (ApplicationSpecificNotice.getBotGameNotice(accountManager: strongSelf.context.sharedContext.accountManager, peerId: botPeer.id)
            |> deliverOnMainQueue).startStandalone(next: { value in
                guard let strongSelf = self else {
                    return
                }

                if value {
                    openWebView()
                } else {
                    let controller = webAppLaunchConfirmationController(context: strongSelf.context, updatedPresentationData: strongSelf.updatedPresentationData, peer: botPeer, completion: { _ in
                        let _ = ApplicationSpecificNotice.setBotGameNotice(accountManager: strongSelf.context.sharedContext.accountManager, peerId: botPeer.id).startStandalone()
                        openWebView()
                    }, showMore: nil)
                    strongSelf.present(controller, in: .window(.root))
                }
            })
        }, activateAdAction: { [weak self] messageId in
            guard let self, let message = self.chatDisplayNode.historyNode.messageInCurrentHistoryView(messageId), let adAttribute = message.adAttribute else {
                return
            }
            
            self.chatDisplayNode.historyNode.adMessagesContext?.markAction(opaqueId: adAttribute.opaqueId)
            
            switch adAttribute.target {
            case let .peer(id, messageId, startParam):
                if case let .peer(currentPeerId) = self.chatLocation, currentPeerId == id {
                    if let messageId {
                        self.navigateToMessage(from: nil, to: .id(messageId, NavigateToMessageParams(timestamp: nil, quote: nil)), rememberInStack: false)
                    }
                } else {
                    let navigationData: ChatControllerInteractionNavigateToPeer
                    if let bot = message.author as? TelegramUser, bot.botInfo != nil, let startParam = startParam {
                        navigationData = .withBotStartPayload(ChatControllerInitialBotStart(payload: startParam, behavior: .interactive))
                    } else {
                        var subject: ChatControllerSubject?
                        if let messageId = messageId {
                            subject = .message(id: .id(messageId), highlight: ChatControllerSubject.MessageHighlight(quote: nil), timecode: nil)
                        }
                        navigationData = .chat(textInputState: nil, subject: subject, peekData: nil)
                    }
                    let _ = (self.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: id))
                    |> deliverOnMainQueue).startStandalone(next: { [weak self] peer in
                        if let self, let peer = peer {
                            self.openPeer(peer: peer, navigation: navigationData, fromMessage: nil)
                        }
                    })
                }
            case let .join(_, joinHash):
                self.controllerInteraction?.openJoinLink(joinHash)
            case let .webPage(_, url):
                self.controllerInteraction?.openUrl(ChatControllerInteraction.OpenUrl(url: url, concealed: false, external: true))
            case let .botApp(peerId, botApp, startParam):
                let _ = (self.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
                |> deliverOnMainQueue).startStandalone(next: { [weak self] peer in
                    if let self, let peer {
                        self.presentBotApp(botApp: botApp, botPeer: peer, payload: startParam)
                    }
                })
            }
        }, openRequestedPeerSelection: { [weak self] messageId, peerType, buttonId, maxQuantity in
            guard let self else {
                return
            }
            let botName = self.presentationInterfaceState.renderedPeer?.peer.flatMap { EnginePeer($0) }?.compactDisplayTitle ?? ""
            let context = self.context
            let peerId = self.chatLocation.peerId
            
            let presentConfirmation: (String, Bool, @escaping () -> Void) -> Void = { [weak self] peerName, isChannel, completion in
                guard let strongSelf = self else {
                    return
                }
                
                var attributedTitle: NSAttributedString?
                let attributedText: NSAttributedString
                
                let theme = AlertControllerTheme(presentationData: strongSelf.presentationData)
                if case .user = peerType {
                    attributedTitle = nil
                    attributedText = NSAttributedString(string: strongSelf.presentationData.strings.RequestPeer_SelectionConfirmationTitle(peerName, botName).string, font: Font.medium(17.0), textColor: theme.primaryColor, paragraphAlignment: .center)
                } else {
                    attributedTitle = NSAttributedString(string: strongSelf.presentationData.strings.RequestPeer_SelectionConfirmationTitle(peerName, botName).string, font: Font.semibold(17.0), textColor: theme.primaryColor, paragraphAlignment: .center)
                    
                    var botAdminRights: TelegramChatAdminRights?
                    switch peerType {
                    case let .group(group):
                        botAdminRights = group.botAdminRights
                    case let .channel(channel):
                        botAdminRights = channel.botAdminRights
                    default:
                        break
                    }
                    if let botAdminRights {
                        if botAdminRights.rights.isEmpty {
                            let stringWithRanges = strongSelf.presentationData.strings.RequestPeer_SelectionConfirmationInviteAdminText(botName, peerName)
                            let formattedString = NSMutableAttributedString(string: stringWithRanges.string, font: Font.regular(strongSelf.presentationData.listsFontSize.baseDisplaySize * 13.0 / 17.0), textColor: theme.primaryColor, paragraphAlignment: .center)
                            for range in stringWithRanges.ranges.prefix(2) {
                                formattedString.addAttribute(.font, value: Font.semibold(strongSelf.presentationData.listsFontSize.baseDisplaySize * 13.0 / 17.0), range: range.range)
                            }
                            attributedText = formattedString
                        } else {
                            let stringWithRanges = strongSelf.presentationData.strings.RequestPeer_SelectionConfirmationInviteWithRightsText(botName, peerName, stringForAdminRights(strings: strongSelf.presentationData.strings, adminRights: botAdminRights, isChannel: isChannel))
                            let formattedString = NSMutableAttributedString(string: stringWithRanges.string, font: Font.regular(strongSelf.presentationData.listsFontSize.baseDisplaySize * 13.0 / 17.0), textColor: theme.primaryColor, paragraphAlignment: .center)
                            for range in stringWithRanges.ranges.prefix(2) {
                                formattedString.addAttribute(.font, value: Font.semibold(strongSelf.presentationData.listsFontSize.baseDisplaySize * 13.0 / 17.0), range: range.range)
                            }
                            attributedText = formattedString
                        }
                    } else {
                        if case let .group(group) = peerType, group.botParticipant {
                            let stringWithRanges = strongSelf.presentationData.strings.RequestPeer_SelectionConfirmationInviteText(botName, peerName)
                            let formattedString = NSMutableAttributedString(string: stringWithRanges.string, font: Font.regular(strongSelf.presentationData.listsFontSize.baseDisplaySize * 13.0 / 17.0), textColor: theme.primaryColor, paragraphAlignment: .center)
                            for range in stringWithRanges.ranges.prefix(2) {
                                formattedString.addAttribute(.font, value: Font.semibold(strongSelf.presentationData.listsFontSize.baseDisplaySize * 13.0 / 17.0), range: range.range)
                            }
                            attributedText = formattedString
                        } else {
                            attributedTitle = nil
                            attributedText = NSAttributedString(string: strongSelf.presentationData.strings.RequestPeer_SelectionConfirmationTitle(peerName, botName).string, font: Font.semibold(strongSelf.presentationData.listsFontSize.baseDisplaySize), textColor: theme.primaryColor, paragraphAlignment: .center)
                        }
                    }
                }
                
                let controller = richTextAlertController(context: context, title: attributedTitle, text: attributedText, actions: [TextAlertAction(type: .genericAction, title: strongSelf.presentationData.strings.Common_Cancel, action: {}), TextAlertAction(type: .defaultAction, title: strongSelf.presentationData.strings.RequestPeer_SelectionConfirmationSend, action: {
                    completion()
                })])
                strongSelf.present(controller, in: .window(.root))
            }
            
            if case .user = peerType, maxQuantity > 1 {
                let presentationData = self.presentationData
                var reachedLimitImpl: ((Int32) -> Void)?
                let controller = context.sharedContext.makeContactMultiselectionController(ContactMultiselectionControllerParams(context: context, mode: .requestedUsersSelection, options: [], isPeerEnabled: { peer in
                    if case let .user(user) = peer, user.botInfo == nil {
                        return true
                    } else {
                        return false
                    }
                }, limit: maxQuantity, reachedLimit: { limit in
                    reachedLimitImpl?(limit)
                }))
                controller.navigationPresentation = .modal
                reachedLimitImpl = { [weak controller] limit in
                    guard let controller else {
                        return
                    }
                    HapticFeedback().error()
                    controller.present(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: presentationData.strings.RequestPeer_ReachedMaximum(limit), timeout: nil, customUndoText: nil), elevatedLayout: true, position: .bottom, animateInAsReplacement: false, action: { _ in return false }), in: .current)
                }
                
                let _ = (controller.result
                |> deliverOnMainQueue).startStandalone(next: { [weak controller] result in
                    guard let controller else {
                        return
                    }
                    var peerIds: [PeerId] = []
                    if case let .result(peerIdsValue, _) = result {
                        peerIds = peerIdsValue.compactMap({ peerId in
                            if case let .peer(peerId) = peerId {
                                return peerId
                            } else {
                                return nil
                            }
                        })
                    }
                    let _ = context.engine.peers.sendBotRequestedPeer(messageId: messageId, buttonId: buttonId, requestedPeerIds: peerIds).startStandalone()
                    controller.dismiss()
                })
                
                self.push(controller)
            } else {
                var createNewGroupImpl: (() -> Void)?
                let controller = self.context.sharedContext.makePeerSelectionController(PeerSelectionControllerParams(context: self.context, filter: [.excludeRecent, .doNotSearchMessages], requestPeerType: [peerType], hasContactSelector: false, createNewGroup: {
                    createNewGroupImpl?()
                }, hasCreation: true))
                   
                controller.peerSelected = { [weak self, weak controller] peer, _ in
                    guard let strongSelf = self else {
                        return
                    }
                    if case .user = peerType {
                        let _ = context.engine.peers.sendBotRequestedPeer(messageId: messageId, buttonId: buttonId, requestedPeerIds: [peer.id]).startStandalone()
                        controller?.dismiss()
                    } else {
                        var isChannel = false
                        if case let .channel(channel) = peer, case .broadcast = channel.info {
                            isChannel = true
                        }
                        let peerName = peer.displayTitle(strings: strongSelf.presentationData.strings, displayOrder: strongSelf.presentationData.nameDisplayOrder)
                        presentConfirmation(peerName, isChannel, {
                            let _ = context.engine.peers.sendBotRequestedPeer(messageId: messageId, buttonId: buttonId, requestedPeerIds: [peer.id]).startStandalone()
                            controller?.dismiss()
                        })
                    }
                }
                createNewGroupImpl = { [weak controller] in
                    switch peerType {
                    case .user:
                        break
                    case let .group(group):
                        let createGroupController = createGroupControllerImpl(context: context, peerIds: group.botParticipant || group.botAdminRights != nil ? (peerId.flatMap { [$0] } ?? []) : [], mode: .requestPeer(group), willComplete: { peerName, complete in
                            presentConfirmation(peerName, false, {
                                complete()
                            })
                        }, completion: { peerId, dismiss in
                            let _ = context.engine.peers.sendBotRequestedPeer(messageId: messageId, buttonId: buttonId, requestedPeerIds: [peerId]).startStandalone()
                            dismiss()
                        })
                        createGroupController.navigationPresentation = .modal
                        controller?.replace(with: createGroupController)
                    case let .channel(channel):
                        let createChannelController = createChannelController(context: context, mode: .requestPeer(channel), willComplete: { peerName, complete in
                            presentConfirmation(peerName, true, {
                                complete()
                            })
                        }, completion: { peerId, dismiss in
                            let _ = context.engine.peers.sendBotRequestedPeer(messageId: messageId, buttonId: buttonId, requestedPeerIds: [peerId]).startStandalone()
                            dismiss()
                        })
                        createChannelController.navigationPresentation = .modal
                        controller?.replace(with: createChannelController)
                    }
                }
                self.push(controller)
            }
        }, saveMediaToFiles: { [weak self] messageId in
            let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Messages.Message(id: messageId))
            |> deliverOnMainQueue).startStandalone(next: { message in
                guard let self, let message else {
                    return
                }
                var file: TelegramMediaFile?
                var title: String?
                var performer: String?
                for media in message.media {
                    if let mediaFile = media as? TelegramMediaFile, mediaFile.isMusic {
                        file = mediaFile
                        for attribute in mediaFile.attributes {
                            if case let .Audio(_, _, titleValue, performerValue, _) = attribute {
                                if let titleValue, !titleValue.isEmpty {
                                    title = titleValue
                                }
                                if let performerValue, !performerValue.isEmpty {
                                    performer = performerValue
                                }
                            }
                        }
                    }
                }
                guard let file else {
                    return
                }
                
                var signal = fetchMediaData(context: context, postbox: context.account.postbox, userLocation: .other, mediaReference: .message(message: MessageReference(message._asMessage()), media: file))
                
                let disposable: MetaDisposable
                if let current = self.saveMediaDisposable {
                    disposable = current
                } else {
                    disposable = MetaDisposable()
                    self.saveMediaDisposable = disposable
                }
                
                var cancelImpl: (() -> Void)?
                let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
                let progressSignal = Signal<Never, NoError> { [weak self] subscriber in
                    guard let self else {
                        return EmptyDisposable
                    }
                    let controller = OverlayStatusController(theme: presentationData.theme, type: .loading(cancelled: {
                        cancelImpl?()
                    }))
                    self.present(controller, in: .window(.root), with: ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
                    return ActionDisposable { [weak controller] in
                        Queue.mainQueue().async() {
                            controller?.dismiss()
                        }
                    }
                }
                |> runOn(Queue.mainQueue())
                |> delay(0.15, queue: Queue.mainQueue())
                let progressDisposable = progressSignal.startStrict()
                
                signal = signal
                |> afterDisposed {
                    Queue.mainQueue().async {
                        progressDisposable.dispose()
                    }
                }
                cancelImpl = { [weak disposable] in
                    disposable?.set(nil)
                }
                disposable.set((signal
                |> deliverOnMainQueue).startStrict(next: { [weak self] state, _ in
                    guard let self else {
                        return
                    }
                    switch state {
                    case .progress:
                        break
                    case let .data(data):
                        if data.complete {
                            var symlinkPath = data.path + ".mp3"
                            if fileSize(symlinkPath) != nil {
                                try? FileManager.default.removeItem(atPath: symlinkPath)
                            }
                            let _ = try? FileManager.default.linkItem(atPath: data.path, toPath: symlinkPath)
                            
                            let audioUrl = URL(fileURLWithPath: symlinkPath)
                            let audioAsset = AVURLAsset(url: audioUrl)
                            
                            var fileExtension = "mp3"
                            if let filename = file.fileName {
                                if let dotIndex = filename.lastIndex(of: ".") {
                                    fileExtension = String(filename[filename.index(after: dotIndex)...])
                                }
                            }
                            
                            var nameComponents: [String] = []
                            if let title {
                                if let performer {
                                    nameComponents.append(performer)
                                }
                                nameComponents.append(title)
                            } else {
                                var artist: String?
                                var title: String?
                                for data in audioAsset.commonMetadata {
                                    if data.commonKey == .commonKeyArtist {
                                        artist = data.stringValue
                                    }
                                    if data.commonKey == .commonKeyTitle {
                                        title = data.stringValue
                                    }
                                }
                                if let artist, !artist.isEmpty {
                                    nameComponents.append(artist)
                                }
                                if let title, !title.isEmpty {
                                    nameComponents.append(title)
                                }
                                if nameComponents.isEmpty, var filename = file.fileName {
                                    if let dotIndex = filename.lastIndex(of: ".") {
                                        filename = String(filename[..<dotIndex])
                                    }
                                    nameComponents.append(filename)
                                }
                            }
                            if !nameComponents.isEmpty {
                                try? FileManager.default.removeItem(atPath: symlinkPath)
                                
                                let fileName = "\(nameComponents.joined(separator: " – ")).\(fileExtension)"
                                symlinkPath = symlinkPath.replacingOccurrences(of: audioUrl.lastPathComponent, with: fileName)
                                let _ = try? FileManager.default.linkItem(atPath: data.path, toPath: symlinkPath)
                            }
                            
                            let url = URL(fileURLWithPath: symlinkPath)
                            let controller = legacyICloudFilePicker(theme: self.presentationData.theme, mode: .export, url: url, documentTypes: [], forceDarkTheme: false, dismissed: {}, completion: { _ in
                                
                            })
                            self.present(controller, in: .window(.root))
                        }
                    }
                }))
            })
        }, openNoAdsDemo: { [weak self] in
            guard let self else {
                return
            }
            var replaceImpl: ((ViewController) -> Void)?
            let controller = PremiumDemoScreen(context: self.context, subject: .noAds, action: {
                let controller = PremiumIntroScreen(context: self.context, source: .ads)
                replaceImpl?(controller)
            })
            replaceImpl = { [weak controller] c in
                controller?.replace(with: c)
            }
            self.push(controller)
        }, displayGiveawayParticipationStatus: { [weak self] messageId in
            guard let self else {
                return
            }
            let disposable: MetaDisposable
            if let current = self.giveawayStatusDisposable {
                disposable = current
            } else {
                disposable = MetaDisposable()
                self.giveawayStatusDisposable = disposable
            }
            disposable.set((self.context.engine.payments.premiumGiveawayInfo(peerId: messageId.peerId, messageId: messageId)
            |> deliverOnMainQueue).start(next: { [weak self] info in
                guard let self, let info else {
                    return
                }
                let content: UndoOverlayContent
                switch info {
                case let .ongoing(_, status):
                    switch status {
                    case .notAllowed:
                        content = .info(title: nil, text: self.presentationData.strings.Chat_Giveaway_Toast_NotAllowed, timeout: nil, customUndoText: self.presentationData.strings.Chat_Giveaway_Toast_LearnMore)
                    case .participating:
                        content = .succeed(text: self.presentationData.strings.Chat_Giveaway_Toast_Participating, timeout: nil, customUndoText: self.presentationData.strings.Chat_Giveaway_Toast_LearnMore)
                    case .notQualified:
                        content = .info(title: nil, text: self.presentationData.strings.Chat_Giveaway_Toast_NotQualified, timeout: nil, customUndoText: self.presentationData.strings.Chat_Giveaway_Toast_LearnMore)
                    case .almostOver:
                        content = .info(title: nil, text: self.presentationData.strings.Chat_Giveaway_Toast_AlmostOver, timeout: nil, customUndoText: self.presentationData.strings.Chat_Giveaway_Toast_LearnMore)
                    }
                    case .finished:
                        content = .info(title: nil, text: self.presentationData.strings.Chat_Giveaway_Toast_Ended, timeout: nil, customUndoText: self.presentationData.strings.Chat_Giveaway_Toast_LearnMore)
                }
                let controller = UndoOverlayController(presentationData: self.presentationData, content: content, elevatedLayout: false, position: .bottom, animateInAsReplacement: false, action: { [weak self] action in
                    if case .undo = action, let self {
                        self.displayGiveawayStatusInfo(messageId: messageId, giveawayInfo: info)
                        return true
                    }
                    return false
                })
                self.present(controller, in: .current)
                
            }))
        }, openPremiumStatusInfo: { [weak self] peerId, sourceView, peerStatus, nameColor in
            guard let self else {
                return
            }
            
            let context = self.context
            let source: Signal<PremiumSource, NoError>
            if let peerStatus {
                source = context.engine.stickers.resolveInlineStickers(fileIds: [peerStatus])
                |> mapToSignal { files in
                    if let file = files[peerStatus] {
                        var reference: StickerPackReference?
                        for attribute in file.attributes {
                            if case let .CustomEmoji(_, _, _, packReference) = attribute, let packReference = packReference {
                                reference = packReference
                                break
                            }
                        }
                        
                        if let reference {
                            return context.engine.stickers.loadedStickerPack(reference: reference, forceActualized: false)
                            |> filter { result in
                                if case .result = result {
                                    return true
                                } else {
                                    return false
                                }
                            }
                            |> take(1)
                            |> mapToSignal { result -> Signal<PremiumSource, NoError> in
                                if case let .result(_, items, _) = result {
                                    return .single(.emojiStatus(peerId, peerStatus, items.first?.file, result))
                                } else {
                                    return .single(.emojiStatus(peerId, peerStatus, nil, nil))
                                }
                            }
                        } else {
                            return .single(.emojiStatus(peerId, peerStatus, nil, nil))
                        }
                    } else {
                        return .single(.emojiStatus(peerId, peerStatus, nil, nil))
                    }
                }
            } else {
                source = .single(.profile(peerId))
            }
            
            let _ = (source
            |> deliverOnMainQueue).startStandalone(next: { [weak self] source in
                guard let self else {
                    return
                }
                let controller = PremiumIntroScreen(context: self.context, source: source)
                controller.sourceView = sourceView
                controller.containerView = self.navigationController?.view
                controller.animationColor = self.context.peerNameColors.get(nameColor, dark: self.presentationData.theme.overallDarkAppearance).main
                self.push(controller)
            })
            
        }, openRecommendedChannelContextMenu: { [weak self] peer, sourceView, gesture in
            guard let self else {
                return
            }
            
            let chatController = self.context.sharedContext.makeChatController(context: self.context, chatLocation: .peer(id: peer.id), subject: nil, botStart: nil, mode: .standard(.previewing))
            chatController.canReadHistory.set(false)
            
            var items: [ContextMenuItem] = [
                .action(ContextMenuActionItem(text: self.presentationData.strings.Conversation_LinkDialogOpen, icon: { theme in return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/ImageEnlarge"), color: theme.actionSheet.primaryTextColor) }, action: { [weak self] _, f in
                    f(.dismissWithoutContent)
                    self?.openPeer(peer: peer, navigation: .chat(textInputState: nil, subject: nil, peekData: nil), fromMessage: nil)
                })),
            ]
            items.append(.action(ContextMenuActionItem(text: self.presentationData.strings.Chat_SimilarChannels_Join, icon: { theme in return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Add"), color: theme.actionSheet.primaryTextColor) }, action: { [weak self] _, f in
                f(.dismissWithoutContent)
                
                guard let self else {
                    return
                }
                let presentationData = self.presentationData
                self.joinChannelDisposable.set((
                    self.context.peerChannelMemberCategoriesContextsManager.join(engine: self.context.engine, peerId: peer.id, hash: nil)
                    |> deliverOnMainQueue
                    |> afterCompleted { [weak self] in
                        Queue.mainQueue().async {
                            if let self {
                                self.present(UndoOverlayController(presentationData: presentationData, content: .succeed(text: presentationData.strings.Chat_SimilarChannels_JoinedChannel(peer.compactDisplayTitle).string, timeout: nil, customUndoText: nil), elevatedLayout: false, position: .top, animateInAsReplacement: false, action: { _ in return false }), in: .current)
                            }
                        }
                    }
                ).startStrict(error: { [weak self] error in
                    guard let self else {
                        return
                    }
                    let text: String
                    switch error {
                    case .inviteRequestSent:
                        self.present(UndoOverlayController(presentationData: presentationData, content: .inviteRequestSent(title: presentationData.strings.Group_RequestToJoinSent, text: presentationData.strings.Group_RequestToJoinSentDescriptionGroup), elevatedLayout: true, animateInAsReplacement: false, action: { _ in return false }), in: .window(.root))
                        return
                    case .tooMuchJoined:
                        self.push(oldChannelsController(context: context, intent: .join))
                        return
                    case .tooMuchUsers:
                        text = self.presentationData.strings.Conversation_UsersTooMuchError
                    case .generic:
                        text = self.presentationData.strings.Channel_ErrorAccessDenied
                    }
                    self.present(textAlertController(context: context, title: nil, text: text, actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]), in: .window(.root))
                }))
            })))
                      
            self.chatDisplayNode.messageTransitionNode.dismissMessageReactionContexts()
            
            self.canReadHistory.set(false)
            
            let contextController = ContextController(presentationData: self.presentationData, source: .controller(ChatContextControllerContentSourceImpl(controller: chatController, sourceView: sourceView, passthroughTouches: true)), items: .single(ContextController.Items(content: .list(items))), gesture: gesture)
            contextController.dismissed = { [weak self] in
                self?.canReadHistory.set(true)
            }
            self.presentInGlobalOverlay(contextController)
        }, openGroupBoostInfo: { [weak self] userId, count in
            guard let self, let peerId = self.chatLocation.peerId else {
                return
            }
            let _ = combineLatest(queue: Queue.mainQueue(),
                context.engine.peers.getChannelBoostStatus(peerId: peerId),
                context.engine.peers.getMyBoostStatus()
            ).startStandalone(next: { [weak self] boostStatus, myBoostStatus in
                guard let self, let boostStatus, let myBoostStatus else {
                    return
                }
                let boostController = PremiumBoostLevelsScreen(
                    context: self.context,
                    peerId: peerId,
                    mode: userId.flatMap { .user(mode: .groupPeer($0, count)) } ?? .user(mode: .current),
                    status: boostStatus,
                    myBoostStatus: myBoostStatus
                )
                self.push(boostController)
            })
        }, requestMessageUpdate: { [weak self] id, scroll in
            if let self {
                self.chatDisplayNode.historyNode.requestMessageUpdate(id, andScrollToItem: scroll)
            }
        }, cancelInteractiveKeyboardGestures: { [weak self] in
            if let self {
                (self.view.window as? WindowHost)?.cancelInteractiveKeyboardGestures()
                self.chatDisplayNode.cancelInteractiveKeyboardGestures()
            }
        }, dismissTextInput: { [weak self] in
            self?.chatDisplayNode.dismissTextInput()
        }, scrollToMessageId: { [weak self] index in
            self?.chatDisplayNode.historyNode.scrollToMessage(index: index)
        }, navigateToStory: { [weak self] message, storyId in
            guard let self else {
                return
            }
            if let story = message.associatedStories[storyId], story.data.isEmpty {
                self.present(UndoOverlayController(presentationData: self.presentationData, content:  .universal(animation: "story_expired", scale: 0.066, colors: [:], title: nil, text: self.presentationData.strings.Story_TooltipExpired, customUndoText: nil, timeout: nil), elevatedLayout: false, action: { _ in return true }), in: .current)
                return
            }
            
            let storyContent = SingleStoryContentContextImpl(context: self.context, storyId: storyId, readGlobally: true)
            let _ = (storyContent.state
            |> take(1)
            |> deliverOnMainQueue).startStandalone(next: { [weak self] _ in
                guard let self else {
                    return
                }
                
                var transitionIn: StoryContainerScreen.TransitionIn?
                for i in 0 ..< 2 {
                    if transitionIn != nil {
                        break
                    }
                    self.chatDisplayNode.historyNode.forEachItemNode { itemNode in
                        if let itemNode = itemNode as? ChatMessageItemView {
                            if i == 0 {
                                if itemNode.item?.message.id != message.id {
                                    return
                                }
                            }
                            
                            if let result = itemNode.targetForStoryTransition(id: storyId) {
                                transitionIn = StoryContainerScreen.TransitionIn(
                                    sourceView: result,
                                    sourceRect: result.bounds,
                                    sourceCornerRadius: 6.0,
                                    sourceIsAvatar: false
                                )
                            }
                        }
                    }
                }
                
                let storyContainerScreen = StoryContainerScreen(
                    context: self.context,
                    content: storyContent,
                    transitionIn: transitionIn,
                    transitionOut: { [weak self] peerId, storyIdValue in
                        guard let self, let storyIdId = storyIdValue.base as? Int32 else {
                            return nil
                        }
                        let storyId = StoryId(peerId: peerId, id: storyIdId)
                        
                        var transitionOut: StoryContainerScreen.TransitionOut?
                        for i in 0 ..< 2 {
                            if transitionOut != nil {
                                break
                            }
                            self.chatDisplayNode.historyNode.forEachItemNode { itemNode in
                                if let itemNode = itemNode as? ChatMessageItemView {
                                    if i == 0 {
                                        if itemNode.item?.message.id != message.id {
                                            return
                                        }
                                    }
                                    
                                    if let result = itemNode.targetForStoryTransition(id: storyId) {
                                        result.isHidden = true
                                        transitionOut = StoryContainerScreen.TransitionOut(
                                            destinationView: result,
                                            transitionView: StoryContainerScreen.TransitionView(
                                                makeView: { [weak result] in
                                                    let parentView = UIView()
                                                    if let copyView = result?.snapshotContentTree(unhide: true) {
                                                        parentView.addSubview(copyView)
                                                    }
                                                    return parentView
                                                },
                                                updateView: { copyView, state, transition in
                                                    guard let view = copyView.subviews.first else {
                                                        return
                                                    }
                                                    let size = state.sourceSize.interpolate(to: state.destinationSize, amount: state.progress)
                                                    transition.setPosition(view: view, position: CGPoint(x: size.width * 0.5, y: size.height * 0.5))
                                                    transition.setScale(view: view, scale: size.width / state.destinationSize.width)
                                                },
                                                insertCloneTransitionView: nil
                                            ),
                                            destinationRect: result.bounds,
                                            destinationCornerRadius: 2.0,
                                            destinationIsAvatar: false,
                                            completed: { [weak result] in
                                                result?.isHidden = false
                                            }
                                        )
                                    }
                                }
                            }
                        }
                        
                        return transitionOut
                    }
                )
                self.push(storyContainerScreen)
            })
        }, attemptedNavigationToPrivateQuote: { [weak self] peer in
            guard let self else {
                return
            }
            let text: String
            if let peer = peer as? TelegramChannel {
                if case .broadcast = peer.info {
                    text = self.presentationData.strings.Chat_ToastQuoteChatUnavailbalePrivateChannel
                } else {
                    text = self.presentationData.strings.Chat_ToastQuoteChatUnavailbalePrivateGroup
                }
            } else if peer is TelegramGroup {
                text = self.presentationData.strings.Chat_ToastQuoteChatUnavailbalePrivateGroup
            } else {
                text = self.presentationData.strings.Chat_ToastQuoteChatUnavailbalePrivateChat
            }
            self.controllerInteraction?.displayUndo(.info(title: nil, text: text, timeout: nil, customUndoText: nil))
        }, automaticMediaDownloadSettings: self.automaticMediaDownloadSettings, pollActionState: ChatInterfacePollActionState(), stickerSettings: self.stickerSettings, presentationContext: ChatPresentationContext(context: context, backgroundNode: self.chatBackgroundNode))
        controllerInteraction.enableFullTranslucency = context.sharedContext.energyUsageSettings.fullTranslucency
        
        self.controllerInteraction = controllerInteraction
        
        //if chatLocation.threadId == nil {
            if let peerId = chatLocation.peerId, peerId != context.account.peerId {
                switch subject {
                case .pinnedMessages, .scheduledMessages, .messageOptions:
                    break
                default:
                    self.navigationBar?.userInfo = PeerInfoNavigationSourceTag(peerId: peerId)
                }
            }
            self.navigationBar?.allowsCustomTransition = { [weak self] in
                guard let strongSelf = self else {
                    return false
                }
                if strongSelf.navigationBar?.userInfo == nil {
                    return false
                }
                if strongSelf.navigationBar?.contentNode != nil {
                    return false
                }
                return true
            }
        //}
        
        self.chatTitleView = ChatTitleView(context: self.context, theme: self.presentationData.theme, strings: self.presentationData.strings, dateTimeFormat: self.presentationData.dateTimeFormat, nameDisplayOrder: self.presentationData.nameDisplayOrder, animationCache: controllerInteraction.presentationContext.animationCache, animationRenderer: controllerInteraction.presentationContext.animationRenderer)
        
        if case .messageOptions = self.subject {
            self.chatTitleView?.disableAnimations = true
        }
        
        self.navigationItem.titleView = self.chatTitleView
        self.chatTitleView?.longPressed = { [weak self] in
            if let strongSelf = self, let peerView = strongSelf.peerView, let peer = peerView.peers[peerView.peerId], peer.restrictionText(platform: "ios", contentSettings: strongSelf.context.currentContentSettings.with { $0 }) == nil && !strongSelf.presentationInterfaceState.isNotAccessible {
                strongSelf.interfaceInteraction?.beginMessageSearch(.everything, "")
            }
        }
        
        let chatInfoButtonItem: UIBarButtonItem
        switch chatLocation {
        case .peer, .replyThread:
            let avatarNode = ChatAvatarNavigationNode()
            avatarNode.contextAction = { [weak self] node, gesture in
                guard let strongSelf = self, let peer = strongSelf.presentationInterfaceState.renderedPeer?.chatMainPeer, peer.smallProfileImage != nil else {
                    return
                }
                let galleryController = AvatarGalleryController(context: strongSelf.context, peer: EnginePeer(peer), remoteEntries: nil, replaceRootController: { controller, ready in
                }, synchronousLoad: true)
                galleryController.setHintWillBePresentedInPreviewingContext(true)
                
                let items: Signal<[ContextMenuItem], NoError> = context.engine.data.get(
                    TelegramEngine.EngineData.Item.Peer.CanViewStats(id: peer.id)
                )
                |> map { canViewStats -> [ContextMenuItem] in
                    var items: [ContextMenuItem] = [
                        .action(ContextMenuActionItem(text: strongSelf.presentationData.strings.Conversation_LinkDialogOpen, icon: { theme in
                            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Info"), color: theme.actionSheet.primaryTextColor)
                        }, action: { _, f in
                            f(.dismissWithoutContent)
                            self?.navigationButtonAction(.openChatInfo(expandAvatar: true, recommendedChannels: false))
                        }))
                    ]
                    if canViewStats {
                        items.append(.action(ContextMenuActionItem(text: strongSelf.presentationData.strings.ChannelInfo_Stats, icon: { theme in
                            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Statistics"), color: theme.actionSheet.primaryTextColor)
                        }, action: { _, f in
                            f(.dismissWithoutContent)
                            guard let strongSelf = self, let peer = strongSelf.presentationInterfaceState.renderedPeer?.chatMainPeer else {
                                return
                            }
                            strongSelf.view.endEditing(true)
                            
                            let statsController: ViewController
                            if let channel = peer as? TelegramChannel, case .group = channel.info {
                                statsController = groupStatsController(context: context, updatedPresentationData: strongSelf.updatedPresentationData, peerId: peer.id)
                            } else {
                                statsController = channelStatsController(context: context, updatedPresentationData: strongSelf.updatedPresentationData, peerId: peer.id)
                            }
                            strongSelf.push(statsController)
                        })))
                    }
                    items.append(.action(ContextMenuActionItem(text: strongSelf.presentationData.strings.Conversation_Search, icon: { theme in
                        return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Search"), color: theme.actionSheet.primaryTextColor)
                    }, action: { _, f in
                        f(.dismissWithoutContent)
                        self?.interfaceInteraction?.beginMessageSearch(.everything, "")
                    })))
                    return items
                }
                
                strongSelf.chatDisplayNode.messageTransitionNode.dismissMessageReactionContexts()
                
                strongSelf.canReadHistory.set(false)
                
                let contextController = ContextController(presentationData: strongSelf.presentationData, source: .controller(ChatContextControllerContentSourceImpl(controller: galleryController, sourceNode: node, passthroughTouches: false)), items: items |> map { ContextController.Items(content: .list($0)) }, gesture: gesture)
                contextController.dismissed = { [weak self] in
                    self?.canReadHistory.set(true)
                }
                strongSelf.presentInGlobalOverlay(contextController)
            }
            
            chatInfoButtonItem = UIBarButtonItem(customDisplayNode: avatarNode)!
            self.avatarNode = avatarNode
        case .feed:
            chatInfoButtonItem = UIBarButtonItem(title: "", style: .plain, target: nil, action: nil)
        }
        chatInfoButtonItem.target = self
        chatInfoButtonItem.action = #selector(self.rightNavigationButtonAction)
        self.chatInfoNavigationButton = ChatNavigationButton(action: .openChatInfo(expandAvatar: true, recommendedChannels: false), buttonItem: chatInfoButtonItem)
        
        self.moreBarButton.setContent(.more(MoreHeaderButton.optionsCircleImage(color: self.presentationData.theme.rootController.navigationBar.buttonColor)))
        self.moreInfoNavigationButton = ChatNavigationButton(action: .toggleInfoPanel, buttonItem: UIBarButtonItem(customDisplayNode: self.moreBarButton)!)
        self.moreBarButton.contextAction = { [weak self] sourceNode, gesture in
            guard let self = self else {
                return
            }
            guard case let .peer(peerId) = self.chatLocation else {
                return
            }
            ChatListControllerImpl.openMoreMenu(context: self.context, peerId: peerId, sourceController: self, isViewingAsTopics: false, sourceView: sourceNode.view, gesture: gesture)
        }
        self.moreBarButton.addTarget(self, action: #selector(self.moreButtonPressed), forControlEvents: .touchUpInside)
        
        self.navigationItem.titleView = self.chatTitleView
        self.chatTitleView?.pressed = { [weak self] in
            self?.navigationButtonAction(.openChatInfo(expandAvatar: false, recommendedChannels: false))
        }
        
        self.updateChatPresentationInterfaceState(animated: false, interactive: false, { state in
            if let botStart = botStart, case .interactive = botStart.behavior {
                return state.updatedBotStartPayload(botStart.payload)
            } else {
                return state
            }
        })
        
        let chatLocationPeerId: PeerId? = chatLocation.peerId
        
        self.accountPeerDisposable = (context.account.postbox.peerView(id: context.account.peerId)
        |> deliverOnMainQueue).startStrict(next: { [weak self] peerView in
            if let strongSelf = self {
                let isPremium = peerView.peers[peerView.peerId]?.isPremium ?? false
                strongSelf.updateChatPresentationInterfaceState(animated: false, interactive: false, { state in
                    return state.updatedIsPremium(isPremium)
                })
            }
        })
        
        if let chatPeerId = chatLocation.peerId {
            self.nameColorDisposable = (context.engine.data.subscribe(
                TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId),
                TelegramEngine.EngineData.Item.Peer.Peer(id: chatPeerId)
            )
            |> deliverOnMainQueue).start(next: { [weak self] accountPeer, chatPeer in
                guard let self, let accountPeer, let chatPeer else {
                    return
                }
                var nameColor: PeerNameColor?
                if case let .channel(channel) = chatPeer, case .broadcast = channel.info {
                    nameColor = chatPeer.nameColor
                } else {
                    nameColor = accountPeer.nameColor
                }
                var accountPeerColor: ChatPresentationInterfaceState.AccountPeerColor?
                if let nameColor {
                    let colors = self.context.peerNameColors.get(nameColor)
                    var style: ChatPresentationInterfaceState.AccountPeerColor.Style = .solid
                    if colors.tertiary != nil {
                        style = .tripleDashed
                    } else if colors.secondary != nil {
                        style = .doubleDashed
                    }
                    accountPeerColor = ChatPresentationInterfaceState.AccountPeerColor(style: style)
                }
                self.updateChatPresentationInterfaceState(animated: false, interactive: false, { state in
                    return state.updatedAccountPeerColor(accountPeerColor)
                })
            })
        }
        
        do {
            let peerId = chatLocationPeerId
            if case let .peer(peerView) = self.chatLocationInfoData, let peerId = peerId {
                peerView.set(context.account.viewTracker.peerView(peerId))
                var onlineMemberCount: Signal<Int32?, NoError> = .single(nil)
                var hasScheduledMessages: Signal<Bool, NoError> = .single(false)
                
                if peerId.namespace == Namespaces.Peer.CloudChannel {
                    let recentOnlineSignal: Signal<Int32?, NoError> = peerView.get()
                    |> map { view -> Bool? in
                        if let cachedData = view.cachedData as? CachedChannelData, let peer = peerViewMainPeer(view) as? TelegramChannel {
                            if case .broadcast = peer.info {
                                return nil
                            } else if let memberCount = cachedData.participantsSummary.memberCount, memberCount > 50 {
                                return true
                            } else {
                                return false
                            }
                        } else {
                            return false
                        }
                    }
                    |> distinctUntilChanged
                    |> mapToSignal { isLarge -> Signal<Int32?, NoError> in
                        if let isLarge = isLarge {
                            if isLarge {
                                return context.peerChannelMemberCategoriesContextsManager.recentOnline(account: context.account, accountPeerId: context.account.peerId, peerId: peerId)
                                |> map(Optional.init)
                            } else {
                                return context.peerChannelMemberCategoriesContextsManager.recentOnlineSmall(engine: context.engine, postbox: context.account.postbox, network: context.account.network, accountPeerId: context.account.peerId, peerId: peerId)
                                |> map(Optional.init)
                            }
                        } else {
                            return .single(nil)
                        }
                    }
                    onlineMemberCount = recentOnlineSignal
                    
                    self.reportIrrelvantGeoNoticePromise.set(context.engine.data.get(TelegramEngine.EngineData.Item.Notices.Notice(key: ApplicationSpecificNotice.irrelevantPeerGeoReportKey(peerId: peerId)))
                    |> map { entry -> Bool? in
                        if let _ = entry?.get(ApplicationSpecificBoolNotice.self) {
                            return true
                        } else {
                            return false
                        }
                    })
                } else {
                    self.reportIrrelvantGeoNoticePromise.set(.single(nil))
                }
                
                var isScheduledOrPinnedMessages = false
                switch subject {
                case .scheduledMessages, .pinnedMessages, .messageOptions:
                    isScheduledOrPinnedMessages = true
                default:
                    break
                }
                
                if chatLocation.peerId != nil, !isScheduledOrPinnedMessages, peerId.namespace != Namespaces.Peer.SecretChat {
                    let chatLocationContextHolder = self.chatLocationContextHolder
                    hasScheduledMessages = peerView.get()
                    |> take(1)
                    |> mapToSignal { view -> Signal<Bool, NoError> in
                        if let peer = peerViewMainPeer(view) as? TelegramChannel, !peer.hasPermission(.sendSomething) {
                            return .single(false)
                        } else {
                            return context.account.viewTracker.scheduledMessagesViewForLocation(context.chatLocationInput(for: chatLocation, contextHolder: chatLocationContextHolder))
                            |> map { view, _, _ in
                                return !view.entries.isEmpty
                            }
                        }
                    }
                }
                
                var displayedCountSignal: Signal<Int?, NoError> = .single(nil)
                var subtitleTextSignal: Signal<String?, NoError> = .single(nil)
                if case .pinnedMessages = subject {
                    displayedCountSignal = self.topPinnedMessageSignal(latest: true)
                    |> map { message -> Int? in
                        return message?.totalCount
                    }
                    |> distinctUntilChanged
                } else if case let .messageOptions(peerIds, messageIds, info) = subject {
                    displayedCountSignal = self.presentationInterfaceStatePromise.get()
                    |> map { state -> Int? in
                        if let selectionState = state.interfaceState.selectionState {
                            return selectionState.selectedIds.count
                        } else {
                            return messageIds.count
                        }
                    }
                    |> distinctUntilChanged
                    
                    let peers = self.context.account.postbox.multiplePeersView(peerIds)
                    |> take(1)
                    
                    let presentationData = self.presentationData
                    
                    switch info {
                    case let .forward(forward):
                        subtitleTextSignal = combineLatest(peers, forward.options, displayedCountSignal)
                        |> map { peersView, options, count in
                            let peers = peersView.peers.values
                            if !peers.isEmpty {
                                if peers.count == 1, let peer = peers.first {
                                    if let peer = peer as? TelegramUser {
                                        let displayName = EnginePeer(peer).compactDisplayTitle
                                        if count == 1 {
                                            if options.hideNames {
                                                return presentationData.strings.Conversation_ForwardOptions_UserMessageForwardHidden(displayName).string
                                            } else {
                                                return presentationData.strings.Conversation_ForwardOptions_UserMessageForwardVisible(displayName).string
                                            }
                                        } else {
                                            if options.hideNames {
                                                return presentationData.strings.Conversation_ForwardOptions_UserMessagesForwardHidden(displayName).string
                                            } else {
                                                return presentationData.strings.Conversation_ForwardOptions_UserMessagesForwardVisible(displayName).string
                                            }
                                        }
                                    } else if let peer = peer as? TelegramChannel, case .broadcast = peer.info {
                                        if count == 1 {
                                            if options.hideNames {
                                                return presentationData.strings.Conversation_ForwardOptions_ChannelMessageForwardHidden
                                            } else {
                                                return presentationData.strings.Conversation_ForwardOptions_ChannelMessageForwardVisible
                                            }
                                        } else {
                                            if options.hideNames {
                                                return presentationData.strings.Conversation_ForwardOptions_ChannelMessagesForwardHidden
                                            } else {
                                                return presentationData.strings.Conversation_ForwardOptions_ChannelMessagesForwardVisible
                                            }
                                        }
                                    } else {
                                        if count == 1 {
                                            if options.hideNames {
                                                return presentationData.strings.Conversation_ForwardOptions_GroupMessageForwardHidden
                                            } else {
                                                return presentationData.strings.Conversation_ForwardOptions_GroupMessageForwardVisible
                                            }
                                        } else {
                                            if options.hideNames {
                                                return presentationData.strings.Conversation_ForwardOptions_GroupMessagesForwardHidden
                                            } else {
                                                return presentationData.strings.Conversation_ForwardOptions_GroupMessagesForwardVisible
                                            }
                                        }
                                    }
                                } else {
                                    if count == 1 {
                                        if options.hideNames {
                                            return presentationData.strings.Conversation_ForwardOptions_RecipientsMessageForwardHidden
                                        } else {
                                            return presentationData.strings.Conversation_ForwardOptions_RecipientsMessageForwardVisible
                                        }
                                    } else {
                                        if options.hideNames {
                                            return presentationData.strings.Conversation_ForwardOptions_RecipientsMessagesForwardHidden
                                        } else {
                                            return presentationData.strings.Conversation_ForwardOptions_RecipientsMessagesForwardVisible
                                        }
                                    }
                                }
                            } else {
                                return nil
                            }
                        }
                    case let .reply(reply):
                        subtitleTextSignal = reply.selectionState.get()
                        |> map { selectionState -> String? in
                            if !selectionState.canQuote {
                                return nil
                            }
                            return presentationData.strings.Chat_SubtitleQuoteSelectionTip
                        }
                    case let .link(link):
                        subtitleTextSignal = link.options
                        |> map { options -> String? in
                            if options.hasAlternativeLinks {
                                return presentationData.strings.Chat_SubtitleLinkListTip
                            } else {
                                return nil
                            }
                        }
                        |> distinctUntilChanged
                    }
                }
                
                let hasPeerInfo: Signal<Bool, NoError>
                if peerId == context.account.peerId {
                    hasPeerInfo = .single(true)
                    |> then(
                        hasAvailablePeerInfoMediaPanes(context: context, peerId: peerId)
                    )
                } else {
                    hasPeerInfo = .single(true)
                }
                
                enum MessageOptionsTitleInfo {
                    case reply(hasQuote: Bool)
                }
                let messageOptionsTitleInfo: Signal<MessageOptionsTitleInfo?, NoError>
                if case let .messageOptions(_, _, info) = self.subject {
                    switch info {
                    case .forward, .link:
                        messageOptionsTitleInfo = .single(nil)
                    case let .reply(reply):
                        messageOptionsTitleInfo = reply.selectionState.get()
                        |> map { selectionState -> Bool in
                            return selectionState.quote != nil
                        }
                        |> distinctUntilChanged
                        |> map { hasQuote -> MessageOptionsTitleInfo in
                            return .reply(hasQuote: hasQuote)
                        }
                    }
                } else {
                    messageOptionsTitleInfo = .single(nil)
                }
                                  
                self.titleDisposable.set((combineLatest(queue: Queue.mainQueue(), peerView.get(), onlineMemberCount, displayedCountSignal, subtitleTextSignal, self.presentationInterfaceStatePromise.get(), hasPeerInfo, messageOptionsTitleInfo)
                |> deliverOnMainQueue).startStrict(next: { [weak self] peerView, onlineMemberCount, displayedCount, subtitleText, presentationInterfaceState, hasPeerInfo, messageOptionsTitleInfo in
                    if let strongSelf = self {
                        var isScheduledMessages = false
                        if case .scheduledMessages = presentationInterfaceState.subject {
                            isScheduledMessages = true
                        }
                        
                        if let peer = peerViewMainPeer(peerView) {
                            if case let .messageOptions(_, _, info) = presentationInterfaceState.subject {
                                if case .reply = info {
                                    let titleContent: ChatTitleContent
                                    if case let .reply(hasQuote) = messageOptionsTitleInfo, hasQuote {
                                        titleContent = .custom(presentationInterfaceState.strings.Chat_TitleQuoteSelection, subtitleText, false)
                                    } else {
                                        titleContent = .custom(presentationInterfaceState.strings.Chat_TitleReply, subtitleText, false)
                                    }
                                    if strongSelf.chatTitleView?.titleContent != titleContent {
                                        if strongSelf.chatTitleView?.titleContent != nil {
                                            strongSelf.chatTitleView?.animateLayoutTransition()
                                        }
                                        strongSelf.chatTitleView?.titleContent = titleContent
                                    }
                                } else if case .link = info {
                                    strongSelf.chatTitleView?.titleContent = .custom(presentationInterfaceState.strings.Chat_TitleLinkOptions, subtitleText, false)
                                } else if displayedCount == 1 {
                                    strongSelf.chatTitleView?.titleContent = .custom(presentationInterfaceState.strings.Conversation_ForwardOptions_ForwardTitleSingle, subtitleText, false)
                                } else {
                                    strongSelf.chatTitleView?.titleContent = .custom(presentationInterfaceState.strings.Conversation_ForwardOptions_ForwardTitle(Int32(displayedCount ?? 1)), subtitleText, false)
                                }
                            } else if let selectionState = presentationInterfaceState.interfaceState.selectionState {
                                if selectionState.selectedIds.count > 0 {
                                    strongSelf.chatTitleView?.titleContent = .custom(presentationInterfaceState.strings.Conversation_SelectedMessages(Int32(selectionState.selectedIds.count)), nil, false)
                                } else {
                                    if let reportReason = presentationInterfaceState.reportReason {
                                        let title: String
                                        switch reportReason {
                                            case .spam:
                                                title = presentationInterfaceState.strings.ReportPeer_ReasonSpam
                                            case .fake:
                                                title = presentationInterfaceState.strings.ReportPeer_ReasonFake
                                            case .violence:
                                                title = presentationInterfaceState.strings.ReportPeer_ReasonViolence
                                            case .porno:
                                                title = presentationInterfaceState.strings.ReportPeer_ReasonPornography
                                            case .childAbuse:
                                                title = presentationInterfaceState.strings.ReportPeer_ReasonChildAbuse
                                            case .copyright:
                                                title = presentationInterfaceState.strings.ReportPeer_ReasonCopyright
                                            case .illegalDrugs:
                                                title = presentationInterfaceState.strings.ReportPeer_ReasonIllegalDrugs
                                            case .personalDetails:
                                                title = presentationInterfaceState.strings.ReportPeer_ReasonPersonalDetails
                                            case .custom:
                                                title = presentationInterfaceState.strings.ReportPeer_ReasonOther
                                            case .irrelevantLocation:
                                                title = ""
                                        }
                                        strongSelf.chatTitleView?.titleContent = .custom(title, presentationInterfaceState.strings.Conversation_SelectMessages, false)
                                    } else {
                                        strongSelf.chatTitleView?.titleContent = .custom(presentationInterfaceState.strings.Conversation_SelectMessages, nil, false)
                                    }
                                }
                            } else {
                                if case .pinnedMessages = presentationInterfaceState.subject {
                                    strongSelf.chatTitleView?.titleContent = .custom(presentationInterfaceState.strings.Chat_TitlePinnedMessages(Int32(displayedCount ?? 1)), nil, false)
                                } else {
                                    strongSelf.chatTitleView?.titleContent = .peer(peerView: ChatTitleContent.PeerData(peerView: peerView), customTitle: nil, onlineMemberCount: onlineMemberCount, isScheduledMessages: isScheduledMessages, isMuted: nil, customMessageCount: nil, isEnabled: hasPeerInfo)
                                    let imageOverride: AvatarNodeImageOverride?
                                    if strongSelf.context.account.peerId == peer.id {
                                        imageOverride = .savedMessagesIcon
                                    } else if peer.id.isReplies {
                                        imageOverride = .repliesIcon
                                    } else if peer.id.isAnonymousSavedMessages {
                                        imageOverride = .anonymousSavedMessagesIcon
                                    } else if peer.isDeleted {
                                        imageOverride = .deletedIcon
                                    } else {
                                        imageOverride = nil
                                    }
                                    (strongSelf.chatInfoNavigationButton?.buttonItem.customDisplayNode as? ChatAvatarNavigationNode)?.setPeer(context: strongSelf.context, theme: strongSelf.presentationData.theme, peer: EnginePeer(peer), overrideImage: imageOverride)
                                    (strongSelf.chatInfoNavigationButton?.buttonItem.customDisplayNode as? ChatAvatarNavigationNode)?.contextActionIsEnabled = strongSelf.chatLocation.threadId == nil && peer.restrictionText(platform: "ios", contentSettings: strongSelf.context.currentContentSettings.with { $0 }) == nil
                                    strongSelf.chatInfoNavigationButton?.buttonItem.accessibilityLabel = presentationInterfaceState.strings.Conversation_ContextMenuOpenProfile
                                    
                                    strongSelf.storyStats = peerView.storyStats
                                    if let avatarNode = strongSelf.avatarNode {
                                        avatarNode.avatarNode.setStoryStats(storyStats: peerView.storyStats.flatMap { storyStats -> AvatarNode.StoryStats? in
                                            if storyStats.totalCount == 0 {
                                                return nil
                                            }
                                            if storyStats.unseenCount == 0 {
                                                return nil
                                            }
                                            return AvatarNode.StoryStats(
                                                totalCount: storyStats.totalCount,
                                                unseenCount: storyStats.unseenCount,
                                                hasUnseenCloseFriendsItems: storyStats.hasUnseenCloseFriends
                                            )
                                        }, presentationParams: AvatarNode.StoryPresentationParams(
                                            colors: AvatarNode.Colors(theme: strongSelf.presentationData.theme),
                                            lineWidth: 1.5,
                                            inactiveLineWidth: 1.5
                                        ), transition: .immediate)
                                    }
                                }
                            }
                        }
                    }
                }))
                
                let threadInfo: Signal<EngineMessageHistoryThread.Info?, NoError>
                if let threadId = self.chatLocation.threadId {
                    let viewKey: PostboxViewKey = .messageHistoryThreadInfo(peerId: peerId, threadId: threadId)
                    threadInfo = context.account.postbox.combinedView(keys: [viewKey])
                    |> map { views -> EngineMessageHistoryThread.Info? in
                        guard let view = views.views[viewKey] as? MessageHistoryThreadInfoView else {
                            return nil
                        }
                        guard let data = view.info?.data.get(MessageHistoryThreadData.self) else {
                            return nil
                        }
                        return data.info
                    }
                    |> distinctUntilChanged
                } else {
                    threadInfo = .single(nil)
                }
                
                let hasSearchTags: Signal<Bool, NoError>
                if let peerId = self.chatLocation.peerId, peerId == context.account.peerId {
                    hasSearchTags = context.engine.data.subscribe(
                        TelegramEngine.EngineData.Item.Messages.SavedMessageTagStats(peerId: context.account.peerId, threadId: self.chatLocation.threadId)
                    )
                    |> map { tags -> Bool in
                        return !tags.isEmpty
                    }
                    |> distinctUntilChanged
                } else {
                    hasSearchTags = .single(false)
                }
                
                let isPremiumRequiredForMessaging: Signal<Bool, NoError>
                if let peerId = self.chatLocation.peerId {
                    isPremiumRequiredForMessaging = context.engine.peers.subscribeIsPremiumRequiredForMessaging(id: peerId)
                    |> distinctUntilChanged
                } else {
                    isPremiumRequiredForMessaging = .single(false)
                }
                
                self.peerDisposable.set(combineLatest(
                    queue: Queue.mainQueue(),
                    peerView.get(),
                    context.engine.data.subscribe(TelegramEngine.EngineData.Item.NotificationSettings.Global()),
                    onlineMemberCount,
                    hasScheduledMessages,
                    self.reportIrrelvantGeoNoticePromise.get(),
                    displayedCountSignal,
                    threadInfo,
                    hasSearchTags,
                    isPremiumRequiredForMessaging
                ).startStrict(next: { [weak self] peerView, globalNotificationSettings, onlineMemberCount, hasScheduledMessages, peerReportNotice, pinnedCount, threadInfo, hasSearchTags, isPremiumRequiredForMessaging in
                    if let strongSelf = self {
                        if strongSelf.peerView === peerView && strongSelf.reportIrrelvantGeoNotice == peerReportNotice && strongSelf.hasScheduledMessages == hasScheduledMessages && strongSelf.threadInfo == threadInfo && strongSelf.presentationInterfaceState.hasSearchTags == hasSearchTags && strongSelf.presentationInterfaceState.isPremiumRequiredForMessaging == isPremiumRequiredForMessaging {
                            return
                        }
                        
                        strongSelf.reportIrrelvantGeoNotice = peerReportNotice
                        strongSelf.hasScheduledMessages = hasScheduledMessages
                        
                        var upgradedToPeerId: PeerId?
                        var movedToForumTopics = false
                        if let previous = strongSelf.peerView, let group = previous.peers[previous.peerId] as? TelegramGroup, group.migrationReference == nil, let updatedGroup = peerView.peers[peerView.peerId] as? TelegramGroup, let migrationReference = updatedGroup.migrationReference {
                            upgradedToPeerId = migrationReference.peerId
                        }
                        if let previous = strongSelf.peerView, let channel = previous.peers[previous.peerId] as? TelegramChannel, !channel.flags.contains(.isForum), let updatedChannel = peerView.peers[peerView.peerId] as? TelegramChannel, updatedChannel.flags.contains(.isForum) {
                            movedToForumTopics = true
                        }
                        
                        var shouldDismiss = false
                        if let previous = strongSelf.peerView, let group = previous.peers[previous.peerId] as? TelegramGroup, group.membership != .Removed, let updatedGroup = peerView.peers[peerView.peerId] as? TelegramGroup, updatedGroup.membership == .Removed {
                            shouldDismiss = true
                        } else if let previous = strongSelf.peerView, let channel = previous.peers[previous.peerId] as? TelegramChannel, channel.participationStatus != .kicked, let updatedChannel = peerView.peers[peerView.peerId] as? TelegramChannel, updatedChannel.participationStatus == .kicked {
                            shouldDismiss = true
                        } else if let previous = strongSelf.peerView, let secretChat = previous.peers[previous.peerId] as? TelegramSecretChat, case .active = secretChat.embeddedState, let updatedSecretChat = peerView.peers[peerView.peerId] as? TelegramSecretChat, case .terminated = updatedSecretChat.embeddedState {
                            shouldDismiss = true
                        }
                        
                        var wasGroupChannel: Bool?
                        if let previousPeerView = strongSelf.peerView, let info = (previousPeerView.peers[previousPeerView.peerId] as? TelegramChannel)?.info {
                            if case .group = info {
                                wasGroupChannel = true
                            } else {
                                wasGroupChannel = false
                            }
                        }
                        var isGroupChannel: Bool?
                        if let info = (peerView.peers[peerView.peerId] as? TelegramChannel)?.info {
                            if case .group = info {
                                isGroupChannel = true
                            } else {
                                isGroupChannel = false
                            }
                        }
                        let firstTime = strongSelf.peerView == nil
                        strongSelf.peerView = peerView
                        strongSelf.threadInfo = threadInfo
                        if wasGroupChannel != isGroupChannel {
                            if let isGroupChannel = isGroupChannel, isGroupChannel {
                                let (recentDisposable, _) = strongSelf.context.peerChannelMemberCategoriesContextsManager.recent(engine: strongSelf.context.engine, postbox: strongSelf.context.account.postbox, network: strongSelf.context.account.network, accountPeerId: context.account.peerId, peerId: peerView.peerId, updated: { _ in })
                                let (adminsDisposable, _) = strongSelf.context.peerChannelMemberCategoriesContextsManager.admins(engine: strongSelf.context.engine, postbox: strongSelf.context.account.postbox, network: strongSelf.context.account.network, accountPeerId: context.account.peerId, peerId: peerView.peerId, updated: { _ in })
                                let disposable = DisposableSet()
                                disposable.add(recentDisposable)
                                disposable.add(adminsDisposable)
                                strongSelf.chatAdditionalDataDisposable.set(disposable)
                            } else {
                                strongSelf.chatAdditionalDataDisposable.set(nil)
                            }
                        }
                        if strongSelf.isNodeLoaded {
                            strongSelf.chatDisplayNode.overlayTitle = strongSelf.overlayTitle
                        }
                        var peerIsMuted = false
                        if let notificationSettings = peerView.notificationSettings as? TelegramPeerNotificationSettings {
                            if case let .muted(until) = notificationSettings.muteState, until >= Int32(CFAbsoluteTimeGetCurrent() + NSTimeIntervalSince1970) {
                                peerIsMuted = true
                            } else if case .default = notificationSettings.muteState {
                                if let peer = peerView.peers[peerView.peerId] {
                                    if peer is TelegramUser {
                                        peerIsMuted = !globalNotificationSettings.privateChats.enabled
                                    } else if peer is TelegramGroup {
                                        peerIsMuted = !globalNotificationSettings.groupChats.enabled
                                    } else if let channel = peer as? TelegramChannel {
                                        switch channel.info {
                                        case .group:
                                            peerIsMuted = !globalNotificationSettings.groupChats.enabled
                                        case .broadcast:
                                            peerIsMuted = !globalNotificationSettings.channels.enabled
                                        }
                                    }
                                }
                            }
                        }
                        var peerDiscussionId: PeerId?
                        var peerGeoLocation: PeerGeoLocation?
                        if let peer = peerView.peers[peerView.peerId] as? TelegramChannel, let cachedData = peerView.cachedData as? CachedChannelData {
                            if case .broadcast = peer.info {
                                if case let .known(value) = cachedData.linkedDiscussionPeerId {
                                    peerDiscussionId = value
                                }
                            } else {
                                peerGeoLocation = cachedData.peerGeoLocation
                            }
                        }
                        var renderedPeer: RenderedPeer?
                        var contactStatus: ChatContactStatus?
                        if let peer = peerView.peers[peerView.peerId] {
                            if let cachedData = peerView.cachedData as? CachedUserData {
                                contactStatus = ChatContactStatus(canAddContact: !peerView.peerIsContact, canReportIrrelevantLocation: false, peerStatusSettings: cachedData.peerStatusSettings, invitedBy: nil)
                            } else if let cachedData = peerView.cachedData as? CachedGroupData {
                                var invitedBy: Peer?
                                if let invitedByPeerId = cachedData.invitedBy {
                                    if let peer = peerView.peers[invitedByPeerId] {
                                        invitedBy = peer
                                    }
                                }
                                contactStatus = ChatContactStatus(canAddContact: false, canReportIrrelevantLocation: false, peerStatusSettings: cachedData.peerStatusSettings, invitedBy: invitedBy)
                            } else if let cachedData = peerView.cachedData as? CachedChannelData {
                                var canReportIrrelevantLocation = true
                                if let peer = peerView.peers[peerView.peerId] as? TelegramChannel, peer.participationStatus == .member {
                                    canReportIrrelevantLocation = false
                                }
                                if let peerReportNotice = peerReportNotice, peerReportNotice {
                                    canReportIrrelevantLocation = false
                                }
                                var invitedBy: Peer?
                                if let invitedByPeerId = cachedData.invitedBy {
                                    if let peer = peerView.peers[invitedByPeerId] {
                                        invitedBy = peer
                                    }
                                }
                                contactStatus = ChatContactStatus(canAddContact: false, canReportIrrelevantLocation: canReportIrrelevantLocation, peerStatusSettings: cachedData.peerStatusSettings, invitedBy: invitedBy)
                            }
                            
                            var peers = SimpleDictionary<PeerId, Peer>()
                            peers[peer.id] = peer
                            if let associatedPeerId = peer.associatedPeerId, let associatedPeer = peerView.peers[associatedPeerId] {
                                peers[associatedPeer.id] = associatedPeer
                            }
                            renderedPeer = RenderedPeer(peerId: peer.id, peers: peers, associatedMedia: peerView.media)
                        }
                        
                        var isNotAccessible: Bool = false
                        if let cachedChannelData = peerView.cachedData as? CachedChannelData {
                            isNotAccessible = cachedChannelData.isNotAccessible
                        }
                        
                        if firstTime && isNotAccessible {
                            strongSelf.context.account.viewTracker.forceUpdateCachedPeerData(peerId: peerView.peerId)
                        }
                        
                        var hasBots: Bool = false
                        var hasBotCommands: Bool = false
                        var botMenuButton: BotMenuButton = .commands
                        var currentSendAsPeerId: PeerId?
                        var autoremoveTimeout: Int32?
                        var copyProtectionEnabled: Bool = false
                        if let peer = peerView.peers[peerView.peerId] {
                            copyProtectionEnabled = peer.isCopyProtectionEnabled
                            if let cachedGroupData = peerView.cachedData as? CachedGroupData {
                                if !cachedGroupData.botInfos.isEmpty {
                                    hasBots = true
                                }
                                let botCommands = cachedGroupData.botInfos.reduce(into: [], { result, info in
                                    result.append(contentsOf: info.botInfo.commands)
                                })
                                if !botCommands.isEmpty {
                                    hasBotCommands = true
                                }
                                if case let .known(value) = cachedGroupData.autoremoveTimeout {
                                    autoremoveTimeout = value?.effectiveValue
                                }
                            } else if let cachedChannelData = peerView.cachedData as? CachedChannelData {
                                currentSendAsPeerId = cachedChannelData.sendAsPeerId
                                if let channel = peer as? TelegramChannel, case .group = channel.info {
                                    if !cachedChannelData.botInfos.isEmpty {
                                        hasBots = true
                                    }
                                    let botCommands = cachedChannelData.botInfos.reduce(into: [], { result, info in
                                        result.append(contentsOf: info.botInfo.commands)
                                    })
                                    if !botCommands.isEmpty {
                                        hasBotCommands = true
                                    }
                                }
                                if case let .known(value) = cachedChannelData.autoremoveTimeout {
                                    autoremoveTimeout = value?.effectiveValue
                                }
                            } else if let cachedUserData = peerView.cachedData as? CachedUserData {
                                botMenuButton = cachedUserData.botInfo?.menuButton ?? .commands
                                if case let .known(value) = cachedUserData.autoremoveTimeout {
                                    autoremoveTimeout = value?.effectiveValue
                                }
                                if let botInfo = cachedUserData.botInfo, !botInfo.commands.isEmpty {
                                    hasBotCommands = true
                                }
                            }
                        }
                        
                        let isArchived: Bool = peerView.groupId == Namespaces.PeerGroup.archive
                        
                        var explicitelyCanPinMessages: Bool = false
                        if let cachedUserData = peerView.cachedData as? CachedUserData {
                            explicitelyCanPinMessages = cachedUserData.canPinMessages
                        } else if peerView.peerId == context.account.peerId {
                            explicitelyCanPinMessages = true
                        }
                                                
                        var animated = false
                        if let peer = strongSelf.presentationInterfaceState.renderedPeer?.peer as? TelegramSecretChat, let updated = renderedPeer?.peer as? TelegramSecretChat, peer.embeddedState != updated.embeddedState {
                            animated = true
                        }
                        if let peer = strongSelf.presentationInterfaceState.renderedPeer?.peer as? TelegramChannel, let updated = renderedPeer?.peer as? TelegramChannel {
                            if peer.participationStatus != updated.participationStatus {
                                animated = true
                            }
                        }
                        
                        var didDisplayActionsPanel = false
                        if let contactStatus = strongSelf.presentationInterfaceState.contactStatus, !contactStatus.isEmpty, let peerStatusSettings = contactStatus.peerStatusSettings {
                            if !peerStatusSettings.flags.isEmpty {
                                if contactStatus.canAddContact && peerStatusSettings.contains(.canAddContact) {
                                    didDisplayActionsPanel = true
                                } else if peerStatusSettings.contains(.canReport) || peerStatusSettings.contains(.canBlock) {
                                    didDisplayActionsPanel = true
                                } else if peerStatusSettings.contains(.canShareContact) {
                                    didDisplayActionsPanel = true
                                } else if contactStatus.canReportIrrelevantLocation && peerStatusSettings.contains(.canReportIrrelevantGeoLocation) {
                                    didDisplayActionsPanel = true
                                } else if peerStatusSettings.contains(.suggestAddMembers) {
                                    didDisplayActionsPanel = true
                                }
                            }
                        }
                        if strongSelf.presentationInterfaceState.search != nil && strongSelf.presentationInterfaceState.hasSearchTags {
                            didDisplayActionsPanel = true
                        }
                        
                        var displayActionsPanel = false
                        if let contactStatus = contactStatus, !contactStatus.isEmpty, let peerStatusSettings = contactStatus.peerStatusSettings {
                            if !peerStatusSettings.flags.isEmpty {
                                if contactStatus.canAddContact && peerStatusSettings.contains(.canAddContact) {
                                    displayActionsPanel = true
                                } else if peerStatusSettings.contains(.canReport) || peerStatusSettings.contains(.canBlock) {
                                    displayActionsPanel = true
                                } else if peerStatusSettings.contains(.canShareContact) {
                                    displayActionsPanel = true
                                } else if contactStatus.canReportIrrelevantLocation && peerStatusSettings.contains(.canReportIrrelevantGeoLocation) {
                                    displayActionsPanel = true
                                } else if peerStatusSettings.contains(.suggestAddMembers) {
                                    displayActionsPanel = true
                                }
                            }
                        }
                        if strongSelf.presentationInterfaceState.search != nil && hasSearchTags {
                            displayActionsPanel = true
                        }
                        
                        if displayActionsPanel != didDisplayActionsPanel {
                            animated = true
                        }
                        
                        if strongSelf.preloadHistoryPeerId != peerDiscussionId {
                            strongSelf.preloadHistoryPeerId = peerDiscussionId
                            if let peerDiscussionId = peerDiscussionId {
                                let combinedDisposable = DisposableSet()
                                strongSelf.preloadHistoryPeerIdDisposable.set(combinedDisposable)
                                combinedDisposable.add(strongSelf.context.account.viewTracker.polledChannel(peerId: peerDiscussionId).startStrict())
                                combinedDisposable.add(strongSelf.context.account.addAdditionalPreloadHistoryPeerId(peerId: peerDiscussionId))
                            } else {
                                strongSelf.preloadHistoryPeerIdDisposable.set(nil)
                            }
                        }
                        
                        strongSelf.updateChatPresentationInterfaceState(animated: animated, interactive: false, {
                            return $0.updatedPeer { _ in
                                return renderedPeer
                            }.updatedIsNotAccessible(isNotAccessible).updatedContactStatus(contactStatus).updatedHasBots(hasBots).updatedHasBotCommands(hasBotCommands).updatedBotMenuButton(botMenuButton).updatedIsArchived(isArchived).updatedPeerIsMuted(peerIsMuted).updatedPeerDiscussionId(peerDiscussionId).updatedPeerGeoLocation(peerGeoLocation).updatedExplicitelyCanPinMessages(explicitelyCanPinMessages).updatedHasScheduledMessages(hasScheduledMessages)
                                .updatedAutoremoveTimeout(autoremoveTimeout)
                                .updatedCurrentSendAsPeerId(currentSendAsPeerId)
                                .updatedCopyProtectionEnabled(copyProtectionEnabled)
                                .updatedHasSearchTags(hasSearchTags)
                                .updatedIsPremiumRequiredForMessaging(isPremiumRequiredForMessaging)
                                .updatedInterfaceState { interfaceState in
                                    var interfaceState = interfaceState
                                    
                                    if let channel = renderedPeer?.peer as? TelegramChannel {
                                        if channel.hasBannedPermission(.banSendVoice) != nil && channel.hasBannedPermission(.banSendInstantVideos) != nil {
                                            interfaceState = interfaceState.withUpdatedMediaRecordingMode(.audio)
                                        } else if channel.hasBannedPermission(.banSendVoice) != nil {
                                            if channel.hasBannedPermission(.banSendInstantVideos) == nil {
                                                interfaceState = interfaceState.withUpdatedMediaRecordingMode(.video)
                                            }
                                        } else if channel.hasBannedPermission(.banSendInstantVideos) != nil {
                                            if channel.hasBannedPermission(.banSendVoice) == nil {
                                                interfaceState = interfaceState.withUpdatedMediaRecordingMode(.audio)
                                            }
                                        }
                                    } else if let group = renderedPeer?.peer as? TelegramGroup {
                                        if group.hasBannedPermission(.banSendVoice) && group.hasBannedPermission(.banSendInstantVideos) {
                                            interfaceState = interfaceState.withUpdatedMediaRecordingMode(.audio)
                                        } else if group.hasBannedPermission(.banSendVoice) {
                                            if !group.hasBannedPermission(.banSendInstantVideos) {
                                                interfaceState = interfaceState.withUpdatedMediaRecordingMode(.video)
                                            }
                                        } else if group.hasBannedPermission(.banSendInstantVideos) {
                                            if !group.hasBannedPermission(.banSendVoice) {
                                                interfaceState = interfaceState.withUpdatedMediaRecordingMode(.audio)
                                            }
                                        }
                                    }
                                    
                                    return interfaceState
                                }
                        })

                        if case .standard(.default) = mode, let channel = renderedPeer?.chatMainPeer as? TelegramChannel, case .broadcast = channel.info {
                            var isRegularChat = false
                            if let subject = subject {
                                if case .message = subject {
                                    isRegularChat = true
                                }
                            } else {
                                isRegularChat = true
                            }
                            if isRegularChat, strongSelf.nextChannelToReadDisposable == nil {
                                //TODO:loc optimize
                                let accountPeerId = strongSelf.context.account.peerId
                                strongSelf.nextChannelToReadDisposable = (combineLatest(queue: .mainQueue(),
                                    strongSelf.context.engine.peers.getNextUnreadChannel(peerId: channel.id, chatListFilterId: strongSelf.currentChatListFilter, getFilterPredicate: { data in
                                    return chatListFilterPredicate(filter: data, accountPeerId: accountPeerId)
                                }),
                                    ApplicationSpecificNotice.getNextChatSuggestionTip(accountManager: strongSelf.context.sharedContext.accountManager)
                                )
                                |> then(.complete() |> delay(1.0, queue: .mainQueue()))
                                |> restart).startStrict(next: { nextPeer, nextChatSuggestionTip in
                                    guard let strongSelf = self else {
                                        return
                                    }

                                    strongSelf.offerNextChannelToRead = true
                                    strongSelf.chatDisplayNode.historyNode.nextChannelToRead = nextPeer.flatMap { nextPeer -> (peer: EnginePeer, unreadCount: Int, location: TelegramEngine.NextUnreadChannelLocation) in
                                        return (peer: nextPeer.peer, unreadCount: nextPeer.unreadCount, location: nextPeer.location)
                                    }
                                    strongSelf.chatDisplayNode.historyNode.nextChannelToReadDisplayName = nextChatSuggestionTip >= 3

                                    let nextPeerId = nextPeer?.peer.id

                                    if strongSelf.preloadNextChatPeerId != nextPeerId {
                                        strongSelf.preloadNextChatPeerId = nextPeerId
                                        if let nextPeerId = nextPeerId {
                                            let combinedDisposable = DisposableSet()
                                            strongSelf.preloadNextChatPeerIdDisposable.set(combinedDisposable)
                                            combinedDisposable.add(strongSelf.context.account.viewTracker.polledChannel(peerId: nextPeerId).startStrict())
                                            combinedDisposable.add(strongSelf.context.account.addAdditionalPreloadHistoryPeerId(peerId: nextPeerId))
                                        } else {
                                            strongSelf.preloadNextChatPeerIdDisposable.set(nil)
                                        }
                                    }
                                    
                                    strongSelf.updateNextChannelToReadVisibility()
                                })
                            }
                        }

                        if !strongSelf.didSetChatLocationInfoReady {
                            strongSelf.didSetChatLocationInfoReady = true
                            strongSelf._chatLocationInfoReady.set(.single(true))
                        }
                        strongSelf.updateReminderActivity()
                        if let upgradedToPeerId = upgradedToPeerId {
                            if let navigationController = strongSelf.effectiveNavigationController {
                                var viewControllers = navigationController.viewControllers
                                if let index = viewControllers.firstIndex(where: { $0 === strongSelf }) {
                                    viewControllers[index] = ChatControllerImpl(context: strongSelf.context, chatLocation: .peer(id: upgradedToPeerId))
                                    navigationController.setViewControllers(viewControllers, animated: false)
                                }
                            }
                        } else if movedToForumTopics {
                            if let navigationController = strongSelf.effectiveNavigationController {
                                let chatListController = strongSelf.context.sharedContext.makeChatListController(context: strongSelf.context, location: .forum(peerId: peerView.peerId), controlsHistoryPreload: false, hideNetworkActivityStatus: false, previewing: false, enableDebugActions: false)
                                navigationController.replaceController(strongSelf, with: chatListController, animated: true)
                            }
                        } else if shouldDismiss {
                            strongSelf.dismiss()
                        }
                    }
                }))
                
                if peerId == context.account.peerId {
                    self.preloadSavedMessagesChatsDisposable = context.engine.messages.savedMessagesPeerListHead().start()
                }
            } else if case let .replyThread(messagePromise) = self.chatLocationInfoData, let peerId = peerId {
                self.reportIrrelvantGeoNoticePromise.set(.single(nil))
                
                let replyThreadType: ChatTitleContent.ReplyThreadType
                var replyThreadId: Int64?
                switch chatLocation {
                case .peer:
                    replyThreadType = .replies
                case let .replyThread(replyThreadMessage):
                    if replyThreadMessage.peerId == context.account.peerId {
                        replyThreadId = replyThreadMessage.threadId
                        replyThreadType = .replies
                    } else {
                        replyThreadId = replyThreadMessage.threadId
                        if replyThreadMessage.isChannelPost {
                            replyThreadType = .comments
                        } else {
                            replyThreadType = .replies
                        }
                    }
                case .feed:
                    replyThreadType = .replies
                }
                
                let peerView = context.account.viewTracker.peerView(peerId)
                
                let messageAndTopic = messagePromise.get()
                |> mapToSignal { message -> Signal<(message: Message?, threadData: MessageHistoryThreadData?, messageCount: Int), NoError> in
                    guard let replyThreadId = replyThreadId else {
                        return .single((message, nil, 0))
                    }
                    let viewKey: PostboxViewKey = .messageHistoryThreadInfo(peerId: peerId, threadId: replyThreadId)
                    let countViewKey: PostboxViewKey = .historyTagSummaryView(tag: MessageTags(), peerId: peerId, threadId: replyThreadId, namespace: Namespaces.Message.Cloud, customTag: nil)
                    let localCountViewKey: PostboxViewKey = .historyTagSummaryView(tag: MessageTags(), peerId: peerId, threadId: replyThreadId, namespace: Namespaces.Message.Local, customTag: nil)
                    return context.account.postbox.combinedView(keys: [viewKey, countViewKey, localCountViewKey])
                    |> map { views -> (message: Message?, threadData: MessageHistoryThreadData?, messageCount: Int) in
                        guard let view = views.views[viewKey] as? MessageHistoryThreadInfoView else {
                            return (message, nil, 0)
                        }
                        var messageCount = 0
                        if let summaryView = views.views[countViewKey] as? MessageHistoryTagSummaryView, let count = summaryView.count {
                            if replyThreadId == 1 {
                                messageCount += Int(count)
                            } else {
                                messageCount += max(Int(count) - 1, 0)
                            }
                        }
                        if let summaryView = views.views[localCountViewKey] as? MessageHistoryTagSummaryView, let count = summaryView.count {
                            messageCount += Int(count)
                        }
                        return (message, view.info?.data.get(MessageHistoryThreadData.self), messageCount)
                    }
                }
                
                let savedMessagesPeerId: PeerId?
                if case let .replyThread(replyThreadMessage) = chatLocation, replyThreadMessage.peerId == context.account.peerId {
                    savedMessagesPeerId = PeerId(replyThreadMessage.threadId)
                } else {
                    savedMessagesPeerId = nil
                }
                
                let savedMessagesPeer: Signal<(peer: EnginePeer?, messageCount: Int)?, NoError>
                if let savedMessagesPeerId {
                    let threadPeerId = savedMessagesPeerId
                    let basicPeerKey: PostboxViewKey = .basicPeer(threadPeerId)
                    let countViewKey: PostboxViewKey = .historyTagSummaryView(tag: MessageTags(), peerId: peerId, threadId: savedMessagesPeerId.toInt64(), namespace: Namespaces.Message.Cloud, customTag: nil)
                    savedMessagesPeer = context.account.postbox.combinedView(keys: [basicPeerKey, countViewKey])
                    |> map { views -> (peer: EnginePeer?, messageCount: Int)? in
                        let peer = ((views.views[basicPeerKey] as? BasicPeerView)?.peer).flatMap(EnginePeer.init)
                        
                        var messageCount = 0
                        if let summaryView = views.views[countViewKey] as? MessageHistoryTagSummaryView, let count = summaryView.count {
                            messageCount += Int(count)
                        }
                        
                        return (peer, messageCount)
                    }
                } else {
                    savedMessagesPeer = .single(nil)
                }
                
                var isScheduledOrPinnedMessages = false
                switch subject {
                case .scheduledMessages, .pinnedMessages, .messageOptions:
                    isScheduledOrPinnedMessages = true
                default:
                    break
                }
                
                var hasScheduledMessages: Signal<Bool, NoError> = .single(false)
                if chatLocation.peerId != nil, !isScheduledOrPinnedMessages, peerId.namespace != Namespaces.Peer.SecretChat {
                    let chatLocationContextHolder = self.chatLocationContextHolder
                    hasScheduledMessages = peerView
                    |> take(1)
                    |> mapToSignal { view -> Signal<Bool, NoError> in
                        if let peer = peerViewMainPeer(view) as? TelegramChannel, !peer.hasPermission(.sendSomething) {
                            return .single(false)
                        } else {
                            return context.account.viewTracker.scheduledMessagesViewForLocation(context.chatLocationInput(for: chatLocation, contextHolder: chatLocationContextHolder))
                            |> map { view, _, _ in
                                return !view.entries.isEmpty
                            }
                        }
                    }
                }
                
                var onlineMemberCount: Signal<Int32?, NoError> = .single(nil)
                if peerId.namespace == Namespaces.Peer.CloudChannel {
                    let recentOnlineSignal: Signal<Int32?, NoError> = peerView
                    |> map { view -> Bool? in
                        if let cachedData = view.cachedData as? CachedChannelData, let peer = peerViewMainPeer(view) as? TelegramChannel {
                            if case .broadcast = peer.info {
                                return nil
                            } else if let memberCount = cachedData.participantsSummary.memberCount, memberCount > 50 {
                                return true
                            } else {
                                return false
                            }
                        } else {
                            return false
                        }
                    }
                    |> distinctUntilChanged
                    |> mapToSignal { isLarge -> Signal<Int32?, NoError> in
                        if let isLarge = isLarge {
                            if isLarge {
                                return context.peerChannelMemberCategoriesContextsManager.recentOnline(account: context.account, accountPeerId: context.account.peerId, peerId: peerId)
                                |> map(Optional.init)
                            } else {
                                return context.peerChannelMemberCategoriesContextsManager.recentOnlineSmall(engine: context.engine, postbox: context.account.postbox, network: context.account.network, accountPeerId: context.account.peerId, peerId: peerId)
                                |> map(Optional.init)
                            }
                        } else {
                            return .single(nil)
                        }
                    }
                    onlineMemberCount = recentOnlineSignal
                }
                
                let hasSearchTags: Signal<Bool, NoError>
                if let peerId = self.chatLocation.peerId, peerId == context.account.peerId {
                    hasSearchTags = context.engine.data.subscribe(
                        TelegramEngine.EngineData.Item.Messages.SavedMessageTagStats(peerId: context.account.peerId, threadId: self.chatLocation.threadId)
                    )
                    |> map { tags -> Bool in
                        return !tags.isEmpty
                    }
                    |> distinctUntilChanged
                } else {
                    hasSearchTags = .single(false)
                }
                
                let isPremiumRequiredForMessaging: Signal<Bool, NoError>
                if let peerId = self.chatLocation.peerId {
                    isPremiumRequiredForMessaging = context.engine.peers.subscribeIsPremiumRequiredForMessaging(id: peerId)
                    |> distinctUntilChanged
                } else {
                    isPremiumRequiredForMessaging = .single(false)
                }
                
                self.titleDisposable.set(nil)
                self.peerDisposable.set((combineLatest(queue: Queue.mainQueue(),
                    peerView,
                    messageAndTopic,
                    savedMessagesPeer,
                    onlineMemberCount,
                    hasScheduledMessages,
                    hasSearchTags,
                    isPremiumRequiredForMessaging
                )
                |> deliverOnMainQueue).startStrict(next: { [weak self] peerView, messageAndTopic, savedMessagesPeer, onlineMemberCount, hasScheduledMessages, hasSearchTags, isPremiumRequiredForMessaging in
                    if let strongSelf = self {
                        strongSelf.hasScheduledMessages = hasScheduledMessages
                        
                        var renderedPeer: RenderedPeer?
                        var contactStatus: ChatContactStatus?
                        var copyProtectionEnabled: Bool = false
                        if let peer = peerView.peers[peerView.peerId] {
                            copyProtectionEnabled = peer.isCopyProtectionEnabled
                            if let cachedData = peerView.cachedData as? CachedUserData {
                                contactStatus = ChatContactStatus(canAddContact: !peerView.peerIsContact, canReportIrrelevantLocation: false, peerStatusSettings: cachedData.peerStatusSettings, invitedBy: nil)
                            } else if let cachedData = peerView.cachedData as? CachedGroupData {
                                var invitedBy: Peer?
                                if let invitedByPeerId = cachedData.invitedBy {
                                    if let peer = peerView.peers[invitedByPeerId] {
                                        invitedBy = peer
                                    }
                                }
                                contactStatus = ChatContactStatus(canAddContact: false, canReportIrrelevantLocation: false, peerStatusSettings: cachedData.peerStatusSettings, invitedBy: invitedBy)
                            } else if let cachedData = peerView.cachedData as? CachedChannelData {
                                var canReportIrrelevantLocation = true
                                if let peer = peerView.peers[peerView.peerId] as? TelegramChannel, peer.participationStatus == .member {
                                    canReportIrrelevantLocation = false
                                }
                                canReportIrrelevantLocation = false
                                var invitedBy: Peer?
                                if let invitedByPeerId = cachedData.invitedBy {
                                    if let peer = peerView.peers[invitedByPeerId] {
                                        invitedBy = peer
                                    }
                                }
                                contactStatus = ChatContactStatus(canAddContact: false, canReportIrrelevantLocation: canReportIrrelevantLocation, peerStatusSettings: cachedData.peerStatusSettings, invitedBy: invitedBy)
                            }
                            
                            var peers = SimpleDictionary<PeerId, Peer>()
                            peers[peer.id] = peer
                            if let associatedPeerId = peer.associatedPeerId, let associatedPeer = peerView.peers[associatedPeerId] {
                                peers[associatedPeer.id] = associatedPeer
                            }
                            renderedPeer = RenderedPeer(peerId: peer.id, peers: peers, associatedMedia: peerView.media)
                        }
                        
                        if let savedMessagesPeerId {
                            let mappedPeerData = ChatTitleContent.PeerData(
                                peerId: savedMessagesPeerId,
                                peer: savedMessagesPeer?.peer?._asPeer(),
                                isContact: true,
                                isSavedMessages: true,
                                notificationSettings: nil,
                                peerPresences: [:],
                                cachedData: nil
                            )
                            strongSelf.chatTitleView?.titleContent = .peer(peerView: mappedPeerData, customTitle: nil, onlineMemberCount: nil, isScheduledMessages: false, isMuted: false, customMessageCount: savedMessagesPeer?.messageCount ?? 0, isEnabled: true)
                            
                            strongSelf.peerView = peerView
                            
                            let imageOverride: AvatarNodeImageOverride?
                            if strongSelf.context.account.peerId == savedMessagesPeerId {
                                imageOverride = .myNotesIcon
                            } else if savedMessagesPeerId.isReplies {
                                imageOverride = .repliesIcon
                            } else if savedMessagesPeerId.isAnonymousSavedMessages {
                                imageOverride = .anonymousSavedMessagesIcon
                            } else if let peer = savedMessagesPeer?.peer, peer.isDeleted {
                                imageOverride = .deletedIcon
                            } else {
                                imageOverride = nil
                            }
                            
                            if strongSelf.isNodeLoaded {
                                strongSelf.chatDisplayNode.overlayTitle = strongSelf.overlayTitle
                            }
                            
                            let animated = false
                            strongSelf.updateChatPresentationInterfaceState(animated: animated, interactive: false, {
                                return $0.updatedPeer { _ in
                                    return renderedPeer
                                }.updatedSavedMessagesTopicPeer(savedMessagesPeer?.peer)
                                .updatedHasSearchTags(hasSearchTags)
                            })
                            
                            (strongSelf.chatInfoNavigationButton?.buttonItem.customDisplayNode as? ChatAvatarNavigationNode)?.setPeer(context: strongSelf.context, theme: strongSelf.presentationData.theme, peer: savedMessagesPeer?.peer, overrideImage: imageOverride)
                            (strongSelf.chatInfoNavigationButton?.buttonItem.customDisplayNode as? ChatAvatarNavigationNode)?.contextActionIsEnabled = false
                            strongSelf.chatInfoNavigationButton?.buttonItem.accessibilityLabel = strongSelf.presentationData.strings.Conversation_ContextMenuOpenProfile
                        } else {
                            let message = messageAndTopic.message
                            
                            var count = 0
                            if let message = message {
                                for attribute in message.attributes {
                                    if let attribute = attribute as? ReplyThreadMessageAttribute {
                                        count = Int(attribute.count)
                                        break
                                    }
                                }
                            }
                            
                            var peerIsMuted = false
                            if let threadData = messageAndTopic.threadData {
                                if case let .muted(until) = threadData.notificationSettings.muteState, until >= Int32(CFAbsoluteTimeGetCurrent() + NSTimeIntervalSince1970) {
                                    peerIsMuted = true
                                }
                            } else if let notificationSettings = peerView.notificationSettings as? TelegramPeerNotificationSettings {
                                if case let .muted(until) = notificationSettings.muteState, until >= Int32(CFAbsoluteTimeGetCurrent() + NSTimeIntervalSince1970) {
                                    peerIsMuted = true
                                }
                            }
                            
                            if let threadInfo = messageAndTopic.threadData?.info {
                                strongSelf.chatTitleView?.titleContent = .peer(peerView: ChatTitleContent.PeerData(peerView: peerView), customTitle: threadInfo.title, onlineMemberCount: onlineMemberCount, isScheduledMessages: false, isMuted: peerIsMuted, customMessageCount: messageAndTopic.messageCount == 0 ? nil : messageAndTopic.messageCount, isEnabled: true)
                                
                                let avatarContent: EmojiStatusComponent.Content
                                if strongSelf.chatLocation.threadId == 1 {
                                    avatarContent = .image(image: PresentationResourcesChat.chatGeneralThreadIcon(strongSelf.presentationData.theme))
                                } else if let fileId = threadInfo.icon {
                                    avatarContent = .animation(content: .customEmoji(fileId: fileId), size: CGSize(width: 48.0, height: 48.0), placeholderColor: strongSelf.presentationData.theme.list.mediaPlaceholderColor, themeColor: strongSelf.presentationData.theme.list.itemAccentColor, loopMode: .count(1))
                                } else {
                                    avatarContent = .topic(title: String(threadInfo.title.prefix(1)), color: threadInfo.iconColor, size: CGSize(width: 32.0, height: 32.0))
                                }
                                (strongSelf.chatInfoNavigationButton?.buttonItem.customDisplayNode as? ChatAvatarNavigationNode)?.setStatus(context: strongSelf.context, content: avatarContent)
                            } else {
                                strongSelf.chatTitleView?.titleContent = .replyThread(type: replyThreadType, count: count)
                            }
                            
                            var wasGroupChannel: Bool?
                            if let previousPeerView = strongSelf.peerView, let info = (previousPeerView.peers[previousPeerView.peerId] as? TelegramChannel)?.info {
                                if case .group = info {
                                    wasGroupChannel = true
                                } else {
                                    wasGroupChannel = false
                                }
                            }
                            var isGroupChannel: Bool?
                            if let info = (peerView.peers[peerView.peerId] as? TelegramChannel)?.info {
                                if case .group = info {
                                    isGroupChannel = true
                                } else {
                                    isGroupChannel = false
                                }
                            }
                            let firstTime = strongSelf.peerView == nil
                            
                            if wasGroupChannel != isGroupChannel {
                                if let isGroupChannel = isGroupChannel, isGroupChannel {
                                    let (recentDisposable, _) = strongSelf.context.peerChannelMemberCategoriesContextsManager.recent(engine: strongSelf.context.engine, postbox: strongSelf.context.account.postbox, network: strongSelf.context.account.network, accountPeerId: context.account.peerId, peerId: peerView.peerId, updated: { _ in })
                                    let (adminsDisposable, _) = strongSelf.context.peerChannelMemberCategoriesContextsManager.admins(engine: strongSelf.context.engine, postbox: strongSelf.context.account.postbox, network: strongSelf.context.account.network, accountPeerId: context.account.peerId, peerId: peerView.peerId, updated: { _ in })
                                    let disposable = DisposableSet()
                                    disposable.add(recentDisposable)
                                    disposable.add(adminsDisposable)
                                    strongSelf.chatAdditionalDataDisposable.set(disposable)
                                } else {
                                    strongSelf.chatAdditionalDataDisposable.set(nil)
                                }
                            }
                            
                            strongSelf.peerView = peerView
                            strongSelf.threadInfo = messageAndTopic.threadData?.info
                            
                            if strongSelf.isNodeLoaded {
                                strongSelf.chatDisplayNode.overlayTitle = strongSelf.overlayTitle
                            }
                            
                            var peerDiscussionId: PeerId?
                            var peerGeoLocation: PeerGeoLocation?
                            var currentSendAsPeerId: PeerId?
                            if let peer = peerView.peers[peerView.peerId] as? TelegramChannel, let cachedData = peerView.cachedData as? CachedChannelData {
                                currentSendAsPeerId = cachedData.sendAsPeerId
                                if case .broadcast = peer.info {
                                    if case let .known(value) = cachedData.linkedDiscussionPeerId {
                                        peerDiscussionId = value
                                    }
                                } else {
                                    peerGeoLocation = cachedData.peerGeoLocation
                                }
                            }
                            
                            var isNotAccessible: Bool = false
                            if let cachedChannelData = peerView.cachedData as? CachedChannelData {
                                isNotAccessible = cachedChannelData.isNotAccessible
                            }
                            
                            if firstTime && isNotAccessible {
                                strongSelf.context.account.viewTracker.forceUpdateCachedPeerData(peerId: peerView.peerId)
                            }
                            
                            var hasBots: Bool = false
                            if let peer = peerView.peers[peerView.peerId] {
                                if let cachedGroupData = peerView.cachedData as? CachedGroupData {
                                    if !cachedGroupData.botInfos.isEmpty {
                                        hasBots = true
                                    }
                                } else if let cachedChannelData = peerView.cachedData as? CachedChannelData, let channel = peer as? TelegramChannel, case .group = channel.info {
                                    if !cachedChannelData.botInfos.isEmpty {
                                        hasBots = true
                                    }
                                }
                            }
                            
                            let isArchived: Bool = peerView.groupId == Namespaces.PeerGroup.archive
                            
                            var explicitelyCanPinMessages: Bool = false
                            if let cachedUserData = peerView.cachedData as? CachedUserData {
                                explicitelyCanPinMessages = cachedUserData.canPinMessages
                            } else if peerView.peerId == context.account.peerId {
                                explicitelyCanPinMessages = true
                            }
                            
                            var animated = false
                            if let peer = strongSelf.presentationInterfaceState.renderedPeer?.peer as? TelegramSecretChat, let updated = renderedPeer?.peer as? TelegramSecretChat, peer.embeddedState != updated.embeddedState {
                                animated = true
                            }
                            if let peer = strongSelf.presentationInterfaceState.renderedPeer?.peer as? TelegramChannel, let updated = renderedPeer?.peer as? TelegramChannel {
                                if peer.participationStatus != updated.participationStatus {
                                    animated = true
                                }
                            }
                            
                            var didDisplayActionsPanel = false
                            if let contactStatus = strongSelf.presentationInterfaceState.contactStatus, !contactStatus.isEmpty, let peerStatusSettings = contactStatus.peerStatusSettings {
                                if !peerStatusSettings.flags.isEmpty {
                                    if contactStatus.canAddContact && peerStatusSettings.contains(.canAddContact) {
                                        didDisplayActionsPanel = true
                                    } else if peerStatusSettings.contains(.canReport) || peerStatusSettings.contains(.canBlock) {
                                        didDisplayActionsPanel = true
                                    } else if peerStatusSettings.contains(.canShareContact) {
                                        didDisplayActionsPanel = true
                                    } else if contactStatus.canReportIrrelevantLocation && peerStatusSettings.contains(.canReportIrrelevantGeoLocation) {
                                        didDisplayActionsPanel = true
                                    } else if peerStatusSettings.contains(.suggestAddMembers) {
                                        didDisplayActionsPanel = true
                                    }
                                }
                            }
                            
                            var displayActionsPanel = false
                            if let contactStatus = contactStatus, !contactStatus.isEmpty, let peerStatusSettings = contactStatus.peerStatusSettings {
                                if !peerStatusSettings.flags.isEmpty {
                                    if contactStatus.canAddContact && peerStatusSettings.contains(.canAddContact) {
                                        displayActionsPanel = true
                                    } else if peerStatusSettings.contains(.canReport) || peerStatusSettings.contains(.canBlock) {
                                        displayActionsPanel = true
                                    } else if peerStatusSettings.contains(.canShareContact) {
                                        displayActionsPanel = true
                                    } else if contactStatus.canReportIrrelevantLocation && peerStatusSettings.contains(.canReportIrrelevantGeoLocation) {
                                        displayActionsPanel = true
                                    } else if peerStatusSettings.contains(.suggestAddMembers) {
                                        displayActionsPanel = true
                                    }
                                }
                            }
                            
                            if displayActionsPanel != didDisplayActionsPanel {
                                animated = true
                            }
                            
                            if strongSelf.preloadHistoryPeerId != peerDiscussionId {
                                strongSelf.preloadHistoryPeerId = peerDiscussionId
                                if let peerDiscussionId = peerDiscussionId {
                                    strongSelf.preloadHistoryPeerIdDisposable.set(strongSelf.context.account.addAdditionalPreloadHistoryPeerId(peerId: peerDiscussionId))
                                } else {
                                    strongSelf.preloadHistoryPeerIdDisposable.set(nil)
                                }
                            }
                            
                            strongSelf.updateChatPresentationInterfaceState(animated: animated, interactive: false, {
                                return $0.updatedPeer { _ in
                                    return renderedPeer
                                }.updatedIsNotAccessible(isNotAccessible).updatedContactStatus(contactStatus).updatedHasBots(hasBots).updatedIsArchived(isArchived).updatedPeerIsMuted(peerIsMuted).updatedPeerDiscussionId(peerDiscussionId).updatedPeerGeoLocation(peerGeoLocation).updatedExplicitelyCanPinMessages(explicitelyCanPinMessages).updatedHasScheduledMessages(hasScheduledMessages).updatedCurrentSendAsPeerId(currentSendAsPeerId)
                                    .updatedCopyProtectionEnabled(copyProtectionEnabled)
                                    .updatedHasSearchTags(hasSearchTags)
                                    .updatedIsPremiumRequiredForMessaging(isPremiumRequiredForMessaging)
                                    .updatedInterfaceState { interfaceState in
                                        var interfaceState = interfaceState
                                        
                                        if let channel = renderedPeer?.peer as? TelegramChannel {
                                            if channel.hasBannedPermission(.banSendVoice) != nil && channel.hasBannedPermission(.banSendInstantVideos) != nil {
                                                interfaceState = interfaceState.withUpdatedMediaRecordingMode(.audio)
                                            } else if channel.hasBannedPermission(.banSendVoice) != nil {
                                                if channel.hasBannedPermission(.banSendInstantVideos) == nil {
                                                    interfaceState = interfaceState.withUpdatedMediaRecordingMode(.video)
                                                }
                                            } else if channel.hasBannedPermission(.banSendInstantVideos) != nil {
                                                if channel.hasBannedPermission(.banSendVoice) == nil {
                                                    interfaceState = interfaceState.withUpdatedMediaRecordingMode(.audio)
                                                }
                                            }
                                        } else if let group = renderedPeer?.peer as? TelegramGroup {
                                            if group.hasBannedPermission(.banSendVoice) && group.hasBannedPermission(.banSendInstantVideos) {
                                                interfaceState = interfaceState.withUpdatedMediaRecordingMode(.audio)
                                            } else if group.hasBannedPermission(.banSendVoice) {
                                                if !group.hasBannedPermission(.banSendInstantVideos) {
                                                    interfaceState = interfaceState.withUpdatedMediaRecordingMode(.video)
                                                }
                                            } else if group.hasBannedPermission(.banSendInstantVideos) {
                                                if !group.hasBannedPermission(.banSendVoice) {
                                                    interfaceState = interfaceState.withUpdatedMediaRecordingMode(.audio)
                                                }
                                            }
                                        }
                                        
                                        return interfaceState
                                    }
                            })
                        }
                        if !strongSelf.didSetChatLocationInfoReady {
                            strongSelf.didSetChatLocationInfoReady = true
                            strongSelf._chatLocationInfoReady.set(.single(true))
                        }
                    }
                }))
            } else if case .feed = self.chatLocationInfoData {
                self.reportIrrelvantGeoNoticePromise.set(.single(nil))
                self.titleDisposable.set(nil)
                
                self.chatTitleView?.titleContent = .custom("Feed", nil, false)
                
                if !self.didSetChatLocationInfoReady {
                    self.didSetChatLocationInfoReady = true
                    self._chatLocationInfoReady.set(.single(true))
                }
            }
        }
        
        self.botCallbackAlertMessageDisposable = (self.botCallbackAlertMessage.get()
        |> deliverOnMainQueue).startStrict(next: { [weak self] message in
                if let strongSelf = self {
                    strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: false, {
                        return $0.updatedTitlePanelContext {
                            if let message = message {
                                if let index = $0.firstIndex(where: {
                                    switch $0 {
                                        case .toastAlert:
                                            return true
                                        default:
                                            return false
                                    }
                                }) {
                                    if $0[index] != ChatTitlePanelContext.toastAlert(message) {
                                        var updatedContexts = $0
                                        updatedContexts[index] = .toastAlert(message)
                                        return updatedContexts
                                    } else {
                                        return $0
                                    }
                                } else {
                                    var updatedContexts = $0
                                    updatedContexts.append(.toastAlert(message))
                                    return updatedContexts.sorted()
                                }
                            } else {
                                if let index = $0.firstIndex(where: {
                                    switch $0 {
                                        case .toastAlert:
                                            return true
                                        default:
                                            return false
                                    }
                                }) {
                                    var updatedContexts = $0
                                    updatedContexts.remove(at: index)
                                    return updatedContexts
                                } else {
                                    return $0
                                }
                            }
                        }
                    })
                }
            })
        
        self.audioRecorderDisposable = (self.audioRecorder.get()
        |> deliverOnMainQueue).startStrict(next: { [weak self] audioRecorder in
            if let strongSelf = self {
                if strongSelf.audioRecorderValue !== audioRecorder {
                    strongSelf.audioRecorderValue = audioRecorder
                    strongSelf.lockOrientation = audioRecorder != nil
                    
                    strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, {
                        $0.updatedInputTextPanelState { panelState in
                            let isLocked = strongSelf.lockMediaRecordingRequestId == strongSelf.beginMediaRecordingRequestId
                            if let audioRecorder = audioRecorder {
                                if panelState.mediaRecordingState == nil {
                                    return panelState.withUpdatedMediaRecordingState(.audio(recorder: audioRecorder, isLocked: isLocked))
                                }
                            } else {
                                if case .waitingForPreview = panelState.mediaRecordingState {
                                    return panelState
                                }
                                return panelState.withUpdatedMediaRecordingState(nil)
                            }
                            return panelState
                        }
                    })
                    strongSelf.audioRecorderStatusDisposable?.dispose()
                    
                    if let audioRecorder = audioRecorder {
                        if !audioRecorder.beginWithTone {
                            strongSelf.recorderFeedback?.impact(.light)
                        }
                        audioRecorder.start()
                        strongSelf.audioRecorderStatusDisposable = (audioRecorder.recordingState
                        |> deliverOnMainQueue).startStrict(next: { value in
                            if case .stopped = value {
                                self?.stopMediaRecorder()
                            }
                        })
                    } else {
                        strongSelf.audioRecorderStatusDisposable = nil
                    }
                    strongSelf.updateDownButtonVisibility()
                }
            }
        })
        
        self.videoRecorderDisposable = (self.videoRecorder.get()
        |> deliverOnMainQueue).startStrict(next: { [weak self] videoRecorder in
            if let strongSelf = self {
                if strongSelf.videoRecorderValue !== videoRecorder {
                    let previousVideoRecorderValue = strongSelf.videoRecorderValue
                    strongSelf.videoRecorderValue = videoRecorder
                    
                    strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, {
                        $0.updatedInputTextPanelState { panelState in
                            if let videoRecorder = videoRecorder {
                                if panelState.mediaRecordingState == nil {
                                    let recordingStatus = videoRecorder.recordingStatus
                                    return panelState.withUpdatedMediaRecordingState(.video(status: .recording(InstantVideoControllerRecordingStatus(micLevel: recordingStatus.micLevel, duration: recordingStatus.duration)), isLocked: strongSelf.lockMediaRecordingRequestId == strongSelf.beginMediaRecordingRequestId))
                                }
                            } else {
                                return panelState.withUpdatedMediaRecordingState(nil)
                            }
                            return panelState
                        }
                    })
                    
                    if let videoRecorder = videoRecorder {
                        strongSelf.recorderFeedback?.impact(.light)
                        
                        videoRecorder.onStop = {
                            if let strongSelf = self {
                                strongSelf.dismissMediaRecorder(.pause)
                            }
                        }
                        strongSelf.present(videoRecorder, in: .window(.root))
                        
                        if strongSelf.lockMediaRecordingRequestId == strongSelf.beginMediaRecordingRequestId {
                            videoRecorder.lockVideoRecording()
                        }
                    }
                    strongSelf.updateDownButtonVisibility()
                    
                    if let previousVideoRecorderValue = previousVideoRecorderValue {
                        previousVideoRecorderValue.discardVideo()
                    }
                }
            }
        })
        
        if let botStart = botStart, case .automatic = botStart.behavior {
            self.startBot(botStart.payload)
        }
        
        let activitySpace: PeerActivitySpace?
        switch self.chatLocation {
        case let .peer(peerId):
            activitySpace = PeerActivitySpace(peerId: peerId, category: .global)
        case let .replyThread(replyThreadMessage):
            activitySpace = PeerActivitySpace(peerId: replyThreadMessage.peerId, category: .thread(replyThreadMessage.threadId))
        case .feed:
            activitySpace = nil
        }
        
        if let activitySpace = activitySpace {
            self.inputActivityDisposable = (self.typingActivityPromise.get()
            |> deliverOnMainQueue).startStrict(next: { [weak self] value in
                if let strongSelf = self, strongSelf.presentationInterfaceState.interfaceState.editMessage == nil && strongSelf.presentationInterfaceState.subject != .scheduledMessages && strongSelf.presentationInterfaceState.currentSendAsPeerId == nil {
                    strongSelf.context.account.updateLocalInputActivity(peerId: activitySpace, activity: .typingText, isPresent: value)
                }
            })
        
            self.choosingStickerActivityDisposable = (self.choosingStickerActivityPromise.get()
            |> mapToSignal { value -> Signal<Bool, NoError> in
                if value {
                    return .single(true)
                } else {
                    return .single(false) |> delay(2.0, queue: Queue.mainQueue())
                }
            }
            |> deliverOnMainQueue).startStrict(next: { [weak self] value in
                if let strongSelf = self, strongSelf.presentationInterfaceState.interfaceState.editMessage == nil && strongSelf.presentationInterfaceState.subject != .scheduledMessages && strongSelf.presentationInterfaceState.currentSendAsPeerId == nil {
                    if value {
                        strongSelf.context.account.updateLocalInputActivity(peerId: activitySpace, activity: .typingText, isPresent: false)
                    }
                    strongSelf.context.account.updateLocalInputActivity(peerId: activitySpace, activity: .choosingSticker, isPresent: value)
                }
            })
            
            self.recordingActivityDisposable = (self.recordingActivityPromise.get()
            |> deliverOnMainQueue).startStrict(next: { [weak self] value in
                if let strongSelf = self, strongSelf.presentationInterfaceState.interfaceState.editMessage == nil && strongSelf.presentationInterfaceState.subject != .scheduledMessages && strongSelf.presentationInterfaceState.currentSendAsPeerId == nil {
                    strongSelf.acquiredRecordingActivityDisposable?.dispose()
                    switch value {
                        case .voice:
                            strongSelf.acquiredRecordingActivityDisposable = strongSelf.context.account.acquireLocalInputActivity(peerId: activitySpace, activity: .recordingVoice)
                        case .instantVideo:
                            strongSelf.acquiredRecordingActivityDisposable = strongSelf.context.account.acquireLocalInputActivity(peerId: activitySpace, activity: .recordingInstantVideo)
                        case .none:
                            strongSelf.acquiredRecordingActivityDisposable = nil
                    }
                }
            })
        }
        
        let themeEmoticon: Signal<String?, NoError> = self.chatThemeEmoticonPromise.get()
        |> distinctUntilChanged
    
        let uploadingChatWallpaper: Signal<TelegramWallpaper?, NoError>
        if let peerId = self.chatLocation.peerId {
            uploadingChatWallpaper = self.context.account.pendingPeerMediaUploadManager.uploadingPeerMedia
            |> map { uploadingPeerMedia -> TelegramWallpaper? in
                if let item = uploadingPeerMedia[peerId], case let .wallpaper(wallpaper, _) = item.content {
                    return wallpaper
                } else {
                    return nil
                }
            }
            |> distinctUntilChanged
        } else {
            uploadingChatWallpaper = .single(nil)
        }
        
        let chatWallpaper: Signal<TelegramWallpaper?, NoError> = combineLatest(self.chatWallpaperPromise.get(), uploadingChatWallpaper)
        |> map { chatWallpaper, uploadingChatWallpaper in
            return uploadingChatWallpaper ?? chatWallpaper
        }
        |> distinctUntilChanged
        
        let themeSettings = context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.presentationThemeSettings])
        |> map { sharedData -> PresentationThemeSettings in
            let themeSettings: PresentationThemeSettings
            if let current = sharedData.entries[ApplicationSpecificSharedDataKeys.presentationThemeSettings]?.get(PresentationThemeSettings.self) {
                themeSettings = current
            } else {
                themeSettings = PresentationThemeSettings.defaultSettings
            }
            return themeSettings
        }
        
        let accountManager = context.sharedContext.accountManager
        let currentThemeEmoticon = Atomic<(String?, Bool)?>(value: nil)
        self.presentationDataDisposable = combineLatest(
            queue: Queue.mainQueue(),
            context.sharedContext.presentationData,
            themeSettings,
            context.engine.themes.getChatThemes(accountManager: accountManager, onlyCached: true),
            themeEmoticon,
            self.themeEmoticonAndDarkAppearancePreviewPromise.get(),
            chatWallpaper
        ).startStrict(next: { [weak self] presentationData, themeSettings, chatThemes, themeEmoticon, themeEmoticonAndDarkAppearance, chatWallpaper in
            if let strongSelf = self {
                let (themeEmoticonPreview, darkAppearancePreview) = themeEmoticonAndDarkAppearance
                
                var chatWallpaper = chatWallpaper
                
                let previousTheme = strongSelf.presentationData.theme
                let previousStrings = strongSelf.presentationData.strings
                let previousChatWallpaper = strongSelf.presentationData.chatWallpaper
                
                var themeEmoticon = themeEmoticon
                if let themeEmoticonPreview = themeEmoticonPreview {
                    if !themeEmoticonPreview.isEmpty {
                        if themeEmoticon?.strippedEmoji != themeEmoticonPreview.strippedEmoji {
                            chatWallpaper = nil
                            themeEmoticon = themeEmoticonPreview
                        }
                    } else {
                        themeEmoticon = nil
                    }
                }
                if strongSelf.chatLocation.peerId == strongSelf.context.account.peerId {
                    themeEmoticon = nil
                }
                                
                var presentationData = presentationData
                var useDarkAppearance = presentationData.theme.overallDarkAppearance

                if let wallpaper = chatWallpaper, case let .emoticon(wallpaperEmoticon) = wallpaper, let theme = chatThemes.first(where: { $0.emoticon?.strippedEmoji == wallpaperEmoticon.strippedEmoji }) {
                    let themeSettings: TelegramThemeSettings?
                    if let matching = theme.settings?.first(where: { $0.baseTheme == presentationData.theme.referenceTheme.baseTheme }) {
                        themeSettings = matching
                    } else {
                        themeSettings = theme.settings?.first
                    }
                    if let themeWallpaper = themeSettings?.wallpaper {
                        chatWallpaper = themeWallpaper
                    }
                }
                if let themeEmoticon = themeEmoticon, let theme = chatThemes.first(where: { $0.emoticon?.strippedEmoji == themeEmoticon.strippedEmoji }) {
                    if let darkAppearancePreview = darkAppearancePreview {
                        useDarkAppearance = darkAppearancePreview
                    }
                    if let theme = makePresentationTheme(cloudTheme: theme, dark: useDarkAppearance) {
                        theme.forceSync = true
                        presentationData = presentationData.withUpdated(theme: theme).withUpdated(chatWallpaper: theme.chat.defaultWallpaper)
                        
                        Queue.mainQueue().after(1.0, {
                            theme.forceSync = false
                        })
                    }
                } else if let darkAppearancePreview = darkAppearancePreview {
                    useDarkAppearance = darkAppearancePreview
                    let lightTheme: PresentationTheme
                    let lightWallpaper: TelegramWallpaper
                    
                    let darkTheme: PresentationTheme
                    let darkWallpaper: TelegramWallpaper
                    
                    if presentationData.autoNightModeTriggered {
                        darkTheme = presentationData.theme
                        darkWallpaper = presentationData.chatWallpaper
                        
                        var currentColors = themeSettings.themeSpecificAccentColors[themeSettings.theme.index]
                        if let colors = currentColors, colors.baseColor == .theme {
                            currentColors = nil
                        }
                        
                        let themeSpecificWallpaper = (themeSettings.themeSpecificChatWallpapers[coloredThemeIndex(reference: themeSettings.theme, accentColor: currentColors)] ?? themeSettings.themeSpecificChatWallpapers[themeSettings.theme.index])
                        
                        if let themeSpecificWallpaper = themeSpecificWallpaper {
                            lightWallpaper = themeSpecificWallpaper
                        } else {
                            let theme = makePresentationTheme(mediaBox: accountManager.mediaBox, themeReference: themeSettings.theme, accentColor: currentColors?.color, bubbleColors: currentColors?.customBubbleColors ?? [], wallpaper: currentColors?.wallpaper, baseColor: currentColors?.baseColor, preview: true) ?? defaultPresentationTheme
                            lightWallpaper = theme.chat.defaultWallpaper
                        }
                        
                        var preferredBaseTheme: TelegramBaseTheme?
                        if let baseTheme = themeSettings.themePreferredBaseTheme[themeSettings.theme.index], [.classic, .day].contains(baseTheme) {
                            preferredBaseTheme = baseTheme
                        }
                        
                        lightTheme = makePresentationTheme(mediaBox: accountManager.mediaBox, themeReference: themeSettings.theme, baseTheme: preferredBaseTheme, accentColor: currentColors?.color, bubbleColors: currentColors?.customBubbleColors ?? [], wallpaper: currentColors?.wallpaper, baseColor: currentColors?.baseColor, serviceBackgroundColor: defaultServiceBackgroundColor) ?? defaultPresentationTheme
                    } else {
                        lightTheme = presentationData.theme
                        lightWallpaper = presentationData.chatWallpaper
                        
                        let automaticTheme = themeSettings.automaticThemeSwitchSetting.theme
                        let effectiveColors = themeSettings.themeSpecificAccentColors[automaticTheme.index]
                        let themeSpecificWallpaper = (themeSettings.themeSpecificChatWallpapers[coloredThemeIndex(reference: automaticTheme, accentColor: effectiveColors)] ?? themeSettings.themeSpecificChatWallpapers[automaticTheme.index])
                        
                        var preferredBaseTheme: TelegramBaseTheme?
                        if let baseTheme = themeSettings.themePreferredBaseTheme[automaticTheme.index], [.night, .tinted].contains(baseTheme) {
                            preferredBaseTheme = baseTheme
                        } else {
                            preferredBaseTheme = .night
                        }
                        
                        darkTheme = makePresentationTheme(mediaBox: accountManager.mediaBox, themeReference: automaticTheme, baseTheme: preferredBaseTheme, accentColor: effectiveColors?.color, bubbleColors: effectiveColors?.customBubbleColors ?? [], wallpaper: effectiveColors?.wallpaper, baseColor: effectiveColors?.baseColor, serviceBackgroundColor: defaultServiceBackgroundColor) ?? defaultPresentationTheme
                        
                        if let themeSpecificWallpaper = themeSpecificWallpaper {
                            darkWallpaper = themeSpecificWallpaper
                        } else {
                            switch lightWallpaper {
                                case .builtin, .color, .gradient:
                                    darkWallpaper = darkTheme.chat.defaultWallpaper
                                case .file:
                                    if lightWallpaper.isPattern {
                                        darkWallpaper = darkTheme.chat.defaultWallpaper
                                    } else {
                                        darkWallpaper = lightWallpaper
                                    }
                                default:
                                    darkWallpaper = lightWallpaper
                            }
                        }
                    }
                    
                    if darkAppearancePreview {
                        darkTheme.forceSync = true
                        Queue.mainQueue().after(1.0, {
                            darkTheme.forceSync = false
                        })
                        presentationData = presentationData.withUpdated(theme: darkTheme).withUpdated(chatWallpaper: darkWallpaper)
                    } else {
                        lightTheme.forceSync = true
                        Queue.mainQueue().after(1.0, {
                            lightTheme.forceSync = false
                        })
                        presentationData = presentationData.withUpdated(theme: lightTheme).withUpdated(chatWallpaper: lightWallpaper)
                    }
                }
                
                if let chatWallpaper {
                    presentationData = presentationData.withUpdated(chatWallpaper: chatWallpaper)
                }
                
                let isFirstTime = !strongSelf.didSetPresentationData
                strongSelf.presentationData = presentationData
                strongSelf.didSetPresentationData = true
                
                let previousThemeEmoticon = currentThemeEmoticon.swap((themeEmoticon, useDarkAppearance))
                
                if isFirstTime || previousTheme != presentationData.theme || previousStrings !== presentationData.strings || presentationData.chatWallpaper != previousChatWallpaper {
                    strongSelf.themeAndStringsUpdated()
                    
                    controllerInteraction.updatedPresentationData = strongSelf.updatedPresentationData
                    strongSelf.presentationDataPromise.set(.single(strongSelf.presentationData))
                    
                    if !isFirstTime && (previousThemeEmoticon?.0 != themeEmoticon || previousThemeEmoticon?.1 != useDarkAppearance) {
                        strongSelf.presentCrossfadeSnapshot()
                    }
                }
                strongSelf.presentationReady.set(.single(true))
            }
        })
        
        self.automaticMediaDownloadSettingsDisposable = (context.sharedContext.automaticMediaDownloadSettings
        |> deliverOnMainQueue).startStrict(next: { [weak self] downloadSettings in
            if let strongSelf = self, strongSelf.automaticMediaDownloadSettings != downloadSettings {
                strongSelf.automaticMediaDownloadSettings = downloadSettings
                strongSelf.controllerInteraction?.automaticMediaDownloadSettings = downloadSettings
                if strongSelf.isNodeLoaded {
                    strongSelf.chatDisplayNode.updateAutomaticMediaDownloadSettings(downloadSettings)
                }
            }
        })
        
        self.stickerSettingsDisposable = combineLatest(queue: Queue.mainQueue(), context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.stickerSettings]), self.disableStickerAnimationsPromise.get()).startStrict(next: { [weak self] sharedData, disableStickerAnimations in
            var stickerSettings = StickerSettings.defaultSettings
            if let value = sharedData.entries[ApplicationSpecificSharedDataKeys.stickerSettings]?.get(StickerSettings.self) {
                stickerSettings = value
            }
            
            let chatStickerSettings = ChatInterfaceStickerSettings(stickerSettings: stickerSettings)
            if let strongSelf = self, strongSelf.stickerSettings != chatStickerSettings || strongSelf.disableStickerAnimationsValue != disableStickerAnimations {
                strongSelf.stickerSettings = chatStickerSettings
                strongSelf.disableStickerAnimationsValue = disableStickerAnimations
                strongSelf.controllerInteraction?.stickerSettings = chatStickerSettings
                if strongSelf.isNodeLoaded {
                    strongSelf.chatDisplayNode.updateStickerSettings(chatStickerSettings, forceStopAnimations: disableStickerAnimations)
                }
            }
        })
        
        var wasInForeground = true
        self.applicationInForegroundDisposable = (context.sharedContext.applicationBindings.applicationInForeground
        |> distinctUntilChanged
        |> deliverOn(Queue.mainQueue())).startStrict(next: { [weak self] value in
            if let strongSelf = self, strongSelf.isNodeLoaded {
                if !value {
                    strongSelf.saveInterfaceState()
                    strongSelf.raiseToListen?.applicationResignedActive()
                    
                    strongSelf.stopMediaRecorder()
                } else {
                    if !wasInForeground {
                        strongSelf.chatDisplayNode.recursivelyEnsureDisplaySynchronously(true)
                    }
                }
                wasInForeground = value
            }
        })
        
        if case let .peer(peerId) = chatLocation, peerId.namespace == Namespaces.Peer.SecretChat {
            self.applicationInFocusDisposable = (context.sharedContext.applicationBindings.applicationIsActive
            |> distinctUntilChanged
            |> deliverOn(Queue.mainQueue())).startStrict(next: { [weak self] value in
                guard let strongSelf = self, strongSelf.isNodeLoaded else {
                    return
                }
                strongSelf.chatDisplayNode.updateIsBlurred(!value)
            })
        }
        
        self.canReadHistoryDisposable = (combineLatest(context.sharedContext.applicationBindings.applicationInForeground, self.canReadHistory.get()) |> map { a, b in
            return a && b
        } |> deliverOnMainQueue).startStrict(next: { [weak self] value in
            if let strongSelf = self, strongSelf.canReadHistoryValue != value {
                strongSelf.canReadHistoryValue = value
                strongSelf.raiseToListen?.enabled = value
                strongSelf.isReminderActivityEnabled = value
                strongSelf.updateReminderActivity()
            }
        })
        
        self.networkStateDisposable = (context.account.networkState |> deliverOnMainQueue).startStrict(next: { [weak self] state in
            if let strongSelf = self, case .standard(.default) = strongSelf.presentationInterfaceState.mode {
                strongSelf.chatTitleView?.networkState = state
            }
        })
        
        if case let .messageOptions(_, messageIds, _) = self.subject, messageIds.count > 1 {
            self.updateChatPresentationInterfaceState(interactive: false, { state in
                return state.updatedInterfaceState({ $0.withUpdatedSelectedMessages(messageIds) })
            })
        }
    }
    
    required public init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        let _ = ChatControllerCount.modify { value in
            return value - 1
        }
        
        let deallocate: () -> Void = {
            self.historyStateDisposable?.dispose()
            self.messageIndexDisposable.dispose()
            self.navigationActionDisposable.dispose()
            self.galleryHiddenMesageAndMediaDisposable.dispose()
            self.temporaryHiddenGalleryMediaDisposable.dispose()
            self.peerDisposable.dispose()
            self.accountPeerDisposable?.dispose()
            self.titleDisposable.dispose()
            self.messageContextDisposable.dispose()
            self.controllerNavigationDisposable.dispose()
            self.sentMessageEventsDisposable.dispose()
            self.failedMessageEventsDisposable.dispose()
            self.sentPeerMediaMessageEventsDisposable.dispose()
            self.messageActionCallbackDisposable.dispose()
            self.messageActionUrlAuthDisposable.dispose()
            self.editMessageDisposable.dispose()
            self.editMessageErrorsDisposable.dispose()
            self.enqueueMediaMessageDisposable.dispose()
            self.resolvePeerByNameDisposable?.dispose()
            self.shareStatusDisposable?.dispose()
            self.clearCacheDisposable?.dispose()
            self.bankCardDisposable?.dispose()
            self.botCallbackAlertMessageDisposable?.dispose()
            self.selectMessagePollOptionDisposables?.dispose()
            for (_, info) in self.contextQueryStates {
                info.1.dispose()
            }
            self.urlPreviewQueryState?.1.dispose()
            self.editingUrlPreviewQueryState?.1.dispose()
            self.replyMessageState?.1.dispose()
            self.audioRecorderDisposable?.dispose()
            self.audioRecorderStatusDisposable?.dispose()
            self.videoRecorderDisposable?.dispose()
            self.buttonKeyboardMessageDisposable?.dispose()
            self.cachedDataDisposable?.dispose()
            self.resolveUrlDisposable?.dispose()
            self.chatUnreadCountDisposable?.dispose()
            self.buttonUnreadCountDisposable?.dispose()
            self.chatUnreadMentionCountDisposable?.dispose()
            self.peerInputActivitiesDisposable?.dispose()
            self.interactiveEmojiSyncDisposable.dispose()
            self.recentlyUsedInlineBotsDisposable?.dispose()
            self.unpinMessageDisposable?.dispose()
            self.inputActivityDisposable?.dispose()
            self.recordingActivityDisposable?.dispose()
            self.acquiredRecordingActivityDisposable?.dispose()
            self.presentationDataDisposable?.dispose()
            self.searchDisposable?.dispose()
            self.applicationInForegroundDisposable?.dispose()
            self.applicationInFocusDisposable?.dispose()
            self.canReadHistoryDisposable?.dispose()
            self.networkStateDisposable?.dispose()
            self.chatAdditionalDataDisposable.dispose()
            self.shareStatusDisposable?.dispose()
            self.context.sharedContext.mediaManager.galleryHiddenMediaManager.removeTarget(self)
            self.preloadHistoryPeerIdDisposable.dispose()
            self.preloadNextChatPeerIdDisposable.dispose()
            self.reportIrrelvantGeoDisposable?.dispose()
            self.reminderActivity?.invalidate()
            self.updateSlowmodeStatusDisposable.dispose()
            self.keepPeerInfoScreenDataHotDisposable.dispose()
            self.preloadAvatarDisposable.dispose()
            self.peekTimerDisposable.dispose()
            self.hasActiveGroupCallDisposable?.dispose()
            self.createVoiceChatDisposable.dispose()
            self.checksTooltipDisposable.dispose()
            self.peerSuggestionsDisposable.dispose()
            self.peerSuggestionsDismissDisposable.dispose()
            self.selectAddMemberDisposable.dispose()
            self.addMemberDisposable.dispose()
            self.joinChannelDisposable.dispose()
            self.nextChannelToReadDisposable?.dispose()
            self.inviteRequestsDisposable.dispose()
            self.sendAsPeersDisposable?.dispose()
            self.preloadAttachBotIconsDisposables?.dispose()
            self.keepMessageCountersSyncrhonizedDisposable?.dispose()
            self.translationStateDisposable?.dispose()
            self.premiumGiftSuggestionDisposable?.dispose()
            self.powerSavingMonitoringDisposable?.dispose()
            self.saveMediaDisposable?.dispose()
            self.giveawayStatusDisposable?.dispose()
            self.nameColorDisposable?.dispose()
            self.choosingStickerActivityDisposable?.dispose()
            self.automaticMediaDownloadSettingsDisposable?.dispose()
            self.stickerSettingsDisposable?.dispose()
            self.searchQuerySuggestionState?.1.dispose()
            self.preloadSavedMessagesChatsDisposable?.dispose()
            self.recorderDataDisposable.dispose()
            self.displaySendWhenOnlineTipDisposable.dispose()
        }
        deallocate()
    }
    
    public func updatePresentationMode(_ mode: ChatControllerPresentationMode) {
        self.updateChatPresentationInterfaceState(animated: false, interactive: false, {
            return $0.updatedMode(mode)
        })
    }
    
    var chatDisplayNode: ChatControllerNode {
        get {
            return super.displayNode as! ChatControllerNode
        }
    }
    
    func themeAndStringsUpdated() {
        self.navigationItem.backBarButtonItem = UIBarButtonItem(title: self.presentationData.strings.Common_Back, style: .plain, target: nil, action: nil)
        switch self.presentationInterfaceState.mode {
        case let .standard(standardMode):
            switch standardMode {
            case .embedded:
                self.statusBar.statusBarStyle = .Ignore
            default:
                self.statusBar.statusBarStyle = self.presentationData.theme.rootController.statusBarStyle.style
                self.deferScreenEdgeGestures = []
            }
        case .overlay:
            self.statusBar.statusBarStyle = .Hide
            self.deferScreenEdgeGestures = [.top]
        case .inline:
            self.statusBar.statusBarStyle = .Ignore
        }
        self.updateNavigationBarPresentation()
        self.updateChatPresentationInterfaceState(animated: false, interactive: false, { state in
            var state = state
            state = state.updatedPresentationReady(self.didSetPresentationData)
            state = state.updatedTheme(self.presentationData.theme)
            state = state.updatedStrings(self.presentationData.strings)
            state = state.updatedDateTimeFormat(self.presentationData.dateTimeFormat)
            state = state.updatedChatWallpaper(self.presentationData.chatWallpaper)
            state = state.updatedBubbleCorners(self.presentationData.chatBubbleCorners)
            return state
        })
        
        self.currentContextController?.updateTheme(presentationData: self.presentationData)
    }
    
    func updateNavigationBarPresentation() {
        let navigationBarTheme: NavigationBarTheme
            
        if self.hasEmbeddedTitleContent {
            navigationBarTheme = NavigationBarTheme(rootControllerTheme: defaultDarkPresentationTheme, hideBackground: self.context.sharedContext.immediateExperimentalUISettings.playerEmbedding ? true : false, hideBadge: true)
        } else {
            navigationBarTheme = NavigationBarTheme(rootControllerTheme: self.presentationData.theme, hideBackground: self.context.sharedContext.immediateExperimentalUISettings.playerEmbedding ? true : false, hideBadge: false)
        }
        
        self.navigationBar?.updatePresentationData(NavigationBarPresentationData(theme: navigationBarTheme, strings: NavigationBarStrings(presentationStrings: self.presentationData.strings)))
        
        self.chatTitleView?.updateThemeAndStrings(theme: self.presentationData.theme, strings: self.presentationData.strings, hasEmbeddedTitleContent: self.hasEmbeddedTitleContent)
    }
    
    func topPinnedMessageSignal(latest: Bool) -> Signal<ChatPinnedMessage?, NoError> {
        var pinnedPeerId: EnginePeer.Id?
        let threadId = self.chatLocation.threadId
        let loadState: Signal<Bool, NoError> = self.chatDisplayNode.historyNode.historyState.get()
        |> map { state -> Bool in
            switch state {
            case .loading:
                return false
            default:
                return true
            }
        }
        |> distinctUntilChanged
        
        switch self.chatLocation {
        case let .peer(id):
            pinnedPeerId = id
        case let .replyThread(message):
            if message.isForumPost {
                pinnedPeerId = self.chatLocation.peerId
            }
        default:
            break
        }
        
        if let peerId = pinnedPeerId {
            let topPinnedMessage: Signal<ChatPinnedMessage?, NoError>
            
            enum ReferenceMessage {
                struct Loaded {
                    var id: MessageId
                    var minId: MessageId
                    var isScrolled: Bool
                }
                
                case ready(Loaded)
                case loading
            }
            
            let referenceMessage: Signal<ReferenceMessage?, NoError>
            if latest {
                referenceMessage = .single(nil)
            } else {
                referenceMessage = combineLatest(
                    queue: Queue.mainQueue(),
                    self.scrolledToMessageId.get(),
                    self.chatDisplayNode.historyNode.topVisibleMessageRange.get()
                )
                |> map { scrolledToMessageId, topVisibleMessageRange -> ReferenceMessage? in
                    if let topVisibleMessageRange = topVisibleMessageRange, topVisibleMessageRange.isLoading {
                        return .loading
                    }
                    
                    let bottomVisibleMessage = topVisibleMessageRange?.lowerBound.id
                    let topVisibleMessage = topVisibleMessageRange?.upperBound.id
                    
                    if let scrolledToMessageId = scrolledToMessageId {
                        if let topVisibleMessage, let bottomVisibleMessage {
                            if scrolledToMessageId.allowedReplacementDirection.contains(.up) && topVisibleMessage < scrolledToMessageId.id {
                                return .ready(ReferenceMessage.Loaded(id: topVisibleMessage, minId: bottomVisibleMessage, isScrolled: false))
                            }
                        }
                        return .ready(ReferenceMessage.Loaded(id: scrolledToMessageId.id, minId: scrolledToMessageId.id, isScrolled: true))
                    } else if let topVisibleMessage, let bottomVisibleMessage {
                        return .ready(ReferenceMessage.Loaded(id: topVisibleMessage, minId: bottomVisibleMessage, isScrolled: false))
                    } else {
                        return nil
                    }
                }
            }
            
            let context = self.context
            
            func pinnedHistorySignal(anchorMessageId: MessageId?, count: Int) -> Signal<ChatHistoryViewUpdate, NoError> {
                let location: ChatHistoryLocation
                if let anchorMessageId = anchorMessageId {
                    location = .InitialSearch(subject: MessageHistoryInitialSearchSubject(location: .id(anchorMessageId), quote: nil), count: count, highlight: false)
                } else {
                    location = .Initial(count: count)
                }
                
                let chatLocation: ChatLocation
                if let threadId {
                    chatLocation = .replyThread(message: ChatReplyThreadMessage(peerId: peerId, threadId: threadId, channelMessageId: nil, isChannelPost: false, isForumPost: true, maxMessage: nil, maxReadIncomingMessageId: nil, maxReadOutgoingMessageId: nil, unreadCount: 0, initialFilledHoles: IndexSet(), initialAnchor: .automatic, isNotAvailable: false))
                } else {
                    chatLocation = .peer(id: peerId)
                }
                
                return (chatHistoryViewForLocation(ChatHistoryLocationInput(content: location, id: 0), ignoreMessagesInTimestampRange: nil, context: context, chatLocation: chatLocation, chatLocationContextHolder: Atomic<ChatLocationContextHolder?>(value: nil), scheduled: false, fixedCombinedReadStates: nil, tag: .tag(MessageTags.pinned), appendMessagesFromTheSameGroup: false, additionalData: [], orderStatistics: .combinedLocation)
                |> castError(Bool.self)
                |> mapToSignal { update -> Signal<ChatHistoryViewUpdate, Bool> in
                    switch update {
                    case let .Loading(_, type):
                        if case .Generic(.FillHole) = type {
                            return .fail(true)
                        }
                    case let .HistoryView(_, type, _, _, _, _, _):
                        if case .Generic(.FillHole) = type {
                            return .fail(true)
                        }
                    }
                    return .single(update)
                })
                |> restartIfError
            }
            
            struct TopMessage {
                var message: Message
                var index: Int
            }
            
            let topMessage = pinnedHistorySignal(anchorMessageId: nil, count: 10)
            |> map { update -> TopMessage? in
                switch update {
                case .Loading:
                    return nil
                case let .HistoryView(viewValue, _, _, _, _, _, _):
                    if let entry = viewValue.entries.last {
                        let index: Int
                        if let location = entry.location {
                            index = location.index
                        } else {
                            index = viewValue.entries.count - 1
                        }
                        
                        return TopMessage(
                            message: entry.message,
                            index: index
                        )
                    } else {
                        return nil
                    }
                }
            }
            
            let loadCount = 10
            
            struct PinnedHistory {
                struct PinnedMessage {
                    var message: Message
                    var index: Int
                }
                
                var messages: [PinnedMessage]
                var totalCount: Int
            }
            
            let adjustedReplyHistory: Signal<PinnedHistory, NoError>
            if latest {
                adjustedReplyHistory = pinnedHistorySignal(anchorMessageId: nil, count: loadCount)
                |> map { view -> PinnedHistory in
                    switch view {
                    case .Loading:
                        return PinnedHistory(messages: [], totalCount: 0)
                    case let .HistoryView(viewValue, _, _, _, _, _, _):
                        var messages: [PinnedHistory.PinnedMessage] = []
                        var totalCount = viewValue.entries.count
                        for i in 0 ..< viewValue.entries.count {
                            let index: Int
                            if !viewValue.holeEarlier && viewValue.earlierId == nil {
                                index = i
                            } else if let location = viewValue.entries[i].location {
                                index = location.index
                                totalCount = location.count
                            } else {
                                index = i
                            }
                            messages.append(PinnedHistory.PinnedMessage(
                                message: viewValue.entries[i].message,
                                index: index
                            ))
                        }
                        return PinnedHistory(messages: messages, totalCount: totalCount)
                    }
                }
            } else {
                adjustedReplyHistory = (Signal<PinnedHistory, NoError> { subscriber in
                    var referenceMessageValue: ReferenceMessage?
                    var view: ChatHistoryViewUpdate?
                    
                    let updateState: () -> Void = {
                        guard let view = view else {
                            return
                        }
                        guard case let .HistoryView(viewValue, _, _, _, _, _, _) = view else {
                            subscriber.putNext(PinnedHistory(messages: [], totalCount: 0))
                            return
                        }
                        
                        var messages: [PinnedHistory.PinnedMessage] = []
                        for i in 0 ..< viewValue.entries.count {
                            messages.append(PinnedHistory.PinnedMessage(
                                message: viewValue.entries[i].message,
                                index: i
                            ))
                        }
                        let result = PinnedHistory(messages: messages, totalCount: messages.count)
                        
                        if case let .ready(loaded) = referenceMessageValue {
                            let referenceId = loaded.id
                            
                            if viewValue.entries.count < loadCount {
                                subscriber.putNext(result)
                            } else if referenceId < viewValue.entries[1].message.id {
                                if viewValue.earlierId != nil {
                                    subscriber.putCompletion()
                                } else {
                                    subscriber.putNext(result)
                                }
                            } else if referenceId > viewValue.entries[viewValue.entries.count - 2].message.id {
                                if viewValue.laterId != nil {
                                    subscriber.putCompletion()
                                } else {
                                    subscriber.putNext(result)
                                }
                            } else {
                                subscriber.putNext(result)
                            }
                        } else {
                            if viewValue.isLoading {
                                subscriber.putNext(result)
                            } else  if viewValue.holeLater || viewValue.laterId != nil {
                                subscriber.putCompletion()
                            } else {
                                subscriber.putNext(result)
                            }
                        }
                    }
                    
                    var initializedView = false
                    let viewDisposable = MetaDisposable()
                    
                    let referenceDisposable = (referenceMessage
                    |> deliverOnMainQueue).startStrict(next: { referenceMessage in
                        referenceMessageValue = referenceMessage
                        if !initializedView {
                            initializedView = true
                            //print("reload at \(String(describing: referenceMessage?.id)) disposable \(unsafeBitCast(viewDisposable, to: UInt64.self))")
                            var referenceId: MessageId?
                            if case let .ready(loaded) = referenceMessage {
                                referenceId = loaded.id
                            }
                            viewDisposable.set((pinnedHistorySignal(anchorMessageId: referenceId, count: loadCount)
                            |> deliverOnMainQueue).startStrict(next: { next in
                                view = next
                                updateState()
                            }))
                        }
                        updateState()
                    })
                    
                    return ActionDisposable {
                        //print("dispose \(unsafeBitCast(viewDisposable, to: UInt64.self))")
                        referenceDisposable.dispose()
                        viewDisposable.dispose()
                    }
                }
                |> runOn(.mainQueue()))
                |> restart
            }
            
            topPinnedMessage = combineLatest(queue: .mainQueue(),
                adjustedReplyHistory,
                topMessage,
                referenceMessage,
                loadState
            )
            |> map { pinnedMessages, topMessage, referenceMessage, loadState -> ChatPinnedMessage? in
                if !loadState {
                    return nil
                }
                
                var message: ChatPinnedMessage?
                
                let topMessageId: MessageId
                if pinnedMessages.messages.isEmpty {
                    return nil
                }
                topMessageId = topMessage?.message.id ?? pinnedMessages.messages[pinnedMessages.messages.count - 1].message.id
                
                if case let .ready(referenceMessage) = referenceMessage, referenceMessage.isScrolled, !pinnedMessages.messages.isEmpty, referenceMessage.id == pinnedMessages.messages[0].message.id, let topMessage = topMessage {
                    var index = topMessage.index
                    for message in pinnedMessages.messages {
                        if message.message.id == topMessage.message.id {
                            index = message.index
                            break
                        }
                    }
                    
                    if threadId != nil {
                        if referenceMessage.minId <= topMessage.message.id {
                            return nil
                        }
                    }
                    return ChatPinnedMessage(message: topMessage.message, index: index, totalCount: pinnedMessages.totalCount, topMessageId: topMessageId)
                }
                
                //print("reference: \(String(describing: referenceMessage?.id.id)) entries: \(view.entries.map(\.index.id.id))")
                for i in 0 ..< pinnedMessages.messages.count {
                    let entry = pinnedMessages.messages[i]
                    var matches = false
                    if message == nil {
                        matches = true
                    } else if case let .ready(referenceMessage) = referenceMessage {
                        if referenceMessage.isScrolled {
                            if entry.message.id < referenceMessage.id {
                                matches = true
                            }
                        } else {
                            if entry.message.id <= referenceMessage.id {
                                matches = true
                            }
                        }
                    } else {
                        matches = true
                    }
                    if matches {
                        if threadId != nil, case let .ready(referenceMessage) = referenceMessage {
                            if referenceMessage.minId <= entry.message.id {
                                continue
                            }
                        }
                        message = ChatPinnedMessage(message: entry.message, index: entry.index, totalCount: pinnedMessages.totalCount, topMessageId: topMessageId)
                    }
                }

                return message
            }
            |> distinctUntilChanged
            
            return topPinnedMessage
        } else {
            return .single(nil)
        }
    }
    
    override public func loadDisplayNode() {
        self.displayNode = ChatControllerNode(context: self.context, chatLocation: self.chatLocation, chatLocationContextHolder: self.chatLocationContextHolder, subject: self.subject, controllerInteraction: self.controllerInteraction!, chatPresentationInterfaceState: self.presentationInterfaceState, automaticMediaDownloadSettings: self.automaticMediaDownloadSettings, navigationBar: self.navigationBar, statusBar: self.statusBar, backgroundNode: self.chatBackgroundNode, controller: self)
        
        if let currentItem = self.tempVoicePlaylistCurrentItem {
            self.chatDisplayNode.historyNode.voicePlaylistItemChanged(nil, currentItem)
        }
        
        self.chatDisplayNode.historyNode.beganDragging = { [weak self] in
            guard let self else {
                return
            }
            if self.presentationInterfaceState.search != nil && self.presentationInterfaceState.historyFilter != nil {
                self.chatDisplayNode.historyNode.addAfterTransactionsCompleted { [weak self] in
                    guard let self else {
                        return
                    }
                    
                    self.chatDisplayNode.dismissInput()
                }
            }
        }
    
        self.chatDisplayNode.historyNode.didScrollWithOffset = { [weak self] offset, transition, itemNode, isTracking in
            guard let strongSelf = self else {
                return
            }

            //print("didScrollWithOffset offset: \(offset), itemNode: \(String(describing: itemNode))")
            
            if offset > 0.0 {
                if var scrolledToMessageIdValue = strongSelf.scrolledToMessageIdValue {
                    scrolledToMessageIdValue.allowedReplacementDirection.insert(.up)
                    strongSelf.scrolledToMessageIdValue = scrolledToMessageIdValue
                }
            } else if offset < 0.0 {
                strongSelf.scrolledToMessageIdValue = nil
            }

            if let currentPinchSourceItemNode = strongSelf.currentPinchSourceItemNode {
                if let itemNode = itemNode {
                    if itemNode === currentPinchSourceItemNode {
                        strongSelf.currentPinchController?.addRelativeContentOffset(CGPoint(x: 0.0, y: -offset), transition: transition)
                    }
                } else {
                    strongSelf.currentPinchController?.addRelativeContentOffset(CGPoint(x: 0.0, y: -offset), transition: transition)
                }
            }
            
            if isTracking {
                strongSelf.chatDisplayNode.loadingPlaceholderNode?.addContentOffset(offset: offset, transition: transition)
            }
            strongSelf.chatDisplayNode.messageTransitionNode.addExternalOffset(offset: offset, transition: transition, itemNode: itemNode)
            
        }
        
        self.chatDisplayNode.historyNode.hasPlentyOfMessagesUpdated = { [weak self] hasPlentyOfMessages in
            if let strongSelf = self {
                strongSelf.updateChatPresentationInterfaceState(interactive: false, { $0.updatedHasPlentyOfMessages(hasPlentyOfMessages) })
            }
        }
        if case .peer(self.context.account.peerId) = self.chatLocation {
            var didDisplayTooltip = false
            if "".isEmpty {
                didDisplayTooltip = true
            }
            self.chatDisplayNode.historyNode.hasLotsOfMessagesUpdated = { [weak self] hasLotsOfMessages in
                guard let self, hasLotsOfMessages else {
                    return
                }
                if didDisplayTooltip {
                    return
                }
                didDisplayTooltip = true
                
                let _ = (ApplicationSpecificNotice.getSavedMessagesChatsSuggestion(accountManager: self.context.sharedContext.accountManager)
                |> deliverOnMainQueue).startStandalone(next: { [weak self] counter in
                    guard let self else {
                        return
                    }
                    if counter >= 3 {
                        return
                    }
                    guard let navigationBar = self.navigationBar else {
                        return
                    }
                    
                    let tooltipScreen = TooltipScreen(account: self.context.account, sharedContext: self.context.sharedContext, text: .plain(text: self.presentationData.strings.Chat_SavedMessagesChatsTooltip), location: .point(navigationBar.frame, .top), displayDuration: .manual, shouldDismissOnTouch: { point, _ in
                        return .ignore
                    })
                    self.present(tooltipScreen, in: .current)
                    
                    let _ = ApplicationSpecificNotice.incrementSavedMessagesChatsSuggestion(accountManager: self.context.sharedContext.accountManager).startStandalone()
                })
            }
        }

        self.chatDisplayNode.historyNode.addContentOffset = { [weak self] offset, itemNode in
            guard let strongSelf = self else {
                return
            }
            strongSelf.chatDisplayNode.messageTransitionNode.addContentOffset(offset: offset, itemNode: itemNode)
        }
        
        var closeOnEmpty = false
        if case .pinnedMessages = self.presentationInterfaceState.subject {
            closeOnEmpty = true
        } else if case let .replyThread(replyThreadMessage) = self.chatLocation, replyThreadMessage.peerId == self.context.account.peerId {
            closeOnEmpty = false
        }
        
        if closeOnEmpty {
            self.chatDisplayNode.historyNode.addSetLoadStateUpdated({ [weak self] state, _ in
                guard let strongSelf = self else {
                    return
                }
                if case .empty = state {
                    strongSelf.dismiss()
                }
            })
        }
        
        self.chatDisplayNode.overlayTitle = self.overlayTitle
        
        let currentAccountPeer = self.context.account.postbox.loadedPeerWithId(self.context.account.peerId)
        |> map { peer in
            return SendAsPeer(peer: peer, subscribers: nil, isPremiumRequired: false)
        }
        
        if let peerId = self.chatLocation.peerId, [Namespaces.Peer.CloudChannel, Namespaces.Peer.CloudGroup].contains(peerId.namespace) {
            self.sendAsPeersDisposable = (combineLatest(
                queue: Queue.mainQueue(),
                currentAccountPeer,
                self.context.account.postbox.peerView(id: peerId),
                self.context.engine.peers.sendAsAvailablePeers(peerId: peerId))
            ).startStrict(next: { [weak self] currentAccountPeer, peerView, peers in
                guard let strongSelf = self else {
                    return
                }
                
                let isPremium = strongSelf.presentationInterfaceState.isPremium
                
                var allPeers: [SendAsPeer]?
                if !peers.isEmpty {
                    if let channel = peerViewMainPeer(peerView) as? TelegramChannel, case .group = channel.info, channel.hasPermission(.canBeAnonymous) {
                        allPeers = peers
                        
                        var hasAnonymousPeer = false
                        for peer in peers {
                            if peer.peer.id == channel.id {
                                hasAnonymousPeer = true
                                break
                            }
                        }
                        if !hasAnonymousPeer {
                            allPeers?.insert(SendAsPeer(peer: channel, subscribers: 0, isPremiumRequired: false), at: 0)
                        }
                    } else {
                        allPeers = peers.filter { $0.peer.id != peerViewMainPeer(peerView)?.id }
                        allPeers?.insert(currentAccountPeer, at: 0)
                    }
                }
                if allPeers?.count == 1 {
                    allPeers = nil
                }
                
                var currentSendAsPeerId = strongSelf.presentationInterfaceState.currentSendAsPeerId
                if let peerId = currentSendAsPeerId, let peer = allPeers?.first(where: { $0.peer.id == peerId }) {
                    if !isPremium && peer.isPremiumRequired {
                        currentSendAsPeerId = nil
                    }
                } else {
                    currentSendAsPeerId = nil
                }
                
                strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: false, {
                    return $0.updatedSendAsPeers(allPeers).updatedCurrentSendAsPeerId(currentSendAsPeerId)
                })
            })
        }
        
        let initialData = self.chatDisplayNode.historyNode.initialData
        |> take(1)
        |> beforeNext { [weak self] combinedInitialData in
            guard let strongSelf = self, let combinedInitialData = combinedInitialData else {
                return
            }

            if let opaqueState = (combinedInitialData.initialData?.storedInterfaceState).flatMap(_internal_decodeStoredChatInterfaceState) {
                var interfaceState = ChatInterfaceState.parse(opaqueState)

                var pinnedMessageId: MessageId?
                var peerIsBlocked: Bool = false
                var callsAvailable: Bool = true
                var callsPrivate: Bool = false
                var activeGroupCallInfo: ChatActiveGroupCallInfo?
                var slowmodeState: ChatSlowmodeState?
                if let cachedData = combinedInitialData.cachedData as? CachedChannelData {
                    pinnedMessageId = cachedData.pinnedMessageId
                    if let channel = combinedInitialData.initialData?.peer as? TelegramChannel, channel.isRestrictedBySlowmode, let timeout = cachedData.slowModeTimeout {
                        if let slowmodeUntilTimestamp = calculateSlowmodeActiveUntilTimestamp(account: strongSelf.context.account, untilTimestamp: cachedData.slowModeValidUntilTimestamp) {
                            slowmodeState = ChatSlowmodeState(timeout: timeout, variant: .timestamp(slowmodeUntilTimestamp))
                        }
                    }
                    if let activeCall = cachedData.activeCall {
                        activeGroupCallInfo = ChatActiveGroupCallInfo(activeCall: activeCall)
                    }
                } else if let cachedData = combinedInitialData.cachedData as? CachedUserData {
                    peerIsBlocked = cachedData.isBlocked
                    callsAvailable = cachedData.voiceCallsAvailable
                    callsPrivate = cachedData.callsPrivate
                    pinnedMessageId = cachedData.pinnedMessageId
                } else if let cachedData = combinedInitialData.cachedData as? CachedGroupData {
                    pinnedMessageId = cachedData.pinnedMessageId
                    if let activeCall = cachedData.activeCall {
                        activeGroupCallInfo = ChatActiveGroupCallInfo(activeCall: activeCall)
                    }
                } else if let _ = combinedInitialData.cachedData as? CachedSecretChatData {
                }
                
                if let channel = combinedInitialData.initialData?.peer as? TelegramChannel {
                    if channel.hasBannedPermission(.banSendVoice) != nil && channel.hasBannedPermission(.banSendInstantVideos) != nil {
                        interfaceState = interfaceState.withUpdatedMediaRecordingMode(.audio)
                    } else if channel.hasBannedPermission(.banSendVoice) != nil {
                        if channel.hasBannedPermission(.banSendInstantVideos) == nil {
                            interfaceState = interfaceState.withUpdatedMediaRecordingMode(.video)
                        }
                    } else if channel.hasBannedPermission(.banSendInstantVideos) != nil {
                        if channel.hasBannedPermission(.banSendVoice) == nil {
                            interfaceState = interfaceState.withUpdatedMediaRecordingMode(.audio)
                        }
                    }
                } else if let group = combinedInitialData.initialData?.peer as? TelegramGroup {
                    if group.hasBannedPermission(.banSendVoice) && group.hasBannedPermission(.banSendInstantVideos) {
                        interfaceState = interfaceState.withUpdatedMediaRecordingMode(.audio)
                    } else if group.hasBannedPermission(.banSendVoice) {
                        if !group.hasBannedPermission(.banSendInstantVideos) {
                            interfaceState = interfaceState.withUpdatedMediaRecordingMode(.video)
                        }
                    } else if group.hasBannedPermission(.banSendInstantVideos) {
                        if !group.hasBannedPermission(.banSendVoice) {
                            interfaceState = interfaceState.withUpdatedMediaRecordingMode(.audio)
                        }
                    }
                }
                
                if case let .replyThread(replyThreadMessageId) = strongSelf.chatLocation {
                    if let channel = combinedInitialData.initialData?.peer as? TelegramChannel, channel.flags.contains(.isForum) {
                        pinnedMessageId = nil
                    } else {
                        pinnedMessageId = replyThreadMessageId.effectiveTopId
                    }
                }
                
                var pinnedMessage: ChatPinnedMessage?
                if let pinnedMessageId = pinnedMessageId {
                    if let cachedDataMessages = combinedInitialData.cachedDataMessages {
                        if let message = cachedDataMessages[pinnedMessageId] {
                            pinnedMessage = ChatPinnedMessage(message: message, index: 0, totalCount: 1, topMessageId: message.id)
                        }
                    }
                }
                
                var buttonKeyboardMessage = combinedInitialData.buttonKeyboardMessage
                if let buttonKeyboardMessageValue = buttonKeyboardMessage, buttonKeyboardMessageValue.isRestricted(platform: "ios", contentSettings: strongSelf.context.currentContentSettings.with({ $0 })) {
                    buttonKeyboardMessage = nil
                }
                
                strongSelf.updateChatPresentationInterfaceState(animated: false, interactive: false, { updated in
                    var updated = updated
                
                    updated = updated.updatedInterfaceState({ _ in return interfaceState })
                    
                    updated = updated.updatedKeyboardButtonsMessage(buttonKeyboardMessage)
                    updated = updated.updatedPinnedMessageId(pinnedMessageId)
                    updated = updated.updatedPinnedMessage(pinnedMessage)
                    updated = updated.updatedPeerIsBlocked(peerIsBlocked)
                    updated = updated.updatedCallsAvailable(callsAvailable)
                    updated = updated.updatedCallsPrivate(callsPrivate)
                    updated = updated.updatedActiveGroupCallInfo(activeGroupCallInfo)
                    updated = updated.updatedTitlePanelContext({ context in
                        if pinnedMessageId != nil {
                            if !context.contains(where: {
                                switch $0 {
                                    case .pinnedMessage:
                                        return true
                                    default:
                                        return false
                                }
                            }) {
                                var updatedContexts = context
                                updatedContexts.append(.pinnedMessage)
                                return updatedContexts.sorted()
                            } else {
                                return context
                            }
                        } else {
                            if let index = context.firstIndex(where: {
                                switch $0 {
                                    case .pinnedMessage:
                                        return true
                                    default:
                                        return false
                                }
                            }) {
                                var updatedContexts = context
                                updatedContexts.remove(at: index)
                                return updatedContexts
                            } else {
                                return context
                            }
                        }
                    })
                    if let editMessage = interfaceState.editMessage, let message = combinedInitialData.initialData?.associatedMessages[editMessage.messageId] {
                        updated = updatedChatEditInterfaceMessageState(state: updated, message: message)
                    }
                    updated = updated.updatedSlowmodeState(slowmodeState)
                    return updated
                })
            }
            if let readStateData = combinedInitialData.readStateData {
                if case let .peer(peerId) = strongSelf.chatLocation, let peerReadStateData = readStateData[peerId], let notificationSettings = peerReadStateData.notificationSettings {
                    
                    let inAppSettings = strongSelf.context.sharedContext.currentInAppNotificationSettings.with { $0 }
                    let (count, _) = renderedTotalUnreadCount(inAppSettings: inAppSettings, totalUnreadState: peerReadStateData.totalState ?? ChatListTotalUnreadState(absoluteCounters: [:], filteredCounters: [:]))
                    
                    var globalRemainingUnreadChatCount = count
                    if !notificationSettings.isRemovedFromTotalUnreadCount(default: false) && peerReadStateData.unreadCount > 0 {
                        if case .messages = inAppSettings.totalUnreadCountDisplayCategory {
                            globalRemainingUnreadChatCount -= peerReadStateData.unreadCount
                        } else {
                            globalRemainingUnreadChatCount -= 1
                        }
                    }
                    if globalRemainingUnreadChatCount > 0 {
                        strongSelf.navigationItem.badge = "\(globalRemainingUnreadChatCount)"
                    } else {
                        strongSelf.navigationItem.badge = ""
                    }
                }
            }
        }
        
        self.buttonKeyboardMessageDisposable = self.chatDisplayNode.historyNode.buttonKeyboardMessage.startStrict(next: { [weak self] message in
            if let strongSelf = self {
                var buttonKeyboardMessageUpdated = false
                if let currentButtonKeyboardMessage = strongSelf.presentationInterfaceState.keyboardButtonsMessage, let message = message {
                    if currentButtonKeyboardMessage.id != message.id || currentButtonKeyboardMessage.stableVersion != message.stableVersion {
                        buttonKeyboardMessageUpdated = true
                    }
                } else if (strongSelf.presentationInterfaceState.keyboardButtonsMessage != nil) != (message != nil) {
                    buttonKeyboardMessageUpdated = true
                }
                if buttonKeyboardMessageUpdated {
                    strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, { $0.updatedKeyboardButtonsMessage(message) })
                }
            }
        })
        
        let hasPendingMessages: Signal<Bool, NoError>
        let chatLocationPeerId = self.chatLocation.peerId
        
        if let chatLocationPeerId = chatLocationPeerId {
            hasPendingMessages = self.context.account.pendingMessageManager.hasPendingMessages
            |> mapToSignal { peerIds -> Signal<Bool, NoError> in
                let value = peerIds.contains(chatLocationPeerId)
                if value {
                    return .single(true)
                } else {
                    return .single(false)
                    |> delay(0.1, queue: .mainQueue())
                }
            }
            |> distinctUntilChanged
        } else {
            hasPendingMessages = .single(false)
        }
        
        let isTopReplyThreadMessageShown: Signal<Bool, NoError> = self.chatDisplayNode.historyNode.isTopReplyThreadMessageShown.get()
        |> distinctUntilChanged
        
        let topPinnedMessage: Signal<ChatPinnedMessage?, NoError>
        if let subject = self.subject {
            switch subject {
            case .messageOptions, .pinnedMessages, .scheduledMessages:
                topPinnedMessage = .single(nil)
            default:
                topPinnedMessage = self.topPinnedMessageSignal(latest: false)
            }
        } else {
            topPinnedMessage = self.topPinnedMessageSignal(latest: false)
        }
        
        if let peerId = self.chatLocation.peerId {
            self.chatThemeEmoticonPromise.set(self.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.ThemeEmoticon(id: peerId)))
            let chatWallpaper = self.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Wallpaper(id: peerId))
            |> take(1)
            self.chatWallpaperPromise.set(chatWallpaper)
        } else {
            self.chatThemeEmoticonPromise.set(.single(nil))
            self.chatWallpaperPromise.set(.single(nil))
        }
        
        if let peerId = self.chatLocation.peerId {
            let customEmojiAvailable: Signal<Bool, NoError> = self.context.engine.data.subscribe(
                TelegramEngine.EngineData.Item.Peer.SecretChatLayer(id: peerId)
            )
            |> map { layer -> Bool in
                guard let layer = layer else {
                    return true
                }
                
                return layer >= 144
            }
            |> distinctUntilChanged
            
            let isForum = self.context.engine.data.subscribe(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
            |> map { peer -> Bool in
                if case let .channel(channel) = peer {
                    return channel.flags.contains(.isForum)
                } else {
                    return false
                }
            }
            |> distinctUntilChanged
            
            let context = self.context
            let threadData: Signal<ChatPresentationInterfaceState.ThreadData?, NoError>
            let forumTopicData: Signal<ChatPresentationInterfaceState.ThreadData?, NoError>
            if let threadId = self.chatLocation.threadId {
                let viewKey: PostboxViewKey = .messageHistoryThreadInfo(peerId: peerId, threadId: threadId)
                threadData = context.account.postbox.combinedView(keys: [viewKey])
                |> map { views -> ChatPresentationInterfaceState.ThreadData? in
                    guard let view = views.views[viewKey] as? MessageHistoryThreadInfoView else {
                        return nil
                    }
                    guard let data = view.info?.data.get(MessageHistoryThreadData.self) else {
                        return nil
                    }
                    return ChatPresentationInterfaceState.ThreadData(title: data.info.title, icon: data.info.icon, iconColor: data.info.iconColor, isOwnedByMe: data.isOwnedByMe, isClosed: data.isClosed)
                }
                |> distinctUntilChanged
                forumTopicData = .single(nil)
            } else {
                forumTopicData = isForum
                |> mapToSignal { isForum -> Signal<ChatPresentationInterfaceState.ThreadData?, NoError> in
                    if isForum {
                        let viewKey: PostboxViewKey = .messageHistoryThreadInfo(peerId: peerId, threadId: 1)
                        return context.account.postbox.combinedView(keys: [viewKey])
                        |> map { views -> ChatPresentationInterfaceState.ThreadData? in
                            guard let view = views.views[viewKey] as? MessageHistoryThreadInfoView else {
                                return nil
                            }
                            guard let data = view.info?.data.get(MessageHistoryThreadData.self) else {
                                return nil
                            }
                            return ChatPresentationInterfaceState.ThreadData(title: data.info.title, icon: data.info.icon, iconColor: data.info.iconColor, isOwnedByMe: data.isOwnedByMe, isClosed: data.isClosed)
                        }
                        |> distinctUntilChanged
                    } else {
                        return .single(nil)
                    }
                }
                threadData = .single(nil)
            }

            if case .standard(.previewing) = self.presentationInterfaceState.mode {
                
            } else if peerId.namespace != Namespaces.Peer.SecretChat && peerId != context.account.peerId && self.subject != .scheduledMessages {
                self.premiumGiftSuggestionDisposable = (ApplicationSpecificNotice.dismissedPremiumGiftSuggestion(accountManager: self.context.sharedContext.accountManager, peerId: peerId)
                |> deliverOnMainQueue).startStrict(next: { [weak self] counter in
                    if let strongSelf = self {
                        strongSelf.updateChatPresentationInterfaceState(animated: strongSelf.willAppear, interactive: strongSelf.willAppear, { state in
                            return state.updatedSuggestPremiumGift(counter == 0)
                        })
                    }
                })
                
                var baseLanguageCode = self.presentationData.strings.baseLanguageCode
                if baseLanguageCode.contains("-") {
                    baseLanguageCode = baseLanguageCode.components(separatedBy: "-").first ?? baseLanguageCode
                }
                let isPremium = self.context.engine.data.subscribe(TelegramEngine.EngineData.Item.Peer.Peer(id: self.context.account.peerId))
                |> map { peer -> Bool in
                    return peer?.isPremium ?? false
                } |> distinctUntilChanged
                
                let isHidden = self.context.engine.data.subscribe(TelegramEngine.EngineData.Item.Peer.TranslationHidden(id: peerId))
                |> distinctUntilChanged
                self.translationStateDisposable = (combineLatest(
                    queue: .concurrentDefaultQueue(),
                    isPremium,
                    isHidden,
                    ApplicationSpecificNotice.translationSuggestion(accountManager: self.context.sharedContext.accountManager)
                ) |> mapToSignal { isPremium, isHidden, counterAndTimestamp -> Signal<ChatPresentationTranslationState?, NoError> in
                    var maybeSuggestPremium = false
                    if counterAndTimestamp.0 >= 3 {
                        maybeSuggestPremium = true
                    }
                    if (isPremium || maybeSuggestPremium) && !isHidden {
                        return chatTranslationState(context: context, peerId: peerId)
                        |> map { translationState -> ChatPresentationTranslationState? in
                            if let translationState, !translationState.fromLang.isEmpty && (translationState.fromLang != baseLanguageCode || translationState.isEnabled) {
                                return ChatPresentationTranslationState(isEnabled: translationState.isEnabled, fromLang: translationState.fromLang, toLang: translationState.toLang ?? baseLanguageCode)
                            } else {
                                return nil
                            }
                        }
                        |> distinctUntilChanged
                    } else {
                        return .single(nil)
                    }
                }
                |> deliverOnMainQueue).startStrict(next: { [weak self] chatTranslationState in
                    if let strongSelf = self {
                        strongSelf.updateChatPresentationInterfaceState(animated: strongSelf.willAppear, interactive: strongSelf.willAppear, { state in
                            return state.updatedTranslationState(chatTranslationState)
                        })
                    }
                })
            }
            
            self.cachedDataDisposable = combineLatest(queue: .mainQueue(), self.chatDisplayNode.historyNode.cachedPeerDataAndMessages,
                hasPendingMessages,
                isTopReplyThreadMessageShown,
                topPinnedMessage,
                customEmojiAvailable,
                isForum,
                threadData,
                forumTopicData
            ).startStrict(next: { [weak self] cachedDataAndMessages, hasPendingMessages, isTopReplyThreadMessageShown, topPinnedMessage, customEmojiAvailable, isForum, threadData, forumTopicData in
                if let strongSelf = self {
                    let (cachedData, messages) = cachedDataAndMessages
                    
                    if cachedData != nil {
                        var themeEmoticon: String? = nil
                        var chatWallpaper: TelegramWallpaper?
                        if let cachedData = cachedData as? CachedUserData {
                            themeEmoticon = cachedData.themeEmoticon
                            chatWallpaper = cachedData.wallpaper
                        } else if let cachedData = cachedData as? CachedGroupData {
                            themeEmoticon = cachedData.themeEmoticon
                        } else if let cachedData = cachedData as? CachedChannelData {
                            themeEmoticon = cachedData.themeEmoticon
                            chatWallpaper = cachedData.wallpaper
                        }
                        
                        strongSelf.chatThemeEmoticonPromise.set(.single(themeEmoticon))
                        strongSelf.chatWallpaperPromise.set(.single(chatWallpaper))
                    }
                    
                    var pinnedMessageId: MessageId?
                    var peerIsBlocked: Bool = false
                    var callsAvailable: Bool = false
                    var callsPrivate: Bool = false
                    var voiceMessagesAvailable: Bool = true
                    var slowmodeState: ChatSlowmodeState?
                    var activeGroupCallInfo: ChatActiveGroupCallInfo?
                    var inviteRequestsPending: Int32?
                    var premiumGiftOptions: [CachedPremiumGiftOption] = []
                    if let cachedData = cachedData as? CachedChannelData {
                        pinnedMessageId = cachedData.pinnedMessageId
                        if let channel = strongSelf.presentationInterfaceState.renderedPeer?.peer as? TelegramChannel, channel.isRestrictedBySlowmode, let timeout = cachedData.slowModeTimeout {
                            if hasPendingMessages {
                                slowmodeState = ChatSlowmodeState(timeout: timeout, variant: .pendingMessages)
                            } else if let slowmodeUntilTimestamp = calculateSlowmodeActiveUntilTimestamp(account: strongSelf.context.account, untilTimestamp: cachedData.slowModeValidUntilTimestamp) {
                                slowmodeState = ChatSlowmodeState(timeout: timeout, variant: .timestamp(slowmodeUntilTimestamp))
                            }
                        }
                        if let activeCall = cachedData.activeCall {
                            activeGroupCallInfo = ChatActiveGroupCallInfo(activeCall: activeCall)
                        }
                        inviteRequestsPending = cachedData.inviteRequestsPending
                    } else if let cachedData = cachedData as? CachedUserData {
                        peerIsBlocked = cachedData.isBlocked
                        callsAvailable = cachedData.voiceCallsAvailable
                        callsPrivate = cachedData.callsPrivate
                        pinnedMessageId = cachedData.pinnedMessageId
                        voiceMessagesAvailable = cachedData.voiceMessagesAvailable
                        premiumGiftOptions = cachedData.premiumGiftOptions
                    } else if let cachedData = cachedData as? CachedGroupData {
                        pinnedMessageId = cachedData.pinnedMessageId
                        if let activeCall = cachedData.activeCall {
                            activeGroupCallInfo = ChatActiveGroupCallInfo(activeCall: activeCall)
                        }
                        inviteRequestsPending = cachedData.inviteRequestsPending
                    } else if let _ = cachedData as? CachedSecretChatData {
                    }
                    
                    var pinnedMessage: ChatPinnedMessage?
                    switch strongSelf.chatLocation {
                    case let .replyThread(replyThreadMessage):
                        if isForum {
                            pinnedMessageId = topPinnedMessage?.message.id
                            pinnedMessage = topPinnedMessage
                        } else {
                            if isTopReplyThreadMessageShown {
                                pinnedMessageId = nil
                            } else {
                                pinnedMessageId = replyThreadMessage.effectiveTopId
                            }
                            if let pinnedMessageId = pinnedMessageId {
                                if let message = messages?[pinnedMessageId] {
                                    pinnedMessage = ChatPinnedMessage(message: message, index: 0, totalCount: 1, topMessageId: message.id)
                                }
                            }
                        }
                    case .peer:
                        pinnedMessageId = topPinnedMessage?.message.id
                        pinnedMessage = topPinnedMessage
                    case .feed:
                        pinnedMessageId = nil
                        pinnedMessage = nil
                    }
                    
                    var pinnedMessageUpdated = false
                    if let current = strongSelf.presentationInterfaceState.pinnedMessage, let updated = pinnedMessage {
                        if current != updated {
                            pinnedMessageUpdated = true
                        }
                    } else if (strongSelf.presentationInterfaceState.pinnedMessage != nil) != (pinnedMessage != nil) {
                        pinnedMessageUpdated = true
                    }
                    
                    let callsDataUpdated = strongSelf.presentationInterfaceState.callsAvailable != callsAvailable || strongSelf.presentationInterfaceState.callsPrivate != callsPrivate
                
                    let voiceMessagesAvailableUpdated = strongSelf.presentationInterfaceState.voiceMessagesAvailable != voiceMessagesAvailable
                    
                    var canManageInvitations = false
                    if let channel = strongSelf.presentationInterfaceState.renderedPeer?.peer as? TelegramChannel, channel.flags.contains(.isCreator) || (channel.adminRights?.rights.contains(.canInviteUsers) == true) {
                        canManageInvitations = true
                    } else if let group = strongSelf.presentationInterfaceState.renderedPeer?.peer as? TelegramGroup {
                        if case .creator = group.role {
                            canManageInvitations = true
                        } else if case let .admin(rights, _) = group.role, rights.rights.contains(.canInviteUsers) {
                            canManageInvitations = true
                        }
                    }
                    
                    if canManageInvitations, let inviteRequestsPending = inviteRequestsPending, inviteRequestsPending >= 0 {
                        if strongSelf.inviteRequestsContext == nil {
                            let inviteRequestsContext = strongSelf.context.engine.peers.peerInvitationImporters(peerId: peerId, subject: .requests(query: nil))
                            strongSelf.inviteRequestsContext = inviteRequestsContext
                                                    
                            strongSelf.inviteRequestsDisposable.set((combineLatest(queue: Queue.mainQueue(), inviteRequestsContext.state, ApplicationSpecificNotice.dismissedInvitationRequests(accountManager: strongSelf.context.sharedContext.accountManager, peerId: peerId))).startStrict(next: { [weak self] requestsState, dismissedInvitationRequests in
                                guard let strongSelf = self else {
                                    return
                                }
                                strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: false, { state in
                                    return state
                                    .updatedTitlePanelContext({ context in
                                        let peers: [EnginePeer] = Array(requestsState.importers.compactMap({ $0.peer.peer.flatMap({ EnginePeer($0) }) }).prefix(3))
                                        
                                        var peersDismissed = false
                                        if let dismissedInvitationRequests = dismissedInvitationRequests, Set(peers.map({ $0.id.toInt64() })) == Set(dismissedInvitationRequests) {
                                            peersDismissed = true
                                        }
                                        
                                        if requestsState.count > 0 && !peersDismissed {
                                            if !context.contains(where: {
                                                switch $0 {
                                                    case .inviteRequests(peers, requestsState.count):
                                                        return true
                                                    default:
                                                        return false
                                                }
                                            }) {
                                                var updatedContexts = context.filter { c in
                                                    if case .inviteRequests = c {
                                                        return false
                                                    } else {
                                                        return true
                                                    }
                                                }
                                                updatedContexts.append(.inviteRequests(peers, requestsState.count))
                                                return updatedContexts.sorted()
                                            } else {
                                                return context
                                            }
                                        } else {
                                            if let index = context.firstIndex(where: {
                                                switch $0 {
                                                    case .inviteRequests:
                                                        return true
                                                    default:
                                                        return false
                                                }
                                            }) {
                                                var updatedContexts = context
                                                updatedContexts.remove(at: index)
                                                return updatedContexts
                                            } else {
                                                return context
                                            }
                                        }
                                    })
                                    .updatedSlowmodeState(slowmodeState)
                                })
                            }))
                        } else if let inviteRequestsContext = strongSelf.inviteRequestsContext {
                            let _ = (inviteRequestsContext.state
                            |> take(1)
                            |> deliverOnMainQueue).startStandalone(next: { [weak inviteRequestsContext] state in
                                if state.count != inviteRequestsPending {
                                    inviteRequestsContext?.loadMore()
                                }
                            })
                        }
                    }
                
                    if strongSelf.presentationInterfaceState.pinnedMessageId != pinnedMessageId || strongSelf.presentationInterfaceState.pinnedMessage != pinnedMessage || strongSelf.presentationInterfaceState.peerIsBlocked != peerIsBlocked || pinnedMessageUpdated || callsDataUpdated || voiceMessagesAvailableUpdated || strongSelf.presentationInterfaceState.slowmodeState != slowmodeState || strongSelf.presentationInterfaceState.activeGroupCallInfo != activeGroupCallInfo || customEmojiAvailable != strongSelf.presentationInterfaceState.customEmojiAvailable || threadData != strongSelf.presentationInterfaceState.threadData || forumTopicData != strongSelf.presentationInterfaceState.forumTopicData || premiumGiftOptions != strongSelf.presentationInterfaceState.premiumGiftOptions {
                        strongSelf.updateChatPresentationInterfaceState(animated: strongSelf.willAppear, interactive: strongSelf.willAppear, { state in
                            return state
                            .updatedPinnedMessageId(pinnedMessageId)
                            .updatedActiveGroupCallInfo(activeGroupCallInfo)
                            .updatedPinnedMessage(pinnedMessage)
                            .updatedPeerIsBlocked(peerIsBlocked)
                            .updatedCallsAvailable(callsAvailable)
                            .updatedCallsPrivate(callsPrivate)
                            .updatedVoiceMessagesAvailable(voiceMessagesAvailable)
                            .updatedCustomEmojiAvailable(customEmojiAvailable)
                            .updatedThreadData(threadData)
                            .updatedForumTopicData(forumTopicData)
                            .updatedIsGeneralThreadClosed(forumTopicData?.isClosed)
                            .updatedPremiumGiftOptions(premiumGiftOptions)
                            .updatedTitlePanelContext({ context in
                                if pinnedMessageId != nil {
                                    if !context.contains(where: {
                                        switch $0 {
                                            case .pinnedMessage:
                                                return true
                                            default:
                                                return false
                                        }
                                    }) {
                                        var updatedContexts = context
                                        updatedContexts.append(.pinnedMessage)
                                        return updatedContexts.sorted()
                                    } else {
                                        return context
                                    }
                                } else {
                                    if let index = context.firstIndex(where: {
                                        switch $0 {
                                            case .pinnedMessage:
                                                return true
                                            default:
                                                return false
                                        }
                                    }) {
                                        var updatedContexts = context
                                        updatedContexts.remove(at: index)
                                        return updatedContexts
                                    } else {
                                        return context
                                    }
                                }
                            })
                            .updatedSlowmodeState(slowmodeState)
                        })
                    }
                    
                    if !strongSelf.didSetCachedDataReady {
                        strongSelf.didSetCachedDataReady = true
                        strongSelf.cachedDataReady.set(.single(true))
                    }
                }
            })
        } else {
            if !self.didSetCachedDataReady {
                self.didSetCachedDataReady = true
                self.cachedDataReady.set(.single(true))
            }
        }
        
        self.historyStateDisposable = self.chatDisplayNode.historyNode.historyState.get().startStrict(next: { [weak self] state in
            if let strongSelf = self {
                strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: strongSelf.isViewLoaded && strongSelf.view.window != nil, {
                    $0.updatedChatHistoryState(state)
                })
                
                if let botStart = strongSelf.botStart, case let .loaded(isEmpty) = state {
                    strongSelf.botStart = nil
                    if !isEmpty {
                        strongSelf.startBot(botStart.payload)
                    }
                }
            }
        })
        
        let effectiveCachedDataReady: Signal<Bool, NoError>
        if case .replyThread = self.chatLocation {
            effectiveCachedDataReady = self.cachedDataReady.get()
        } else {
            //effectiveCachedDataReady = .single(true)
            effectiveCachedDataReady = self.cachedDataReady.get()
        }
        self.ready.set(combineLatest(queue: .mainQueue(),
            self.chatDisplayNode.historyNode.historyState.get(),
            self._chatLocationInfoReady.get(),
            effectiveCachedDataReady,
            initialData,
            self.wallpaperReady.get(),
            self.presentationReady.get()
        )
        |> map { _, chatLocationInfoReady, cachedDataReady, _, wallpaperReady, presentationReady in
            return chatLocationInfoReady && cachedDataReady && wallpaperReady && presentationReady
        }
        |> distinctUntilChanged)
        
        if self.context.sharedContext.immediateExperimentalUISettings.crashOnLongQueries {
            let _ = (self.ready.get()
            |> filter({ $0 })
            |> take(1)
            |> timeout(0.8, queue: .concurrentDefaultQueue(), alternate: Signal { _ in
                preconditionFailure()
            })).startStandalone()
        }
        
        self.chatDisplayNode.historyNode.contentPositionChanged = { [weak self] offset in
            guard let strongSelf = self else { return }

            var minOffsetForNavigation: CGFloat = 40.0
            strongSelf.chatDisplayNode.historyNode.enumerateItemNodes { itemNode in
                if let itemNode = itemNode as? ChatMessageBubbleItemNode {
                    if let message = itemNode.item?.content.firstMessage, let adAttribute = message.adAttribute {
                        minOffsetForNavigation += itemNode.bounds.height

                        switch offset {
                        case let .known(offset):
                            if offset <= 50.0 {
                                strongSelf.chatDisplayNode.historyNode.markAdAsSeen(opaqueId: adAttribute.opaqueId)
                            }
                        default:
                            break
                        }
                    }
                }
                return false
            }
            
            let offsetAlpha: CGFloat
            let plainInputSeparatorAlpha: CGFloat
            switch offset {
                case let .known(offset):
                    if offset < minOffsetForNavigation {
                        offsetAlpha = 0.0
                    } else {
                        offsetAlpha = 1.0
                    }
                    if offset < 4.0 {
                        plainInputSeparatorAlpha = 0.0
                    } else {
                        plainInputSeparatorAlpha = 1.0
                    }
                case .unknown:
                    offsetAlpha = 1.0
                    plainInputSeparatorAlpha = 1.0
                case .none:
                    offsetAlpha = 0.0
                    plainInputSeparatorAlpha = 0.0
            }
            
            strongSelf.shouldDisplayDownButton = !offsetAlpha.isZero
            strongSelf.controllerInteraction?.recommendedChannelsOpenUp = !strongSelf.shouldDisplayDownButton
            strongSelf.updateDownButtonVisibility()
            strongSelf.chatDisplayNode.updatePlainInputSeparatorAlpha(plainInputSeparatorAlpha, transition: .animated(duration: 0.2, curve: .easeInOut))
        }
        
        self.chatDisplayNode.historyNode.scrolledToIndex = { [weak self] toSubject, initial in
            if let strongSelf = self, case let .message(index) = toSubject.index {
                if case let .message(messageSubject, _, _) = strongSelf.subject, initial, case let .id(messageId) = messageSubject, messageId != index.id {
                    if messageId.peerId == index.id.peerId {
                        strongSelf.present(UndoOverlayController(presentationData: strongSelf.presentationData, content: .info(title: nil, text: strongSelf.presentationData.strings.Conversation_MessageDoesntExist, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return true }), in: .current)
                    }
                } else if let controllerInteraction = strongSelf.controllerInteraction {
                    var mappedId = index.id
                    if index.timestamp == 0 {
                        if case let .replyThread(message) = strongSelf.chatLocation, let channelMessageId = message.channelMessageId {
                            mappedId = channelMessageId
                        }
                    }
                    
                    if let message = strongSelf.chatDisplayNode.historyNode.messageInCurrentHistoryView(mappedId) {
                        let highlightedState = ChatInterfaceHighlightedState(messageStableId: message.stableId, quote: toSubject.quote.flatMap { quote in ChatInterfaceHighlightedState.Quote(string: quote.string, offset: quote.offset) })
                        controllerInteraction.highlightedState = highlightedState
                        strongSelf.updateItemNodesHighlightedStates(animated: initial)
                        strongSelf.scrolledToMessageIdValue = ScrolledToMessageId(id: mappedId, allowedReplacementDirection: [])
                        
                        var hasQuote = false
                        if let quote = toSubject.quote {
                            if message.text.contains(quote.string) {
                                hasQuote = true
                            } else {
                                strongSelf.present(UndoOverlayController(presentationData: strongSelf.presentationData, content: .info(title: nil, text: strongSelf.presentationData.strings.Chat_ToastQuoteNotFound, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return true }), in: .current)
                            }
                        }
                        
                        strongSelf.messageContextDisposable.set((Signal<Void, NoError>.complete() |> delay(hasQuote ? 1.5 : 0.7, queue: Queue.mainQueue())).startStrict(completed: {
                            if let strongSelf = self, let controllerInteraction = strongSelf.controllerInteraction {
                                if controllerInteraction.highlightedState == highlightedState {
                                    controllerInteraction.highlightedState = nil
                                    strongSelf.updateItemNodesHighlightedStates(animated: true)
                                }
                            }
                        }))
                        
                        if let (messageId, params) = strongSelf.scheduledScrollToMessageId {
                            strongSelf.scheduledScrollToMessageId = nil
                            if let timecode = params.timestamp, message.id == messageId {
                                Queue.mainQueue().after(0.2) {
                                    let _ = strongSelf.controllerInteraction?.openMessage(message, OpenMessageParams(mode: .timecode(timecode)))
                                }
                            }
                        } else if case let .message(_, _, maybeTimecode) = strongSelf.subject, let timecode = maybeTimecode, initial {
                            Queue.mainQueue().after(0.2) {
                                let _ = strongSelf.controllerInteraction?.openMessage(message, OpenMessageParams(mode: .timecode(timecode)))
                            }
                        }
                    }
                }
            }
        }
        
        self.chatDisplayNode.historyNode.scrolledToSomeIndex = { [weak self] in
            guard let strongSelf = self else {
                return
            }
            strongSelf.scrolledToMessageIdValue = nil
        }
        
        self.chatDisplayNode.historyNode.maxVisibleMessageIndexUpdated = { [weak self] index in
            if let strongSelf = self, !strongSelf.historyNavigationStack.isEmpty {
                strongSelf.historyNavigationStack.filterOutIndicesLessThan(index)
            }
        }
        
        self.chatDisplayNode.requestLayout = { [weak self] transition in
            self?.requestLayout(transition: transition)
        }
        
        self.chatDisplayNode.setupSendActionOnViewUpdate = { [weak self] f, messageCorrelationId in
            //print("setup layoutActionOnViewTransition")

            self?.chatDisplayNode.historyNode.layoutActionOnViewTransition = ({ [weak self] transition in
                f()
                if let strongSelf = self, let validLayout = strongSelf.validLayout {
                    var mappedTransition: (ChatHistoryListViewTransition, ListViewUpdateSizeAndInsets?)?
                    
                    let isScheduledMessages: Bool
                    if case .scheduledMessages = strongSelf.presentationInterfaceState.subject {
                        isScheduledMessages = true
                    } else {
                        isScheduledMessages = false
                    }
                    let duration: Double = strongSelf.chatDisplayNode.messageTransitionNode.hasScheduledTransitions ? ChatMessageTransitionNodeImpl.animationDuration : 0.18
                    let curve: ContainedViewLayoutTransitionCurve = strongSelf.chatDisplayNode.messageTransitionNode.hasScheduledTransitions ? ChatMessageTransitionNodeImpl.verticalAnimationCurve : .easeInOut
                    let controlPoints: (Float, Float, Float, Float) = strongSelf.chatDisplayNode.messageTransitionNode.hasScheduledTransitions ? ChatMessageTransitionNodeImpl.verticalAnimationControlPoints : (0.5, 0.33, 0.0, 0.0)

                    let shouldUseFastMessageSendAnimation = strongSelf.chatDisplayNode.shouldUseFastMessageSendAnimation
                    
                    strongSelf.chatDisplayNode.containerLayoutUpdated(validLayout, navigationBarHeight: strongSelf.navigationLayout(layout: validLayout).navigationFrame.maxY, transition: .animated(duration: duration, curve: curve), listViewTransaction: { updateSizeAndInsets, _, _, _ in

                        var options = transition.options
                        let _ = options.insert(.Synchronous)
                        let _ = options.insert(.LowLatency)
                        let _ = options.insert(.PreferSynchronousResourceLoading)

                        var deleteItems = transition.deleteItems
                        var insertItems: [ListViewInsertItem] = []
                        var stationaryItemRange: (Int, Int)?
                        var scrollToItem: ListViewScrollToItem?

                        if shouldUseFastMessageSendAnimation {
                            options.remove(.AnimateInsertion)
                            options.insert(.RequestItemInsertionAnimations)

                            deleteItems = transition.deleteItems.map({ item in
                                return ListViewDeleteItem(index: item.index, directionHint: nil)
                            })

                            var maxInsertedItem: Int?
                            var insertedIndex: Int?
                            for i in 0 ..< transition.insertItems.count {
                                let item = transition.insertItems[i]
                                if item.directionHint == .Down && (maxInsertedItem == nil || maxInsertedItem! < item.index) {
                                    maxInsertedItem = item.index
                                }
                                insertedIndex = item.index
                                insertItems.append(ListViewInsertItem(index: item.index, previousIndex: item.previousIndex, item: item.item, directionHint: item.directionHint == .Down ? .Up : nil))
                            }

                            if isScheduledMessages, let insertedIndex = insertedIndex {
                                scrollToItem = ListViewScrollToItem(index: insertedIndex, position: .visible, animated: true, curve: .Custom(duration: duration, controlPoints.0, controlPoints.1, controlPoints.2, controlPoints.3), directionHint: .Down)
                            } else if transition.historyView.originalView.laterId == nil {
                                scrollToItem = ListViewScrollToItem(index: 0, position: .top(0.0), animated: true, curve: .Custom(duration: duration, controlPoints.0, controlPoints.1, controlPoints.2, controlPoints.3), directionHint: .Up)
                            }

                            if let maxInsertedItem = maxInsertedItem {
                                stationaryItemRange = (maxInsertedItem + 1, Int.max)
                            }
                        }
                        
                        mappedTransition = (ChatHistoryListViewTransition(historyView: transition.historyView, deleteItems: deleteItems, insertItems: insertItems, updateItems: transition.updateItems, options: options, scrollToItem: scrollToItem, stationaryItemRange: stationaryItemRange, initialData: transition.initialData, keyboardButtonsMessage: transition.keyboardButtonsMessage, cachedData: transition.cachedData, cachedDataMessages: transition.cachedDataMessages, readStateData: transition.readStateData, scrolledToIndex: transition.scrolledToIndex, scrolledToSomeIndex: transition.scrolledToSomeIndex, peerType: transition.peerType, networkType: transition.networkType, animateIn: false, reason: transition.reason, flashIndicators: transition.flashIndicators, animateFromPreviousFilter: false), updateSizeAndInsets)
                    }, updateExtraNavigationBarBackgroundHeight: { value, hitTestSlop, _ in
                        strongSelf.additionalNavigationBarBackgroundHeight = value
                        strongSelf.additionalNavigationBarHitTestSlop = hitTestSlop
                    })
                    
                    if let mappedTransition = mappedTransition {
                        return mappedTransition
                    }
                }
                return (transition, nil)
            }, messageCorrelationId)
        }
        
        self.chatDisplayNode.sendMessages = { [weak self] messages, silentPosting, scheduleTime, isAnyMessageTextPartitioned in
            if let strongSelf = self, let peerId = strongSelf.chatLocation.peerId {
                var correlationIds: [Int64] = []
                for message in messages {
                    switch message {
                    case let .message(_, _, _, _, _, _, _, _, correlationId, _):
                        if let correlationId = correlationId {
                            correlationIds.append(correlationId)
                        }
                    default:
                        break
                    }
                }
                strongSelf.commitPurposefulAction()
                
                var hasDisabledContent = false
                if "".isEmpty {
                    hasDisabledContent = false
                }
                
                if let channel = strongSelf.presentationInterfaceState.renderedPeer?.peer as? TelegramChannel, channel.isRestrictedBySlowmode {
                    let forwardCount = messages.reduce(0, { count, message -> Int in
                        if case .forward = message {
                            return count + 1
                        } else {
                            return count
                        }
                    })
                    
                    var errorText: String?
                    if forwardCount > 1 {
                        errorText = strongSelf.presentationData.strings.Chat_AttachmentMultipleForwardDisabled
                    } else if isAnyMessageTextPartitioned {
                        errorText = strongSelf.presentationData.strings.Chat_MultipleTextMessagesDisabled
                    } else if hasDisabledContent {
                        errorText = strongSelf.restrictedSendingContentsText()
                    }
                    
                    if let errorText = errorText {
                        strongSelf.present(standardTextAlertController(theme: AlertControllerTheme(presentationData: strongSelf.presentationData), title: nil, text: errorText, actions: [TextAlertAction(type: .defaultAction, title: strongSelf.presentationData.strings.Common_OK, action: {})]), in: .window(.root))
                        return
                    }
                }
                
                let transformedMessages: [EnqueueMessage]
                if let silentPosting = silentPosting {
                    transformedMessages = strongSelf.transformEnqueueMessages(messages, silentPosting: silentPosting)
                } else if let scheduleTime = scheduleTime {
                    transformedMessages = strongSelf.transformEnqueueMessages(messages, silentPosting: false, scheduleTime: scheduleTime)
                } else {
                    transformedMessages = strongSelf.transformEnqueueMessages(messages)
                }
                
                var forwardedMessages: [[EnqueueMessage]] = []
                var forwardSourcePeerIds = Set<PeerId>()
                for message in transformedMessages {
                    if case let .forward(source, _, _, _, _) = message {
                        forwardSourcePeerIds.insert(source.peerId)
                        
                        var added = false
                        if var last = forwardedMessages.last {
                            if let currentMessage = last.first, case let .forward(currentSource, _, _, _, _) = currentMessage, currentSource.peerId == source.peerId {
                                last.append(message)
                                added = true
                            }
                        }
                        if !added {
                            forwardedMessages.append([message])
                        }
                    }
                }
                
                let signal: Signal<[MessageId?], NoError>
                if forwardSourcePeerIds.count > 1 {
                    var signals: [Signal<[MessageId?], NoError>] = []
                    for messagesGroup in forwardedMessages {
                        signals.append(enqueueMessages(account: strongSelf.context.account, peerId: peerId, messages: messagesGroup))
                    }
                    signal = combineLatest(signals)
                    |> map { results in
                        var ids: [MessageId?] = []
                        for result in results {
                            ids.append(contentsOf: result)
                        }
                        return ids
                    }
                } else {
                    signal = enqueueMessages(account: strongSelf.context.account, peerId: peerId, messages: transformedMessages)
                }
                
                let _ = (signal
                |> deliverOnMainQueue).startStandalone(next: { messageIds in
                    if let strongSelf = self {
                        if case .scheduledMessages = strongSelf.presentationInterfaceState.subject {
                        } else {
                            strongSelf.chatDisplayNode.historyNode.scrollToEndOfHistory()
                        }
                    }
                })
                
                donateSendMessageIntent(account: strongSelf.context.account, sharedContext: strongSelf.context.sharedContext, intentContext: .chat, peerIds: [peerId])
                
                strongSelf.updateChatPresentationInterfaceState(interactive: true, { $0.updatedShowCommands(false) })
            }
        }
        
        self.chatDisplayNode.requestUpdateChatInterfaceState = { [weak self] transition, saveInterfaceState, f in
            self?.updateChatPresentationInterfaceState(transition: transition, interactive: true, saveInterfaceState: saveInterfaceState, { $0.updatedInterfaceState(f) })
        }
        
        self.chatDisplayNode.requestUpdateInterfaceState = { [weak self] transition, interactive, f in
            self?.updateChatPresentationInterfaceState(transition: transition, interactive: interactive, f)
        }
        
        self.chatDisplayNode.displayAttachmentMenu = { [weak self] in
            guard let strongSelf = self else {
                return
            }
            strongSelf.interfaceInteraction?.updateShowWebView { _ in
                return false
            }
            if strongSelf.presentationInterfaceState.interfaceState.editMessage == nil, let _ = strongSelf.presentationInterfaceState.slowmodeState, strongSelf.presentationInterfaceState.subject != .scheduledMessages {
                if let rect = strongSelf.chatDisplayNode.frameForAttachmentButton() {
                    strongSelf.interfaceInteraction?.displaySlowmodeTooltip(strongSelf.chatDisplayNode.view, rect)
                }
                return
            }
            if let messageId = strongSelf.presentationInterfaceState.interfaceState.editMessage?.messageId {
                let _ = (strongSelf.context.engine.data.get(TelegramEngine.EngineData.Item.Messages.Message(id: messageId))
                |> deliverOnMainQueue).startStandalone(next: { message in
                    guard let strongSelf = self, let editMessageState = strongSelf.presentationInterfaceState.editMessageState, case let .media(options) = editMessageState.content else {
                        return
                    }
                    var originalMediaReference: AnyMediaReference?
                    if let message = message {
                        for media in message.media {
                            if let image = media as? TelegramMediaImage {
                                originalMediaReference = .message(message: MessageReference(message._asMessage()), media: image)
                            } else if let file = media as? TelegramMediaFile {
                                if file.isVideo || file.isAnimated {
                                    originalMediaReference = .message(message: MessageReference(message._asMessage()), media: file)
                                }
                            }
                        }
                    }
                    strongSelf.oldPresentAttachmentMenu(editMediaOptions: options, editMediaReference: originalMediaReference)
                })
            } else {
                strongSelf.presentAttachmentMenu(subject: .default)
            }
        }
        self.chatDisplayNode.paste = { [weak self] data in
            switch data {
            case let .images(images):
                self?.displayPasteMenu(images.map { .image($0) })
            case let .video(data):
                let tempFilePath = NSTemporaryDirectory() + "\(Int64.random(in: 0...Int64.max)).mp4"
                let url = NSURL(fileURLWithPath: tempFilePath) as URL
                try? data.write(to: url)
                self?.displayPasteMenu([.video(url)])
            case let .gif(data):
                self?.enqueueGifData(data)
            case let .sticker(image, isMemoji):
                self?.enqueueStickerImage(image, isMemoji: isMemoji)
            }
        }
        self.chatDisplayNode.updateTypingActivity = { [weak self] value in
            if let strongSelf = self {
                if value {
                    strongSelf.typingActivityPromise.set(Signal<Bool, NoError>.single(true)
                    |> then(
                        Signal<Bool, NoError>.single(false)
                        |> delay(4.0, queue: Queue.mainQueue())
                    ))
                    
                    if !strongSelf.didDisplayGroupEmojiTip, value {
                        strongSelf.didDisplayGroupEmojiTip = true
                        
                        Queue.mainQueue().after(2.0) {
                            strongSelf.displayGroupEmojiTooltip()
                        }
                    }
                    
                    if !strongSelf.didDisplaySendWhenOnlineTip, value {
                        strongSelf.didDisplaySendWhenOnlineTip = true
                        
                        strongSelf.displaySendWhenOnlineTipDisposable.set(
                            (strongSelf.typingActivityPromise.get()
                            |> filter { !$0 }
                            |> take(1)
                            |> deliverOnMainQueue).start(next: { [weak self] _ in
                                if let strongSelf = self {
                                    Queue.mainQueue().after(2.0) {
                                        strongSelf.displaySendWhenOnlineTooltip()
                                    }
                                }
                            })
                        )
                    }
                } else {
                    strongSelf.typingActivityPromise.set(.single(false))
                }
            }
        }
        
        self.chatDisplayNode.dismissUrlPreview = { [weak self] in
            if let strongSelf = self {
                if let _ = strongSelf.presentationInterfaceState.interfaceState.editMessage {
                    if let link = strongSelf.presentationInterfaceState.editingUrlPreview?.url {
                        strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, { presentationInterfaceState in
                            return presentationInterfaceState.updatedInterfaceState { interfaceState in
                                return interfaceState.withUpdatedEditMessage(interfaceState.editMessage.flatMap { editMessage in
                                    var editMessage = editMessage
                                    if !editMessage.disableUrlPreviews.contains(link) {
                                        editMessage.disableUrlPreviews.append(link)
                                    }
                                    return editMessage
                                })
                            }
                        })
                    }
                } else {
                    if let link = strongSelf.presentationInterfaceState.urlPreview?.url {
                        strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, { presentationInterfaceState in
                            return presentationInterfaceState.updatedInterfaceState { interfaceState in
                                var composeDisableUrlPreviews = interfaceState.composeDisableUrlPreviews
                                if !composeDisableUrlPreviews.contains(link) {
                                    composeDisableUrlPreviews.append(link)
                                }
                                return interfaceState.withUpdatedComposeDisableUrlPreviews(composeDisableUrlPreviews)
                            }
                        })
                    }
                }
            }
        }
        
        self.chatDisplayNode.navigateButtons.downPressed = { [weak self] in
            guard let self else {
                return
            }
            
            if self.presentationInterfaceState.search?.resultsState != nil {
                self.interfaceInteraction?.navigateMessageSearch(.later)
            } else {
                if let messageId = self.historyNavigationStack.removeLast() {
                    self.navigateToMessage(from: nil, to: .id(messageId.id, NavigateToMessageParams(timestamp: nil, quote: nil)), rememberInStack: false)
                } else {
                    if case .known = self.chatDisplayNode.historyNode.visibleContentOffset() {
                        self.chatDisplayNode.historyNode.scrollToEndOfHistory()
                    } else if case .peer = self.chatLocation {
                        self.scrollToEndOfHistory()
                    } else if case .replyThread = self.chatLocation {
                        self.scrollToEndOfHistory()
                    } else {
                        self.chatDisplayNode.historyNode.scrollToEndOfHistory()
                    }
                }
            }
        }
        self.chatDisplayNode.navigateButtons.upPressed = { [weak self] in
            guard let self else {
                return
            }
            
            if self.presentationInterfaceState.search?.resultsState != nil {
                self.interfaceInteraction?.navigateMessageSearch(.earlier)
            }
        }
        
        self.chatDisplayNode.navigateButtons.mentionsPressed = { [weak self] in
            if let strongSelf = self, strongSelf.isNodeLoaded, let peerId = strongSelf.chatLocation.peerId {
                let signal = strongSelf.context.engine.messages.earliestUnseenPersonalMentionMessage(peerId: peerId, threadId: strongSelf.chatLocation.threadId)
                strongSelf.navigationActionDisposable.set((signal |> deliverOnMainQueue).startStrict(next: { result in
                    if let strongSelf = self {
                        switch result {
                            case let .result(messageId):
                                if let messageId = messageId {
                                    strongSelf.navigateToMessage(from: nil, to: .id(messageId, NavigateToMessageParams(timestamp: nil, quote: nil)))
                                }
                            case .loading:
                                break
                        }
                    }
                }))
            }
        }
        
        self.chatDisplayNode.navigateButtons.mentionsButton.activated = { [weak self] gesture, _ in
            guard let strongSelf = self else {
                gesture.cancel()
                return
            }
            
            strongSelf.chatDisplayNode.messageTransitionNode.dismissMessageReactionContexts()
            
            var menuItems: [ContextMenuItem] = []
            menuItems.append(.action(ContextMenuActionItem(
                id: nil,
                text: strongSelf.presentationData.strings.WebSearch_RecentSectionClear,
                textColor: .primary,
                textLayout: .singleLine,
                icon: { theme in
                    return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Read"), color: theme.contextMenu.primaryColor)
                },
                action: { _, f in
                    f(.dismissWithoutContent)
                    
                    guard let strongSelf = self, let peerId = strongSelf.chatLocation.peerId else {
                        return
                    }
                    let _ = clearPeerUnseenPersonalMessagesInteractively(account: strongSelf.context.account, peerId: peerId, threadId: strongSelf.chatLocation.threadId).startStandalone()
                }
            )))
            let items = ContextController.Items(content: .list(menuItems))
            
            let controller = ContextController(presentationData: strongSelf.presentationData, source: .extracted(ChatMessageNavigationButtonContextExtractedContentSource(chatNode: strongSelf.chatDisplayNode, contentNode: strongSelf.chatDisplayNode.navigateButtons.mentionsButton.containerNode)), items: .single(items), recognizer: nil, gesture: gesture)
            
            strongSelf.forEachController({ controller in
                if let controller = controller as? TooltipScreen {
                    controller.dismiss()
                }
                return true
            })
            strongSelf.window?.presentInGlobalOverlay(controller)
        }
        
        self.chatDisplayNode.navigateButtons.reactionsPressed = { [weak self] in
            if let strongSelf = self, strongSelf.isNodeLoaded, let peerId = strongSelf.chatLocation.peerId {
                let signal = strongSelf.context.engine.messages.earliestUnseenPersonalReactionMessage(peerId: peerId, threadId: strongSelf.chatLocation.threadId)
                strongSelf.navigationActionDisposable.set((signal |> deliverOnMainQueue).startStrict(next: { result in
                    if let strongSelf = self {
                        switch result {
                            case let .result(messageId):
                                if let messageId = messageId {
                                    strongSelf.chatDisplayNode.historyNode.suspendReadingReactions = true
                                    strongSelf.navigateToMessage(from: nil, to: .id(messageId, NavigateToMessageParams(timestamp: nil, quote: nil)), scrollPosition: .center(.top), completion: {
                                        guard let strongSelf = self else {
                                            return
                                        }
                                        strongSelf.chatDisplayNode.historyNode.forEachItemNode { itemNode in
                                            guard let itemNode = itemNode as? ChatMessageItemView, let item = itemNode.item else {
                                                return
                                            }
                                            guard item.message.id == messageId else {
                                                return
                                            }
                                            var maybeUpdatedReaction: (MessageReaction.Reaction, Bool, EnginePeer?)?
                                            if let attribute = item.message.reactionsAttribute {
                                                for recentPeer in attribute.recentPeers {
                                                    if recentPeer.isUnseen {
                                                        maybeUpdatedReaction = (recentPeer.value, recentPeer.isLarge, item.message.peers[recentPeer.peerId].flatMap(EnginePeer.init))
                                                        break
                                                    }
                                                }
                                            }
                                            
                                            guard let (updatedReaction, updatedReactionIsLarge, updatedReactionPeer) = maybeUpdatedReaction else {
                                                return
                                            }
                                            
                                            guard let availableReactions = item.associatedData.availableReactions else {
                                                return
                                            }
                                            
                                            var avatarPeers: [EnginePeer] = []
                                            if item.message.id.peerId.namespace != Namespaces.Peer.CloudUser, let updatedReactionPeer = updatedReactionPeer {
                                                avatarPeers.append(updatedReactionPeer)
                                            }
                                            
                                            var reactionItem: ReactionItem?
                                            
                                            switch updatedReaction {
                                            case .builtin:
                                                for reaction in availableReactions.reactions {
                                                    guard let centerAnimation = reaction.centerAnimation else {
                                                        continue
                                                    }
                                                    guard let aroundAnimation = reaction.aroundAnimation else {
                                                        continue
                                                    }
                                                    if reaction.value == updatedReaction {
                                                        reactionItem = ReactionItem(
                                                            reaction: ReactionItem.Reaction(rawValue: reaction.value),
                                                            appearAnimation: reaction.appearAnimation,
                                                            stillAnimation: reaction.selectAnimation,
                                                            listAnimation: centerAnimation,
                                                            largeListAnimation: reaction.activateAnimation,
                                                            applicationAnimation: aroundAnimation,
                                                            largeApplicationAnimation: reaction.effectAnimation,
                                                            isCustom: false
                                                        )
                                                        break
                                                    }
                                                }
                                            case let .custom(fileId):
                                                if let itemFile = item.message.associatedMedia[MediaId(namespace: Namespaces.Media.CloudFile, id: fileId)] as? TelegramMediaFile {
                                                    reactionItem = ReactionItem(
                                                        reaction: ReactionItem.Reaction(rawValue: updatedReaction),
                                                        appearAnimation: itemFile,
                                                        stillAnimation: itemFile,
                                                        listAnimation: itemFile,
                                                        largeListAnimation: itemFile,
                                                        applicationAnimation: nil,
                                                        largeApplicationAnimation: nil,
                                                        isCustom: true
                                                    )
                                                }
                                            }
                                            
                                            guard let targetView = itemNode.targetReactionView(value: updatedReaction) else {
                                                return
                                            }
                                            if let reactionItem = reactionItem {
                                                let standaloneReactionAnimation = StandaloneReactionAnimation(genericReactionEffect: strongSelf.chatDisplayNode.historyNode.takeGenericReactionEffect())
                                                
                                                strongSelf.chatDisplayNode.messageTransitionNode.addMessageStandaloneReactionAnimation(messageId: item.message.id, standaloneReactionAnimation: standaloneReactionAnimation)
                                                
                                                strongSelf.chatDisplayNode.addSubnode(standaloneReactionAnimation)
                                                standaloneReactionAnimation.frame = strongSelf.chatDisplayNode.bounds
                                                standaloneReactionAnimation.animateReactionSelection(
                                                    context: strongSelf.context,
                                                    theme: strongSelf.presentationData.theme,
                                                    animationCache: strongSelf.controllerInteraction!.presentationContext.animationCache,
                                                    reaction: reactionItem,
                                                    avatarPeers: avatarPeers,
                                                    playHaptic: true,
                                                    isLarge: updatedReactionIsLarge,
                                                    targetView: targetView,
                                                    addStandaloneReactionAnimation: { standaloneReactionAnimation in
                                                        guard let strongSelf = self else {
                                                            return
                                                        }
                                                        strongSelf.chatDisplayNode.messageTransitionNode.addMessageStandaloneReactionAnimation(messageId: item.message.id, standaloneReactionAnimation: standaloneReactionAnimation)
                                                        standaloneReactionAnimation.frame = strongSelf.chatDisplayNode.bounds
                                                        strongSelf.chatDisplayNode.addSubnode(standaloneReactionAnimation)
                                                    },
                                                    completion: { [weak standaloneReactionAnimation] in
                                                        standaloneReactionAnimation?.removeFromSupernode()
                                                    }
                                                )
                                            }
                                        }
                                        
                                        strongSelf.chatDisplayNode.historyNode.suspendReadingReactions = false
                                    })
                                }
                            case .loading:
                                break
                        }
                    }
                }))
            }
        }
        
        self.chatDisplayNode.navigateButtons.reactionsButton.activated = { [weak self] gesture, _ in
            guard let strongSelf = self else {
                gesture.cancel()
                return
            }
            
            strongSelf.chatDisplayNode.messageTransitionNode.dismissMessageReactionContexts()
            
            var menuItems: [ContextMenuItem] = []
            menuItems.append(.action(ContextMenuActionItem(
                id: nil,
                text: strongSelf.presentationData.strings.Conversation_ReadAllReactions,
                textColor: .primary,
                textLayout: .singleLine,
                icon: { theme in
                    return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Read"), color: theme.contextMenu.primaryColor)
                },
                action: { _, f in
                    f(.dismissWithoutContent)
                    
                    guard let strongSelf = self, let peerId = strongSelf.chatLocation.peerId else {
                        return
                    }
                    let _ = clearPeerUnseenReactionsInteractively(account: strongSelf.context.account, peerId: peerId, threadId: strongSelf.chatLocation.threadId).startStandalone()
                }
            )))
            let items = ContextController.Items(content: .list(menuItems))
            
            let controller = ContextController(presentationData: strongSelf.presentationData, source: .extracted(ChatMessageNavigationButtonContextExtractedContentSource(chatNode: strongSelf.chatDisplayNode, contentNode: strongSelf.chatDisplayNode.navigateButtons.reactionsButton.containerNode)), items: .single(items), recognizer: nil, gesture: gesture)
            
            strongSelf.forEachController({ controller in
                if let controller = controller as? TooltipScreen {
                    controller.dismiss()
                }
                return true
            })
            strongSelf.window?.presentInGlobalOverlay(controller)
        }
        
        let interfaceInteraction = ChatPanelInterfaceInteraction(setupReplyMessage: { [weak self] messageId, completion in
            guard let strongSelf = self, strongSelf.isNodeLoaded else {
                return
            }
            if let messageId = messageId {
                if canSendMessagesToChat(strongSelf.presentationInterfaceState) {
                    let _ = strongSelf.presentVoiceMessageDiscardAlert(action: {
                        if let message = strongSelf.chatDisplayNode.historyNode.messageInCurrentHistoryView(messageId) {
                            strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, { $0.updatedInterfaceState({
                                $0.withUpdatedReplyMessageSubject(ChatInterfaceState.ReplyMessageSubject(
                                    messageId: message.id,
                                    quote: nil
                                ))
                            }).updatedReplyMessage(message).updatedSearch(nil).updatedShowCommands(false) }, completion: { t in
                                completion(t, {})
                            })
                            strongSelf.updateItemNodesSearchTextHighlightStates()
                            strongSelf.chatDisplayNode.ensureInputViewFocused()
                        } else {
                            completion(.immediate, {})
                        }
                    }, alertAction: {
                        completion(.immediate, {})
                    }, delay: true)
                } else {
                    let replySubject = ChatInterfaceState.ReplyMessageSubject(
                        messageId: messageId,
                        quote: nil
                    )
                    completion(.immediate, {
                        guard let self else {
                            return
                        }
                        moveReplyMessageToAnotherChat(selfController: self, replySubject: replySubject)
                    })
                }
            } else {
                strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, { $0.updatedInterfaceState({ $0.withUpdatedReplyMessageSubject(nil) }) }, completion: { t in
                    completion(t, {})
                })
            }
        }, setupEditMessage: { [weak self] messageId, completion in
            if let strongSelf = self, strongSelf.isNodeLoaded {
                guard let messageId = messageId else {
                    strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, { state in
                        var state = state
                        state = state.updatedInterfaceState {
                            $0.withUpdatedEditMessage(nil)
                        }
                        state = state.updatedEditMessageState(nil)
                        return state
                    }, completion: completion)
                    
                    return
                }
                let _ = strongSelf.presentVoiceMessageDiscardAlert(action: {
                    if let message = strongSelf.chatDisplayNode.historyNode.messageInCurrentHistoryView(messageId) {
                        strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, { state in
                            var entities: [MessageTextEntity] = []
                            for attribute in message.attributes {
                                if let attribute = attribute as? TextEntitiesMessageAttribute {
                                    entities = attribute.entities
                                    break
                                }
                            }
                            var inputTextMaxLength: Int32 = 4096
                            var webpageUrl: String?
                            for media in message.media {
                                if media is TelegramMediaImage || media is TelegramMediaFile {
                                    inputTextMaxLength = strongSelf.context.userLimits.maxCaptionLength
                                } else if let webpage = media as? TelegramMediaWebpage, case let .Loaded(content) = webpage.content {
                                    webpageUrl = content.url
                                }
                            }
                            
                            let inputText = chatInputStateStringWithAppliedEntities(message.text, entities: entities)
                            var disableUrlPreviews: [String] = []
                            if webpageUrl == nil {
                                disableUrlPreviews = detectUrls(inputText)
                            }
                            
                            var updated = state.updatedInterfaceState { interfaceState in
                                return interfaceState.withUpdatedEditMessage(ChatEditMessageState(messageId: messageId, inputState: ChatTextInputState(inputText: inputText), disableUrlPreviews: disableUrlPreviews, inputTextMaxLength: inputTextMaxLength))
                            }
                            
                            updated = updatedChatEditInterfaceMessageState(state: updated, message: message)
                            updated = updated.updatedInputMode({ _ in
                                return .text
                            })
                            updated = updated.updatedShowCommands(false)
                            
                            return updated
                        }, completion: completion)
                    }
                }, alertAction: {
                    completion(.immediate)
                }, delay: true)
            }
        }, beginMessageSelection: { [weak self] messageIds, completion in
            if let strongSelf = self, strongSelf.isNodeLoaded {
                let _ = strongSelf.presentVoiceMessageDiscardAlert(action: {
                    strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, { $0.updatedInterfaceState { $0.withUpdatedSelectedMessages(messageIds) }.updatedShowCommands(false) }, completion: completion)
                    
                    if let selectionState = strongSelf.presentationInterfaceState.interfaceState.selectionState {
                        let count = selectionState.selectedIds.count
                        let text = strongSelf.presentationData.strings.VoiceOver_Chat_MessagesSelected(Int32(count))
                        UIAccessibility.post(notification: UIAccessibility.Notification.announcement, argument: text)
                    }
                }, alertAction: {
                    completion(.immediate)
                }, delay: true)
            } else {
                completion(.immediate)
            }
        }, deleteSelectedMessages: { [weak self] in
            if let strongSelf = self {
                if let messageIds = strongSelf.presentationInterfaceState.interfaceState.selectionState?.selectedIds, !messageIds.isEmpty {
                    strongSelf.messageContextDisposable.set((strongSelf.context.sharedContext.chatAvailableMessageActions(engine: strongSelf.context.engine, accountPeerId: strongSelf.context.account.peerId, messageIds: messageIds)
                    |> deliverOnMainQueue).startStrict(next: { actions in
                        if let strongSelf = self, !actions.options.isEmpty {
                            if let banAuthor = actions.banAuthor {
                                strongSelf.presentBanMessageOptions(accountPeerId: strongSelf.context.account.peerId, author: banAuthor, messageIds: messageIds, options: actions.options)
                            } else {
                                if actions.options.intersection([.deleteLocally, .deleteGlobally]).isEmpty {
                                    strongSelf.presentClearCacheSuggestion()
                                } else {
                                    strongSelf.presentDeleteMessageOptions(messageIds: messageIds, options: actions.options, contextController: nil, completion: { _ in })
                                }
                            }
                        }
                    }))
                }
            }
        }, reportSelectedMessages: { [weak self] in
            if let strongSelf = self, let messageIds = strongSelf.presentationInterfaceState.interfaceState.selectionState?.selectedIds, !messageIds.isEmpty {
                if let reportReason = strongSelf.presentationInterfaceState.reportReason {
                    let presentationData = strongSelf.presentationData
                    let controller = ActionSheetController(presentationData: presentationData, allowInputInset: true)
                    let dismissAction: () -> Void = { [weak self, weak controller] in
                        self?.view.window?.endEditing(true)
                        controller?.dismissAnimated()
                    }
                    var message = ""
                    var items: [ActionSheetItem] = []
                    items.append(ReportPeerHeaderActionSheetItem(context: strongSelf.context, text: presentationData.strings.Report_AdditionalDetailsText))
                    items.append(ReportPeerDetailsActionSheetItem(context: strongSelf.context, theme: presentationData.theme, placeholderText: presentationData.strings.Report_AdditionalDetailsPlaceholder, textUpdated: { text in
                        message = text
                    }))
                    items.append(ActionSheetButtonItem(title: presentationData.strings.Report_Report, color: .accent, font: .bold, enabled: true, action: {
                        dismissAction()
                        strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, { $0.updatedInterfaceState { $0.withoutSelectionState() } }, completion: { _ in
                            let _ = (strongSelf.context.engine.peers.reportPeerMessages(messageIds: Array(messageIds), reason: reportReason, message: message)
                            |> deliverOnMainQueue).startStandalone(completed: {
                                strongSelf.present(UndoOverlayController(presentationData: presentationData, content: .emoji(name: "PoliceCar", text: presentationData.strings.Report_Succeed), elevatedLayout: false, action: { _ in return false }), in: .current)
                            })
                        })
                    }))
                    
                    controller.setItemGroups([
                        ActionSheetItemGroup(items: items),
                        ActionSheetItemGroup(items: [ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, action: { dismissAction() })])
                    ])
                    strongSelf.present(controller, in: .window(.root))
                } else {
                    strongSelf.present(peerReportOptionsController(context: strongSelf.context, subject: .messages(Array(messageIds).sorted()), passthrough: false, present: { c, a in
                        self?.present(c, in: .window(.root), with: a)
                    }, push: { c in
                        self?.push(c)
                    }, completion: { _, done in
                        if done {
                            strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, { $0.updatedInterfaceState { $0.withoutSelectionState() } })
                        }
                    }), in: .window(.root))
                }
            }
        }, reportMessages: { [weak self] messages, contextController in
            if let strongSelf = self, !messages.isEmpty {
                let options: [PeerReportOption] = [.spam, .violence, .pornography, .childAbuse, .copyright, .illegalDrugs, .personalDetails, .other]
                presentPeerReportOptions(context: strongSelf.context, parent: strongSelf, contextController: contextController, subject: .messages(messages.map({ $0.id }).sorted()), options: options, completion: { _, _ in })
            }
        }, blockMessageAuthor: { [weak self] message, contextController in
            contextController?.dismiss(completion: {
                guard let strongSelf = self else {
                    return
                }
                
                let author = message.forwardInfo?.author
                
                guard let peer = author else {
                    return
                }
                
                let presentationData = strongSelf.presentationData
                let controller = ActionSheetController(presentationData: presentationData)
                let dismissAction: () -> Void = { [weak controller] in
                    controller?.dismissAnimated()
                }
                var reportSpam = true
                var items: [ActionSheetItem] = []
                items.append(ActionSheetTextItem(title: presentationData.strings.UserInfo_BlockConfirmationTitle(EnginePeer(peer).compactDisplayTitle).string))
                items.append(contentsOf: [
                    ActionSheetCheckboxItem(title: presentationData.strings.Conversation_Moderate_Report, label: "", value: reportSpam, action: { [weak controller] checkValue in
                        reportSpam = checkValue
                        controller?.updateItem(groupIndex: 0, itemIndex: 1, { item in
                            if let item = item as? ActionSheetCheckboxItem {
                                return ActionSheetCheckboxItem(title: item.title, label: item.label, value: !item.value, action: item.action)
                            }
                            return item
                        })
                    }),
                    ActionSheetButtonItem(title: presentationData.strings.Replies_BlockAndDeleteRepliesActionTitle, color: .destructive, action: {
                        dismissAction()
                        guard let strongSelf = self else {
                            return
                        }
                        let _ = strongSelf.context.engine.privacy.requestUpdatePeerIsBlocked(peerId: peer.id, isBlocked: true).startStandalone()
                        let context = strongSelf.context
                        let _ = context.engine.messages.deleteAllMessagesWithForwardAuthor(peerId: message.id.peerId, forwardAuthorId: peer.id, namespace: Namespaces.Message.Cloud).startStandalone()
                        let _ = strongSelf.context.engine.peers.reportRepliesMessage(messageId: message.id, deleteMessage: true, deleteHistory: true, reportSpam: reportSpam).startStandalone()
                    })
                ] as [ActionSheetItem])
                
                controller.setItemGroups([
                    ActionSheetItemGroup(items: items),
                ActionSheetItemGroup(items: [ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, action: { dismissAction() })])
                ])
                strongSelf.present(controller, in: .window(.root), with: ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
            })
        }, deleteMessages: { [weak self] messages, contextController, completion in
            if let strongSelf = self, !messages.isEmpty {
                let messageIds = Set(messages.map { $0.id })
                strongSelf.messageContextDisposable.set((strongSelf.context.sharedContext.chatAvailableMessageActions(engine: strongSelf.context.engine, accountPeerId: strongSelf.context.account.peerId, messageIds: messageIds)
                |> deliverOnMainQueue).startStrict(next: { actions in
                    if let strongSelf = self, !actions.options.isEmpty {
                        if let banAuthor = actions.banAuthor {
                            if let contextController = contextController {
                                contextController.dismiss(completion: {
                                    guard let strongSelf = self else {
                                        return
                                    }
                                    strongSelf.presentBanMessageOptions(accountPeerId: strongSelf.context.account.peerId, author: banAuthor, messageIds: messageIds, options: actions.options)
                                })
                            } else {
                                strongSelf.presentBanMessageOptions(accountPeerId: strongSelf.context.account.peerId, author: banAuthor, messageIds: messageIds, options: actions.options)
                                completion(.default)
                            }
                        } else {
                            var isAction = false
                            if messages.count == 1 {
                                for media in messages[0].media {
                                    if media is TelegramMediaAction {
                                        isAction = true
                                    }
                                }
                            }
                            if isAction && (actions.options == .deleteGlobally || actions.options == .deleteLocally) {
                                let _ = strongSelf.context.engine.messages.deleteMessagesInteractively(messageIds: Array(messageIds), type: actions.options == .deleteLocally ? .forLocalPeer : .forEveryone).startStandalone()
                                completion(.dismissWithoutContent)
                            } else if (messages.first?.flags.isSending ?? false) {
                                let _ = strongSelf.context.engine.messages.deleteMessagesInteractively(messageIds: Array(messageIds), type: .forEveryone, deleteAllInGroup: true).startStandalone()
                                completion(.dismissWithoutContent)
                            } else {
                                if actions.options.intersection([.deleteLocally, .deleteGlobally]).isEmpty {
                                    strongSelf.presentClearCacheSuggestion()
                                    completion(.default)
                                } else {
                                    var isScheduled = false
                                    for id in messageIds {
                                        if Namespaces.Message.allScheduled.contains(id.namespace) {
                                            isScheduled = true
                                            break
                                        }
                                    }
                                    strongSelf.presentDeleteMessageOptions(messageIds: messageIds, options: isScheduled ? [.deleteLocally] : actions.options, contextController: contextController, completion: completion)
                                }
                            }
                        }
                    }
                }))
            }
        }, forwardSelectedMessages: { [weak self] in
            if let strongSelf = self {
                strongSelf.commitPurposefulAction()
                if let forwardMessageIdsSet = strongSelf.presentationInterfaceState.interfaceState.selectionState?.selectedIds {
                    let forwardMessageIds = Array(forwardMessageIdsSet).sorted()
                    strongSelf.forwardMessages(messageIds: forwardMessageIds)
                }
            }
        }, forwardCurrentForwardMessages: { [weak self] in
            if let strongSelf = self {
                strongSelf.commitPurposefulAction()
                if let forwardMessageIds = strongSelf.presentationInterfaceState.interfaceState.forwardMessageIds {
                    strongSelf.forwardMessages(messageIds: forwardMessageIds, options: strongSelf.presentationInterfaceState.interfaceState.forwardOptionsState, resetCurrent: true)
                }
            }
        }, forwardMessages: { [weak self] messages in
            if let strongSelf = self, !messages.isEmpty {
                strongSelf.commitPurposefulAction()
                let forwardMessageIds = messages.map { $0.id }.sorted()
                strongSelf.forwardMessages(messageIds: forwardMessageIds)
            }
        }, updateForwardOptionsState: { [weak self] f in
            if let strongSelf = self {
                strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, { $0.updatedInterfaceState({ $0.withUpdatedForwardOptionsState(f($0.forwardOptionsState ?? ChatInterfaceForwardOptionsState(hideNames: false, hideCaptions: false, unhideNamesOnCaptionChange: false))) }) })
            }
        }, presentForwardOptions: { [weak self] sourceNode in
            guard let self else {
                return
            }
            presentChatForwardOptions(selfController: self, sourceNode: sourceNode)
        }, presentReplyOptions: { [weak self] sourceNode in
            guard let self else {
                return
            }
            presentChatReplyOptions(selfController: self, sourceNode: sourceNode)
        }, presentLinkOptions: { [weak self] sourceNode in
            guard let self else {
                return
            }
            presentChatLinkOptions(selfController: self, sourceNode: sourceNode)
        }, shareSelectedMessages: { [weak self] in
            if let strongSelf = self, let selectedIds = strongSelf.presentationInterfaceState.interfaceState.selectionState?.selectedIds, !selectedIds.isEmpty {
                strongSelf.commitPurposefulAction()
                let _ = (strongSelf.context.engine.data.get(EngineDataMap(
                    selectedIds.map(TelegramEngine.EngineData.Item.Messages.Message.init)
                ))
                |> map { messages -> [EngineMessage] in
                    return messages.values.compactMap { $0 }
                }
                |> deliverOnMainQueue).startStandalone(next: { messages in
                    if let strongSelf = self, !messages.isEmpty {
                        strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, { $0.updatedInterfaceState({ $0.withoutSelectionState() }) })
                        
                        let shareController = ShareController(context: strongSelf.context, subject: .messages(messages.sorted(by: { lhs, rhs in
                            return lhs.index < rhs.index
                        }).map { $0._asMessage() }), externalShare: true, immediateExternalShare: true, updatedPresentationData: strongSelf.updatedPresentationData)
                        strongSelf.chatDisplayNode.dismissInput()
                        strongSelf.present(shareController, in: .window(.root))
                    }
                })
            }
        }, updateTextInputStateAndMode: { [weak self] f in
            if let strongSelf = self {
                strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, { state in
                    let (updatedState, updatedMode) = f(state.interfaceState.effectiveInputState, state.inputMode)
                    return state.updatedInterfaceState { interfaceState in
                        return interfaceState.withUpdatedEffectiveInputState(updatedState)
                        }.updatedInputMode({ _ in updatedMode })
                })
                
                if !strongSelf.presentationInterfaceState.interfaceState.effectiveInputState.inputText.string.isEmpty {
                    strongSelf.silentPostTooltipController?.dismiss()
                }
            }
        }, updateInputModeAndDismissedButtonKeyboardMessageId: { [weak self] f in
            if let strongSelf = self {
                strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, {
                    let (updatedInputMode, updatedClosedButtonKeyboardMessageId) = f($0)
                    var updated = $0.updatedInputMode({ _ in return updatedInputMode }).updatedInterfaceState({
                        $0.withUpdatedMessageActionsState({ value in
                            var value = value
                            value.closedButtonKeyboardMessageId = updatedClosedButtonKeyboardMessageId
                            return value
                        })
                    })
                    var dismissWebView = false
                    switch updatedInputMode {
                        case .text, .media, .inputButtons:
                            dismissWebView = true
                        default:
                            break
                    }
                    if dismissWebView {
                        updated = updated.updatedShowWebView(false)
                    }
                    return updated
                })
            }
        }, openStickers: { [weak self] in
            guard let strongSelf = self else {
                return
            }
            strongSelf.chatDisplayNode.openStickers(beginWithEmoji: false)
            strongSelf.mediaRecordingModeTooltipController?.dismissImmediately()
        }, editMessage: { [weak self] in
            guard let strongSelf = self, let editMessage = strongSelf.presentationInterfaceState.interfaceState.editMessage else {
                return
            }
            
            let _ = (strongSelf.context.engine.data.get(TelegramEngine.EngineData.Item.Messages.Message(id: editMessage.messageId))
            |> deliverOnMainQueue).start(next: { [weak strongSelf] message in
                guard let strongSelf, let message else {
                    return
                }
                
                var disableUrlPreview = false
                
                var webpage: TelegramMediaWebpage?
                var webpagePreviewAttribute: WebpagePreviewMessageAttribute?
                if let urlPreview = strongSelf.presentationInterfaceState.editingUrlPreview {
                    if editMessage.disableUrlPreviews.contains(urlPreview.url) {
                        disableUrlPreview = true
                    } else {
                        webpage = urlPreview.webPage
                        webpagePreviewAttribute = WebpagePreviewMessageAttribute(leadingPreview: !urlPreview.positionBelowText, forceLargeMedia: urlPreview.largeMedia, isManuallyAdded: true, isSafe: false)
                    }
                }
                
                let text = trimChatInputText(convertMarkdownToAttributes(editMessage.inputState.inputText))
                
                let entities = generateTextEntities(text.string, enabledTypes: .all, currentEntities: generateChatInputTextEntities(text))
                var entitiesAttribute: TextEntitiesMessageAttribute?
                if !entities.isEmpty {
                    entitiesAttribute = TextEntitiesMessageAttribute(entities: entities)
                }
                
                var inlineStickers: [MediaId: TelegramMediaFile] = [:]
                var firstLockedPremiumEmoji: TelegramMediaFile?
                text.enumerateAttribute(ChatTextInputAttributes.customEmoji, in: NSRange(location: 0, length: text.length), using: { value, _, _ in
                    if let value = value as? ChatTextInputTextCustomEmojiAttribute {
                        if let file = value.file {
                            inlineStickers[file.fileId] = file
                            if file.isPremiumEmoji && !strongSelf.presentationInterfaceState.isPremium && strongSelf.chatLocation.peerId != strongSelf.context.account.peerId {
                                if firstLockedPremiumEmoji == nil {
                                    firstLockedPremiumEmoji = file
                                }
                            }
                        }
                    }
                })
                
                if let firstLockedPremiumEmoji = firstLockedPremiumEmoji {
                    let presentationData = strongSelf.context.sharedContext.currentPresentationData.with { $0 }
                    strongSelf.controllerInteraction?.displayUndo(.sticker(context: strongSelf.context, file: firstLockedPremiumEmoji, loop: true, title: nil, text: presentationData.strings.EmojiInput_PremiumEmojiToast_Text, undoText: presentationData.strings.EmojiInput_PremiumEmojiToast_Action, customAction: {
                        guard let strongSelf = self else {
                            return
                        }
                        strongSelf.chatDisplayNode.dismissTextInput()
                        
                        var replaceImpl: ((ViewController) -> Void)?
                        let controller = PremiumDemoScreen(context: strongSelf.context, subject: .animatedEmoji, action: {
                            let controller = PremiumIntroScreen(context: strongSelf.context, source: .animatedEmoji)
                            replaceImpl?(controller)
                        })
                        replaceImpl = { [weak controller] c in
                            controller?.replace(with: c)
                        }
                        strongSelf.present(controller, in: .window(.root), with: nil)
                    }))
                    
                    return
                }
                
                if text.length == 0 {
                    if strongSelf.presentationInterfaceState.editMessageState?.mediaReference != nil {
                    } else if message.media.contains(where: { media in
                        switch media {
                        case _ as TelegramMediaImage, _ as TelegramMediaFile, _ as TelegramMediaMap:
                            return true
                        default:
                            return false
                        }
                    }) {
                    } else {
                        if strongSelf.recordingModeFeedback == nil {
                            strongSelf.recordingModeFeedback = HapticFeedback()
                            strongSelf.recordingModeFeedback?.prepareError()
                        }
                        strongSelf.recordingModeFeedback?.error()
                        return
                    }
                }
                
                var updatingMedia = false
                let media: RequestEditMessageMedia
                if let editMediaReference = strongSelf.presentationInterfaceState.editMessageState?.mediaReference {
                    media = .update(editMediaReference)
                    updatingMedia = true
                } else if let webpage {
                    media = .update(.standalone(media: webpage))
                } else {
                    media = .keep
                }
                
                let _ = (strongSelf.context.account.postbox.messageAtId(editMessage.messageId)
                |> deliverOnMainQueue)
                .startStandalone(next: { [weak self] currentMessage in
                    if let strongSelf = self {
                        if let currentMessage = currentMessage {
                            let currentEntities = currentMessage.textEntitiesAttribute?.entities ?? []
                            let currentWebpagePreviewAttribute = currentMessage.webpagePreviewAttribute ?? WebpagePreviewMessageAttribute(leadingPreview: false, forceLargeMedia: nil, isManuallyAdded: true, isSafe: false)
                            
                            if currentMessage.text != text.string || currentEntities != entities || updatingMedia || webpagePreviewAttribute != currentWebpagePreviewAttribute || disableUrlPreview {
                                strongSelf.context.account.pendingUpdateMessageManager.add(messageId: editMessage.messageId, text: text.string, media: media, entities: entitiesAttribute, inlineStickers: inlineStickers, webpagePreviewAttribute: webpagePreviewAttribute, disableUrlPreview: disableUrlPreview)
                            }
                        }
                        
                        strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, { state in
                            var state = state
                            state = state.updatedInterfaceState({ $0.withUpdatedEditMessage(nil) })
                            state = state.updatedEditMessageState(nil)
                            return state
                        })
                    }
                })
            })
        }, beginMessageSearch: { [weak self] domain, query in
            guard let strongSelf = self else {
                return
            }
            
            let _ = strongSelf.presentVoiceMessageDiscardAlert(action: {
                var interactive = true
                if strongSelf.chatDisplayNode.isInputViewFocused {
                    interactive = false
                    strongSelf.context.sharedContext.mainWindow?.doNotAnimateLikelyKeyboardAutocorrectionSwitch()
                }
                
                strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: interactive, { current in
                    return current.updatedSearch(current.search == nil ? ChatSearchData(domain: domain).withUpdatedQuery(query) : current.search?.withUpdatedDomain(domain).withUpdatedQuery(query))
                })
                strongSelf.updateItemNodesSearchTextHighlightStates()
            })
        }, dismissMessageSearch: { [weak self] in
            if let strongSelf = self {
                strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, { current in
                    return current.updatedSearch(nil).updatedHistoryFilter(nil)
                })
                strongSelf.updateItemNodesSearchTextHighlightStates()
                strongSelf.searchResultsController = nil
            }
        }, updateMessageSearch: { [weak self] query in
            if let strongSelf = self {
                strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, { current in
                    if let data = current.search {
                        return current.updatedSearch(data.withUpdatedQuery(query))
                    } else {
                        return current
                    }
                })
                strongSelf.updateItemNodesSearchTextHighlightStates()
                strongSelf.searchResultsController = nil
            }
        }, openSearchResults: { [weak self] in
            if let strongSelf = self, let searchData = strongSelf.presentationInterfaceState.search, let _ = searchData.resultsState {
                if let controller = strongSelf.searchResultsController {
                    strongSelf.chatDisplayNode.dismissInput()
                    if case let .inline(navigationController) = strongSelf.presentationInterfaceState.mode {
                        navigationController?.pushViewController(controller)
                    } else {
                        strongSelf.push(controller)
                    }
                } else {
                    let _ = (strongSelf.searchResult.get()
                    |> take(1)
                    |> deliverOnMainQueue).startStandalone(next: { [weak self] searchResult in
                        if let strongSelf = self, let (searchResult, searchState, searchLocation) = searchResult {
                            let controller = ChatSearchResultsController(context: strongSelf.context, updatedPresentationData: strongSelf.updatedPresentationData, location: searchLocation, searchQuery: searchData.query, searchResult: searchResult, searchState: searchState, navigateToMessageIndex: { index in
                                guard let strongSelf = self else {
                                    return
                                }
                                strongSelf.interfaceInteraction?.navigateMessageSearch(.index(index))
                            }, resultsUpdated: { results, state in
                                guard let strongSelf = self else {
                                    return
                                }
                                let updatedValue: (SearchMessagesResult, SearchMessagesState, SearchMessagesLocation)? = (results, state, searchLocation)
                                strongSelf.searchResult.set(.single(updatedValue))
                                strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, { current in
                                    if let data = current.search {
                                        let messageIndices = results.messages.map({ $0.index }).sorted()
                                        var currentIndex = messageIndices.last
                                        if let previousResultId = data.resultsState?.currentId {
                                            for index in messageIndices {
                                                if index.id >= previousResultId {
                                                    currentIndex = index
                                                    break
                                                }
                                            }
                                        }
                                        return current.updatedSearch(data.withUpdatedResultsState(ChatSearchResultsState(messageIndices: messageIndices, currentId: currentIndex?.id, state: state, totalCount: results.totalCount, completed: results.completed)))
                                    } else {
                                        return current
                                    }
                                })
                            })
                            strongSelf.chatDisplayNode.dismissInput()
                            if case let .inline(navigationController) = strongSelf.presentationInterfaceState.mode {
                                navigationController?.pushViewController(controller)
                            } else {
                                strongSelf.push(controller)
                            }
                            strongSelf.searchResultsController = controller
                        }
                    })
                }
            }
        }, navigateMessageSearch: { [weak self] action in
            if let strongSelf = self {
                var navigateIndex: MessageIndex?
                strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, { current in
                    if let data = current.search, let resultsState = data.resultsState {
                        if let currentId = resultsState.currentId, let index = resultsState.messageIndices.firstIndex(where: { $0.id == currentId }) {
                            var updatedIndex: Int?
                            switch action {
                                case .earlier:
                                    if index != 0 {
                                        updatedIndex = index - 1
                                    }
                                case .later:
                                    if index != resultsState.messageIndices.count - 1 {
                                        updatedIndex = index + 1
                                    }
                                case let .index(index):
                                    if index >= 0 && index < resultsState.messageIndices.count {
                                        updatedIndex = index
                                    }
                            }
                            if let updatedIndex = updatedIndex {
                                navigateIndex = resultsState.messageIndices[updatedIndex]
                                return current.updatedSearch(data.withUpdatedResultsState(ChatSearchResultsState(messageIndices: resultsState.messageIndices, currentId: resultsState.messageIndices[updatedIndex].id, state: resultsState.state, totalCount: resultsState.totalCount, completed: resultsState.completed)))
                            }
                        }
                    }
                    return current
                })
                strongSelf.updateItemNodesSearchTextHighlightStates()
                if let navigateIndex = navigateIndex {
                    switch strongSelf.chatLocation {
                    case .peer, .replyThread, .feed:
                        strongSelf.navigateToMessage(from: nil, to: .index(navigateIndex), forceInCurrentChat: true)
                    }
                }
            }
        }, openCalendarSearch: { [weak self] in
            self?.openCalendarSearch(timestamp: Int32(Date().timeIntervalSince1970))
        }, toggleMembersSearch: { [weak self] value in
            if let strongSelf = self {
                strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, { state in
                    if value {
                        return state.updatedSearch(ChatSearchData(query: "", domain: .members, domainSuggestionContext: .none, resultsState: nil))
                    } else if let search = state.search {
                        switch search.domain {
                        case .everything, .tag:
                            return state
                        case .members:
                            return state.updatedSearch(ChatSearchData(query: "", domain: .everything, domainSuggestionContext: .none, resultsState: nil))
                        case .member:
                            return state.updatedSearch(ChatSearchData(query: "", domain: .members, domainSuggestionContext: .none, resultsState: nil))
                        }
                    } else {
                        return state
                    }
                })
                strongSelf.updateItemNodesSearchTextHighlightStates()
            }
        }, navigateToMessage: { [weak self] messageId, dropStack, forceInCurrentChat, statusSubject in
            self?.navigateToMessage(from: nil, to: .id(messageId, NavigateToMessageParams(timestamp: nil, quote: nil)), forceInCurrentChat: forceInCurrentChat, dropStack: dropStack, statusSubject: statusSubject)
        }, navigateToChat: { [weak self] peerId in
            guard let strongSelf = self else {
                return
            }
            let _ = (strongSelf.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
            |> deliverOnMainQueue).startStandalone(next: { peer in
                guard let peer = peer else {
                    return
                }
                guard let strongSelf = self else {
                    return
                }
                
                if let navigationController = strongSelf.effectiveNavigationController {
                    strongSelf.context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: strongSelf.context, chatLocation: .peer(peer), subject: nil, keepStack: .always))
                }
            })
        }, navigateToProfile: { [weak self] peerId in
            guard let strongSelf = self else {
                return
            }
            let _ = (strongSelf.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
            |> deliverOnMainQueue).startStandalone(next: { peer in
                if let strongSelf = self, let peer = peer {
                    strongSelf.openPeer(peer: peer, navigation: .default, fromMessage: nil)
                }
            })
        }, openPeerInfo: { [weak self] in
            self?.navigationButtonAction(.openChatInfo(expandAvatar: false, recommendedChannels: false))
        }, togglePeerNotifications: { [weak self] in
            if let strongSelf = self, let peerId = strongSelf.chatLocation.peerId {
                let _ = strongSelf.context.engine.peers.togglePeerMuted(peerId: peerId, threadId: strongSelf.chatLocation.threadId).startStandalone()
            }
        }, sendContextResult: { [weak self] results, result, node, rect in
            guard let strongSelf = self else {
                return false
            }
            if let _ = strongSelf.presentationInterfaceState.slowmodeState, strongSelf.presentationInterfaceState.subject != .scheduledMessages {
                strongSelf.interfaceInteraction?.displaySlowmodeTooltip(node.view, rect)
                return false
            }
            
            strongSelf.enqueueChatContextResult(results, result)
            return true
        }, sendBotCommand: { [weak self] botPeer, command in
            if let strongSelf = self, canSendMessagesToChat(strongSelf.presentationInterfaceState) {
                if let peer = strongSelf.presentationInterfaceState.renderedPeer?.peer {
                    let messageText: String
                    if let addressName = botPeer.addressName {
                        if peer is TelegramUser {
                            messageText = command
                        } else {
                            messageText = command + "@" + addressName
                        }
                    } else {
                        messageText = command
                    }
                    let replyMessageSubject = strongSelf.presentationInterfaceState.interfaceState.replyMessageSubject
                    strongSelf.chatDisplayNode.setupSendActionOnViewUpdate({
                        if let strongSelf = self {
                            strongSelf.chatDisplayNode.collapseInput()
                            
                            strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: false, {
                                $0.updatedInterfaceState { $0.withUpdatedReplyMessageSubject(nil).withUpdatedComposeInputState(ChatTextInputState(inputText: NSAttributedString(string: ""))).withUpdatedComposeDisableUrlPreviews([]) }
                            })
                        }
                    }, nil)
                    var attributes: [MessageAttribute] = []
                    let entities = generateTextEntities(messageText, enabledTypes: .all)
                    if !entities.isEmpty {
                        attributes.append(TextEntitiesMessageAttribute(entities: entities))
                    }
                    strongSelf.sendMessages([.message(text: messageText, attributes: attributes, inlineStickers: [:], mediaReference: nil, threadId: strongSelf.chatLocation.threadId, replyToMessageId: replyMessageSubject?.subjectModel, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])])
                    strongSelf.interfaceInteraction?.updateShowCommands { _ in
                        return false
                    }
                }
            }
        }, sendBotStart: { [weak self] payload in
            if let strongSelf = self, canSendMessagesToChat(strongSelf.presentationInterfaceState) {
                strongSelf.startBot(payload)
            }
        }, botSwitchChatWithPayload: { [weak self] peerId, payload in
            if let strongSelf = self, case let .peer(currentPeerId) = strongSelf.chatLocation {
                var isScheduled = false
                if case .scheduledMessages = strongSelf.presentationInterfaceState.subject {
                    isScheduled = true
                }
                let _ = (strongSelf.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
                |> deliverOnMainQueue).startStandalone(next: { peer in
                    if let strongSelf = self, let peer = peer {
                        strongSelf.openPeer(peer: peer, navigation: .withBotStartPayload(ChatControllerInitialBotStart(payload: payload, behavior: .automatic(returnToPeerId: currentPeerId, scheduled: isScheduled))), fromMessage: nil)
                    }
                })
            }
        }, beginMediaRecording: { [weak self] isVideo in
            guard let strongSelf = self else {
                return
            }
            guard let peer = strongSelf.presentationInterfaceState.renderedPeer?.peer else {
                return
            }
            
            strongSelf.dismissAllTooltips()
            
            strongSelf.mediaRecordingModeTooltipController?.dismiss()
            strongSelf.interfaceInteraction?.updateShowWebView { _ in
                return false
            }
            
            var bannedMediaInput = false
            if let channel = peer as? TelegramChannel {
                if channel.hasBannedPermission(.banSendVoice) != nil && channel.hasBannedPermission(.banSendInstantVideos) != nil {
                    bannedMediaInput = true
                } else if channel.hasBannedPermission(.banSendVoice) != nil {
                    if !isVideo {
                        strongSelf.controllerInteraction?.displayUndo(.info(title: nil, text: strongSelf.restrictedSendingContentsText(), timeout: nil, customUndoText: nil))
                        return
                    }
                } else if channel.hasBannedPermission(.banSendInstantVideos) != nil {
                    if isVideo {
                        strongSelf.controllerInteraction?.displayUndo(.info(title: nil, text: strongSelf.restrictedSendingContentsText(), timeout: nil, customUndoText: nil))
                        return
                    }
                }
            } else if let group = peer as? TelegramGroup {
                if group.hasBannedPermission(.banSendVoice) && group.hasBannedPermission(.banSendInstantVideos) {
                    bannedMediaInput = true
                } else if group.hasBannedPermission(.banSendVoice) {
                    if !isVideo {
                        strongSelf.controllerInteraction?.displayUndo(.info(title: nil, text: strongSelf.restrictedSendingContentsText(), timeout: nil, customUndoText: nil))
                        return
                    }
                } else if group.hasBannedPermission(.banSendInstantVideos) {
                    if isVideo {
                        strongSelf.controllerInteraction?.displayUndo(.info(title: nil, text: strongSelf.restrictedSendingContentsText(), timeout: nil, customUndoText: nil))
                        return
                    }
                }
            }
            
            if bannedMediaInput {
                strongSelf.controllerInteraction?.displayUndo(.universal(animation: "premium_unlock", scale: 1.0, colors: ["__allcolors__": UIColor(white: 1.0, alpha: 1.0)], title: nil, text: strongSelf.restrictedSendingContentsText(), customUndoText: nil, timeout: nil))
                return
            }
                        
            let requestId = strongSelf.beginMediaRecordingRequestId
            let begin: () -> Void = {
                guard let strongSelf = self, strongSelf.beginMediaRecordingRequestId == requestId else {
                    return
                }
                guard checkAvailableDiskSpace(context: strongSelf.context, push: { [weak self] c in
                    self?.present(c, in: .window(.root))
                }) else {
                    return
                }
                let hasOngoingCall: Signal<Bool, NoError> = strongSelf.context.sharedContext.hasOngoingCall.get()
                let _ = (hasOngoingCall
                |> take(1)
                |> deliverOnMainQueue).startStandalone(next: { hasOngoingCall in
                    guard let strongSelf = self, strongSelf.beginMediaRecordingRequestId == requestId else {
                        return
                    }
                    if hasOngoingCall {
                        strongSelf.present(textAlertController(context: strongSelf.context, updatedPresentationData: strongSelf.updatedPresentationData, title: strongSelf.presentationData.strings.Call_CallInProgressTitle, text: strongSelf.presentationData.strings.Call_RecordingDisabledMessage, actions: [TextAlertAction(type: .defaultAction, title: strongSelf.presentationData.strings.Common_OK, action: {
                        })]), in: .window(.root))
                    } else {
                        if isVideo {
                            strongSelf.requestVideoRecorder()
                        } else {
                            strongSelf.requestAudioRecorder(beginWithTone: false)
                        }
                    }
                })
            }
                        
            DeviceAccess.authorizeAccess(to: .microphone(isVideo ? .video : .audio), presentationData: strongSelf.presentationData, present: { c, a in
                self?.present(c, in: .window(.root), with: a)
            }, openSettings: {
                self?.context.sharedContext.applicationBindings.openSettings()
            }, { granted in
                guard let strongSelf = self, granted else {
                    return
                }
                if isVideo {
                    DeviceAccess.authorizeAccess(to: .camera(.video), presentationData: strongSelf.presentationData, present: { c, a in
                        self?.present(c, in: .window(.root), with: a)
                    }, openSettings: {
                        self?.context.sharedContext.applicationBindings.openSettings()
                    }, { granted in
                        if granted {
                            begin()
                        }
                    })
                } else {
                    begin()
                }
            })
        }, finishMediaRecording: { [weak self] action in
            guard let strongSelf = self else {
                return
            }
            strongSelf.beginMediaRecordingRequestId += 1
            strongSelf.dismissMediaRecorder(action)
        }, stopMediaRecording: { [weak self] in
            guard let strongSelf = self else {
                return
            }
            strongSelf.beginMediaRecordingRequestId += 1
            strongSelf.lockMediaRecordingRequestId = nil
            strongSelf.stopMediaRecorder(pause: true)
        }, lockMediaRecording: { [weak self] in
            guard let strongSelf = self else {
                return
            }
            strongSelf.lockMediaRecordingRequestId = strongSelf.beginMediaRecordingRequestId
            strongSelf.lockMediaRecorder()
        }, resumeMediaRecording: { [weak self] in
            guard let self else {
                return
            }
            self.resumeMediaRecorder()
        }, deleteRecordedMedia: { [weak self] in
            self?.deleteMediaRecording()
        }, sendRecordedMedia: { [weak self] silentPosting, viewOnce in
            self?.sendMediaRecording(silentPosting: silentPosting, viewOnce: viewOnce)
        }, displayRestrictedInfo: { [weak self] subject, displayType in
            guard let strongSelf = self else {
                return
            }
            let subjectFlags: [TelegramChatBannedRightsFlags]
            switch subject {
            case .stickers:
                subjectFlags = [.banSendStickers]
            case .mediaRecording, .premiumVoiceMessages:
                subjectFlags = [.banSendVoice, .banSendInstantVideos]
            }
                        
            var bannedPermission: (Int32, Bool)? = nil
            if let channel = strongSelf.presentationInterfaceState.renderedPeer?.peer as? TelegramChannel {
                for subjectFlag in subjectFlags {
                    if let value = channel.hasBannedPermission(subjectFlag) {
                        bannedPermission = value
                        break
                    }
                }
            } else if let group = strongSelf.presentationInterfaceState.renderedPeer?.peer as? TelegramGroup {
                for subjectFlag in subjectFlags {
                    if group.hasBannedPermission(subjectFlag) {
                        bannedPermission = (Int32.max, false)
                        break
                    }
                }
            }
            
            var displayToast = false
            
            if let (untilDate, personal) = bannedPermission {
                let banDescription: String
                switch subject {
                    case .stickers:
                        if untilDate != 0 && untilDate != Int32.max {
                            banDescription = strongSelf.presentationInterfaceState.strings.Conversation_RestrictedStickersTimed(stringForFullDate(timestamp: untilDate, strings: strongSelf.presentationInterfaceState.strings, dateTimeFormat: strongSelf.presentationInterfaceState.dateTimeFormat)).string
                        } else if personal {
                            banDescription = strongSelf.presentationInterfaceState.strings.Conversation_RestrictedStickers
                        } else {
                            banDescription = strongSelf.presentationInterfaceState.strings.Conversation_DefaultRestrictedStickers
                        }
                    case .mediaRecording:
                        if untilDate != 0 && untilDate != Int32.max {
                            banDescription = strongSelf.presentationInterfaceState.strings.Conversation_RestrictedMediaTimed(stringForFullDate(timestamp: untilDate, strings: strongSelf.presentationInterfaceState.strings, dateTimeFormat: strongSelf.presentationInterfaceState.dateTimeFormat)).string
                        } else if personal {
                            banDescription = strongSelf.presentationInterfaceState.strings.Conversation_RestrictedMedia
                        } else {
                            banDescription = strongSelf.restrictedSendingContentsText()
                            displayToast = true
                        }
                    case .premiumVoiceMessages:
                        banDescription = ""
                }
                if strongSelf.recordingModeFeedback == nil {
                    strongSelf.recordingModeFeedback = HapticFeedback()
                    strongSelf.recordingModeFeedback?.prepareError()
                }
                
                strongSelf.recordingModeFeedback?.error()
                
                switch displayType {
                    case .tooltip:
                        if displayToast {
                            strongSelf.controllerInteraction?.displayUndo(.universal(animation: "premium_unlock", scale: 1.0, colors: ["__allcolors__": UIColor(white: 1.0, alpha: 1.0)], title: nil, text: banDescription, customUndoText: nil, timeout: nil))
                        } else {
                            var rect: CGRect?
                            let isStickers: Bool = subject == .stickers
                            switch subject {
                            case .stickers:
                                rect = strongSelf.chatDisplayNode.frameForStickersButton()
                                if var rectValue = rect, let actionRect = strongSelf.chatDisplayNode.frameForInputActionButton() {
                                    rectValue.origin.y = actionRect.minY
                                    rect = rectValue
                                }
                            case .mediaRecording, .premiumVoiceMessages:
                                rect = strongSelf.chatDisplayNode.frameForInputActionButton()
                            }
                            
                            if let tooltipController = strongSelf.mediaRestrictedTooltipController, strongSelf.mediaRestrictedTooltipControllerMode == isStickers {
                                tooltipController.updateContent(.text(banDescription), animated: true, extendTimer: true)
                            } else if let rect = rect {
                                strongSelf.mediaRestrictedTooltipController?.dismiss()
                                let tooltipController = TooltipController(content: .text(banDescription), baseFontSize: strongSelf.presentationData.listsFontSize.baseDisplaySize)
                                strongSelf.mediaRestrictedTooltipController = tooltipController
                                strongSelf.mediaRestrictedTooltipControllerMode = isStickers
                                tooltipController.dismissed = { [weak tooltipController] _ in
                                    if let strongSelf = self, let tooltipController = tooltipController, strongSelf.mediaRestrictedTooltipController === tooltipController {
                                        strongSelf.mediaRestrictedTooltipController = nil
                                    }
                                }
                                strongSelf.present(tooltipController, in: .window(.root), with: TooltipControllerPresentationArguments(sourceNodeAndRect: {
                                    if let strongSelf = self {
                                        return (strongSelf.chatDisplayNode, rect)
                                    }
                                    return nil
                                }))
                            }
                        }
                    case .alert:
                        strongSelf.present(textAlertController(context: strongSelf.context, updatedPresentationData: strongSelf.updatedPresentationData, title: nil, text: banDescription, actions: [TextAlertAction(type: .defaultAction, title: strongSelf.presentationData.strings.Common_OK, action: {})]), in: .window(.root))
                }
            }
            
            if case .premiumVoiceMessages = subject {
                let text: String
                if let peer = strongSelf.presentationInterfaceState.renderedPeer?.peer.flatMap({ EnginePeer($0) }) {
                    text = strongSelf.presentationInterfaceState.strings.Conversation_VoiceMessagesRestricted(peer.compactDisplayTitle).string
                } else {
                    text = ""
                }
                switch displayType {
                    case .tooltip:
                        let rect = strongSelf.chatDisplayNode.frameForInputActionButton()
                        if let rect = rect {
                            strongSelf.mediaRestrictedTooltipController?.dismiss()
                            let tooltipController = TooltipController(content: .text(text), baseFontSize: strongSelf.presentationData.listsFontSize.baseDisplaySize, padding: 2.0)
                            strongSelf.mediaRestrictedTooltipController = tooltipController
                            strongSelf.mediaRestrictedTooltipControllerMode = false
                            tooltipController.dismissed = { [weak tooltipController] _ in
                                if let strongSelf = self, let tooltipController = tooltipController, strongSelf.mediaRestrictedTooltipController === tooltipController {
                                    strongSelf.mediaRestrictedTooltipController = nil
                                }
                            }
                            strongSelf.present(tooltipController, in: .window(.root), with: TooltipControllerPresentationArguments(sourceNodeAndRect: {
                                if let strongSelf = self {
                                    return (strongSelf.chatDisplayNode, rect)
                                }
                                return nil
                            }))
                        }
                    case .alert:
                        strongSelf.present(textAlertController(context: strongSelf.context, updatedPresentationData: strongSelf.updatedPresentationData, title: nil, text: text, actions: [TextAlertAction(type: .defaultAction, title: strongSelf.presentationData.strings.Common_OK, action: {})]), in: .window(.root))
                }
            } else if case .mediaRecording = subject, strongSelf.presentationInterfaceState.hasActiveGroupCall {
                let rect = strongSelf.chatDisplayNode.frameForInputActionButton()
                if let rect = rect {
                    strongSelf.mediaRestrictedTooltipController?.dismiss()
                    let text: String
                    if let channel = strongSelf.presentationInterfaceState.renderedPeer?.peer as? TelegramChannel, case .broadcast = channel.info {
                        text = strongSelf.presentationInterfaceState.strings.Conversation_LiveStreamMediaRecordingRestricted
                    } else {
                        text = strongSelf.presentationInterfaceState.strings.Conversation_VoiceChatMediaRecordingRestricted
                    }
                    let tooltipController = TooltipController(content: .text(text), baseFontSize: strongSelf.presentationData.listsFontSize.baseDisplaySize)
                    strongSelf.mediaRestrictedTooltipController = tooltipController
                    strongSelf.mediaRestrictedTooltipControllerMode = false
                    tooltipController.dismissed = { [weak tooltipController] _ in
                        if let strongSelf = self, let tooltipController = tooltipController, strongSelf.mediaRestrictedTooltipController === tooltipController {
                            strongSelf.mediaRestrictedTooltipController = nil
                        }
                    }
                    strongSelf.present(tooltipController, in: .window(.root), with: TooltipControllerPresentationArguments(sourceNodeAndRect: {
                        if let strongSelf = self {
                            return (strongSelf.chatDisplayNode, rect)
                        }
                        return nil
                    }))
                }
            }
        }, displayVideoUnmuteTip: { [weak self] location in
            guard let strongSelf = self, !strongSelf.didDisplayVideoUnmuteTooltip, let layout = strongSelf.validLayout, strongSelf.traceVisibility() && isTopmostChatController(strongSelf) else {
                return
            }
            if let location = location, location.y < strongSelf.navigationLayout(layout: layout).navigationFrame.maxY {
                return
            }
            let icon: UIImage?
            if layout.deviceMetrics.hasTopNotch || layout.deviceMetrics.hasDynamicIsland {
                icon = UIImage(bundleImageName: "Chat/Message/VolumeButtonIconX")
            } else {
                icon = UIImage(bundleImageName: "Chat/Message/VolumeButtonIcon")
            }
            if let location = location, let icon = icon {
                strongSelf.didDisplayVideoUnmuteTooltip = true
                strongSelf.videoUnmuteTooltipController?.dismiss()
                let tooltipController = TooltipController(content: .iconAndText(icon, strongSelf.presentationInterfaceState.strings.Conversation_PressVolumeButtonForSound), baseFontSize: strongSelf.presentationData.listsFontSize.baseDisplaySize, timeout: 3.5, dismissByTapOutside: true, dismissImmediatelyOnLayoutUpdate: true)
                strongSelf.videoUnmuteTooltipController = tooltipController
                tooltipController.dismissed = { [weak tooltipController] _ in
                    if let strongSelf = self, let tooltipController = tooltipController, strongSelf.videoUnmuteTooltipController === tooltipController {
                        strongSelf.videoUnmuteTooltipController = nil
                        ApplicationSpecificNotice.setVolumeButtonToUnmute(accountManager: strongSelf.context.sharedContext.accountManager)
                    }
                }
                strongSelf.present(tooltipController, in: .window(.root), with: TooltipControllerPresentationArguments(sourceNodeAndRect: {
                    if let strongSelf = self {
                        return (strongSelf.chatDisplayNode, CGRect(origin: location, size: CGSize()))
                    }
                    return nil
                }))
            } else if let tooltipController = strongSelf.videoUnmuteTooltipController {
                tooltipController.dismissImmediately()
            }
        }, switchMediaRecordingMode: { [weak self] in
            guard let strongSelf = self else {
                return
            }
            guard let peer = strongSelf.presentationInterfaceState.renderedPeer?.peer else {
                return
            }
            
            var bannedMediaInput = false
            if let channel = peer as? TelegramChannel {
                if channel.hasBannedPermission(.banSendVoice) != nil && channel.hasBannedPermission(.banSendInstantVideos) != nil {
                    bannedMediaInput = true
                } else if channel.hasBannedPermission(.banSendVoice) != nil {
                    if channel.hasBannedPermission(.banSendInstantVideos) == nil {
                        strongSelf.displayMediaRecordingTooltip()
                        return
                    }
                } else if channel.hasBannedPermission(.banSendInstantVideos) != nil {
                    if channel.hasBannedPermission(.banSendVoice) == nil {
                        strongSelf.displayMediaRecordingTooltip()
                        return
                    }
                }
            } else if let group = peer as? TelegramGroup {
                if group.hasBannedPermission(.banSendVoice) && group.hasBannedPermission(.banSendInstantVideos) {
                    bannedMediaInput = true
                } else if group.hasBannedPermission(.banSendVoice) {
                    if !group.hasBannedPermission(.banSendInstantVideos) {
                        strongSelf.displayMediaRecordingTooltip()
                        return
                    }
                } else if group.hasBannedPermission(.banSendInstantVideos) {
                    if !group.hasBannedPermission(.banSendVoice) {
                        strongSelf.displayMediaRecordingTooltip()
                        return
                    }
                }
            }
            
            if bannedMediaInput {
                strongSelf.controllerInteraction?.displayUndo(.universal(animation: "premium_unlock", scale: 1.0, colors: ["__allcolors__": UIColor(white: 1.0, alpha: 1.0)], title: nil, text: strongSelf.restrictedSendingContentsText(), customUndoText: nil, timeout: nil))
                return
            }
            
            if strongSelf.recordingModeFeedback == nil {
                strongSelf.recordingModeFeedback = HapticFeedback()
                strongSelf.recordingModeFeedback?.prepareImpact()
            }
            
            strongSelf.recordingModeFeedback?.impact()
            var updatedMode: ChatTextInputMediaRecordingButtonMode?
            
            strongSelf.updateChatPresentationInterfaceState(interactive: true, {
                return $0.updatedInterfaceState({ current in
                    let mode: ChatTextInputMediaRecordingButtonMode
                    switch current.mediaRecordingMode {
                        case .audio:
                            mode = .video
                        case .video:
                            mode = .audio
                    }
                    updatedMode = mode
                    return current.withUpdatedMediaRecordingMode(mode)
                }).updatedShowWebView(false)
            })
            
            if let updatedMode = updatedMode, updatedMode == .video {
                let _ = ApplicationSpecificNotice.incrementChatMediaMediaRecordingTips(accountManager: strongSelf.context.sharedContext.accountManager, count: 3).startStandalone()
            }
            
            strongSelf.displayMediaRecordingTooltip()
        }, setupMessageAutoremoveTimeout: { [weak self] in
            guard let strongSelf = self, case let .peer(peerId) = strongSelf.chatLocation else {
                return
            }
            guard let peer = strongSelf.presentationInterfaceState.renderedPeer?.peer else {
                return
            }
            if peerId.namespace == Namespaces.Peer.SecretChat {
                strongSelf.chatDisplayNode.dismissInput()
                
                if let peer = peer as? TelegramSecretChat {
                    let controller = ChatSecretAutoremoveTimerActionSheetController(context: strongSelf.context, currentValue: peer.messageAutoremoveTimeout == nil ? 0 : peer.messageAutoremoveTimeout!, applyValue: { value in
                        if let strongSelf = self {
                            let _ = strongSelf.context.engine.peers.setChatMessageAutoremoveTimeoutInteractively(peerId: peer.id, timeout: value == 0 ? nil : value).startStandalone()
                        }
                    })
                    strongSelf.present(controller, in: .window(.root))
                }
            } else {
                var currentAutoremoveTimeout: Int32? = strongSelf.presentationInterfaceState.autoremoveTimeout
                var canSetupAutoremoveTimeout = false
                
                if let secretChat = peer as? TelegramSecretChat {
                    currentAutoremoveTimeout = secretChat.messageAutoremoveTimeout
                    canSetupAutoremoveTimeout = true
                } else if let group = peer as? TelegramGroup {
                    if !group.hasBannedPermission(.banChangeInfo) {
                        canSetupAutoremoveTimeout = true
                    }
                } else if let user = peer as? TelegramUser {
                    if user.id != strongSelf.context.account.peerId && user.botInfo == nil {
                        canSetupAutoremoveTimeout = true
                    }
                } else if let channel = peer as? TelegramChannel {
                    if channel.hasPermission(.changeInfo) {
                        canSetupAutoremoveTimeout = true
                    }
                }
                
                if canSetupAutoremoveTimeout {
                    strongSelf.presentAutoremoveSetup()
                } else if let currentAutoremoveTimeout = currentAutoremoveTimeout, let rect = strongSelf.chatDisplayNode.frameForInputPanelAccessoryButton(.messageAutoremoveTimeout(currentAutoremoveTimeout)) {
                    
                    let intervalText = timeIntervalString(strings: strongSelf.presentationData.strings, value: currentAutoremoveTimeout)
                    let text: String = strongSelf.presentationData.strings.Conversation_AutoremoveTimerSetToastText(intervalText).string
                    
                    strongSelf.mediaRecordingModeTooltipController?.dismiss()
                    
                    if let tooltipController = strongSelf.silentPostTooltipController {
                        tooltipController.updateContent(.text(text), animated: true, extendTimer: true)
                    } else {
                        let tooltipController = TooltipController(content: .text(text), baseFontSize: strongSelf.presentationData.listsFontSize.baseDisplaySize, timeout: 4.0)
                        strongSelf.silentPostTooltipController = tooltipController
                        tooltipController.dismissed = { [weak tooltipController] _ in
                            if let strongSelf = self, let tooltipController = tooltipController, strongSelf.silentPostTooltipController === tooltipController {
                                strongSelf.silentPostTooltipController = nil
                            }
                        }
                        strongSelf.present(tooltipController, in: .window(.root), with: TooltipControllerPresentationArguments(sourceNodeAndRect: {
                            if let strongSelf = self {
                                return (strongSelf.chatDisplayNode, rect)
                            }
                            return nil
                        }))
                    }
                }
            }
        }, sendSticker: { [weak self] file, clearInput, sourceView, sourceRect, sourceLayer, bubbleUpEmojiOrStickersets in
            if let strongSelf = self, canSendMessagesToChat(strongSelf.presentationInterfaceState) {
                return strongSelf.controllerInteraction?.sendSticker(file, false, false, nil, clearInput, sourceView, sourceRect, sourceLayer, bubbleUpEmojiOrStickersets) ?? false
            } else {
                return false
            }
        }, unblockPeer: { [weak self] in
            self?.unblockPeer()
        }, pinMessage: { [weak self] messageId, contextController in
            if let strongSelf = self, let currentPeerId = strongSelf.chatLocation.peerId {
                if let peer = strongSelf.presentationInterfaceState.renderedPeer?.peer {
                    if strongSelf.canManagePin() {
                        let pinAction: (Bool, Bool) -> Void = { notify, forThisPeerOnlyIfPossible in
                            if let strongSelf = self {
                                let disposable: MetaDisposable
                                if let current = strongSelf.unpinMessageDisposable {
                                    disposable = current
                                } else {
                                    disposable = MetaDisposable()
                                    strongSelf.unpinMessageDisposable = disposable
                                }
                                disposable.set(strongSelf.context.engine.messages.requestUpdatePinnedMessage(peerId: currentPeerId, update: .pin(id: messageId, silent: !notify, forThisPeerOnlyIfPossible: forThisPeerOnlyIfPossible)).startStrict(completed: {
                                    guard let strongSelf = self else {
                                        return
                                    }
                                    strongSelf.scrolledToMessageIdValue = nil
                                }))
                            }
                        }
                        
                        if let peer = peer as? TelegramChannel, case .broadcast = peer.info, let contextController = contextController {
                            contextController.dismiss(completion: {
                                pinAction(true, false)
                            })
                        } else if let peer = peer as? TelegramUser, let contextController = contextController {
                            if peer.id == strongSelf.context.account.peerId {
                                contextController.dismiss(completion: {
                                    pinAction(true, true)
                                })
                            } else {
                                var contextItems: [ContextMenuItem] = []
                                contextItems.append(.action(ContextMenuActionItem(text: strongSelf.presentationData.strings.Conversation_PinMessagesFor(EnginePeer(peer).compactDisplayTitle).string, textColor: .primary, icon: { _ in nil }, action: { c, _ in
                                    c.dismiss(completion: {
                                        pinAction(true, false)
                                    })
                                })))
                                
                                contextItems.append(.action(ContextMenuActionItem(text: strongSelf.presentationData.strings.Conversation_PinMessagesForMe, textColor: .primary, icon: { _ in nil }, action: { c, _ in
                                    c.dismiss(completion: {
                                        pinAction(true, true)
                                    })
                                })))
                                
                                contextController.setItems(.single(ContextController.Items(content: .list(contextItems))), minHeight: nil, animated: true)
                            }
                            return
                        } else {
                            if let contextController = contextController {
                                var contextItems: [ContextMenuItem] = []
                                
                                contextItems.append(.action(ContextMenuActionItem(text: strongSelf.presentationData.strings.Conversation_PinMessageAlert_PinAndNotifyMembers, textColor: .primary, icon: { _ in nil }, action: { c, _ in
                                    c.dismiss(completion: {
                                        pinAction(true, false)
                                    })
                                })))
                                
                                contextItems.append(.action(ContextMenuActionItem(text: strongSelf.presentationData.strings.Conversation_PinMessageAlert_OnlyPin, textColor: .primary, icon: { _ in nil }, action: { c, _ in
                                    c.dismiss(completion: {
                                        pinAction(false, false)
                                    })
                                })))
                                
                                contextController.setItems(.single(ContextController.Items(content: .list(contextItems))), minHeight: nil, animated: true)
                                
                                return
                            } else {
                                let continueAction: () -> Void = {
                                    guard let strongSelf = self else {
                                        return
                                    }
                                    
                                    var pinImmediately = false
                                    if let channel = peer as? TelegramChannel, case .broadcast = channel.info {
                                        pinImmediately = true
                                    } else if let _ = peer as? TelegramUser {
                                        pinImmediately = true
                                    }
                                    
                                    if pinImmediately {
                                        pinAction(true, false)
                                    } else {
                                        let topPinnedMessage: Signal<ChatPinnedMessage?, NoError> = strongSelf.topPinnedMessageSignal(latest: true)
                                        |> take(1)
                                        
                                        let _ = (topPinnedMessage
                                        |> deliverOnMainQueue).startStandalone(next: { value in
                                            guard let strongSelf = self else {
                                                return
                                            }
                                            
                                            let title: String?
                                            let text: String
                                            let actionLayout: TextAlertContentActionLayout
                                            let actions: [TextAlertAction]
                                            if let value = value, value.message.id > messageId {
                                                title = strongSelf.presentationData.strings.Conversation_PinOlderMessageAlertTitle
                                                text = strongSelf.presentationData.strings.Conversation_PinOlderMessageAlertText
                                                actionLayout = .vertical
                                                actions = [
                                                    TextAlertAction(type: .defaultAction, title: strongSelf.presentationData.strings.Conversation_PinMessageAlertPin, action: {
                                                        pinAction(false, false)
                                                    }),
                                                    TextAlertAction(type: .genericAction, title: strongSelf.presentationData.strings.Common_Cancel, action: {
                                                    })
                                                ]
                                            } else {
                                                title = nil
                                                text = strongSelf.presentationData.strings.Conversation_PinMessageAlertGroup
                                                actionLayout = .horizontal
                                                actions = [
                                                    TextAlertAction(type: .genericAction, title: strongSelf.presentationData.strings.Conversation_PinMessageAlert_OnlyPin, action: {
                                                        pinAction(false, false)
                                                    }),
                                                    TextAlertAction(type: .defaultAction, title: strongSelf.presentationData.strings.Common_Yes, action: {
                                                        pinAction(true, false)
                                                    })
                                                ]
                                            }
                                            
                                            strongSelf.present(textAlertController(context: strongSelf.context, updatedPresentationData: strongSelf.updatedPresentationData, title: title, text: text, actions: actions, actionLayout: actionLayout), in: .window(.root))
                                        })
                                    }
                                }
                                
                                continueAction()
                            }
                        }
                    } else {
                        if let topPinnedMessageId = strongSelf.presentationInterfaceState.pinnedMessage?.topMessageId {
                            strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, {
                                return $0.updatedInterfaceState({ $0.withUpdatedMessageActionsState({ value in
                                    var value = value
                                    value.closedPinnedMessageId = topPinnedMessageId
                                    return value
                                    })
                                })
                            })
                        }
                    }
                }
            }
        }, unpinMessage: { [weak self] id, askForConfirmation, contextController in
            let impl: () -> Void = {
                guard let strongSelf = self else {
                    return
                }
                guard let peer = strongSelf.presentationInterfaceState.renderedPeer?.peer else {
                    return
                }
                
                if strongSelf.canManagePin() {
                    let action: () -> Void = {
                        if let strongSelf = self {
                            let disposable: MetaDisposable
                            if let current = strongSelf.unpinMessageDisposable {
                                disposable = current
                            } else {
                                disposable = MetaDisposable()
                                strongSelf.unpinMessageDisposable = disposable
                            }
                            
                            if askForConfirmation {
                                strongSelf.chatDisplayNode.historyNode.pendingUnpinnedAllMessages = true
                                strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, {
                                    return $0.updatedPendingUnpinnedAllMessages(true)
                                })
                                    
                                strongSelf.present(
                                    UndoOverlayController(
                                        presentationData: strongSelf.presentationData,
                                        content: .messagesUnpinned(
                                            title: strongSelf.presentationData.strings.Chat_MessagesUnpinned(1),
                                            text: "",
                                            undo: askForConfirmation,
                                            isHidden: false
                                        ),
                                        elevatedLayout: false,
                                        action: { action in
                                            switch action {
                                            case .commit:
                                                disposable.set((strongSelf.context.engine.messages.requestUpdatePinnedMessage(peerId: peer.id, update: .clear(id: id))
                                                |> deliverOnMainQueue).startStrict(error: { _ in
                                                    guard let strongSelf = self else {
                                                        return
                                                    }
                                                    strongSelf.chatDisplayNode.historyNode.pendingUnpinnedAllMessages = false
                                                    strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, {
                                                        return $0.updatedPendingUnpinnedAllMessages(false)
                                                    })
                                                }, completed: {
                                                    guard let strongSelf = self else {
                                                        return
                                                    }
                                                    strongSelf.chatDisplayNode.historyNode.pendingUnpinnedAllMessages = false
                                                    strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, {
                                                        return $0.updatedPendingUnpinnedAllMessages(false)
                                                    })
                                                }))
                                            case .undo:
                                                strongSelf.chatDisplayNode.historyNode.pendingUnpinnedAllMessages = false
                                                strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, {
                                                    return $0.updatedPendingUnpinnedAllMessages(false)
                                                })
                                            default:
                                                break
                                            }
                                            return true
                                        }
                                    ),
                                    in: .current
                                )
                            } else {
                                if case .pinnedMessages = strongSelf.presentationInterfaceState.subject {
                                    strongSelf.chatDisplayNode.historyNode.pendingRemovedMessages.insert(id)
                                    strongSelf.present(
                                        UndoOverlayController(
                                            presentationData: strongSelf.presentationData,
                                            content: .messagesUnpinned(
                                                title: strongSelf.presentationData.strings.Chat_MessagesUnpinned(1),
                                                text: "",
                                                undo: true,
                                                isHidden: false
                                            ),
                                            elevatedLayout: false,
                                            action: { action in
                                                guard let strongSelf = self else {
                                                    return true
                                                }
                                                switch action {
                                                case .commit:
                                                    let _ = (strongSelf.context.engine.messages.requestUpdatePinnedMessage(peerId: peer.id, update: .clear(id: id))
                                                    |> deliverOnMainQueue).startStandalone(completed: {
                                                        Queue.mainQueue().after(1.0, {
                                                            guard let strongSelf = self else {
                                                                return
                                                            }
                                                            strongSelf.chatDisplayNode.historyNode.pendingRemovedMessages.remove(id)
                                                        })
                                                    })
                                                case .undo:
                                                    strongSelf.chatDisplayNode.historyNode.pendingRemovedMessages.remove(id)
                                                default:
                                                    break
                                                }
                                                return true
                                            }
                                        ),
                                        in: .current
                                    )
                                } else {
                                    disposable.set((strongSelf.context.engine.messages.requestUpdatePinnedMessage(peerId: peer.id, update: .clear(id: id))
                                    |> deliverOnMainQueue).startStrict())
                                }
                            }
                        }
                    }
                    if askForConfirmation {
                        strongSelf.present(textAlertController(context: strongSelf.context, updatedPresentationData: strongSelf.updatedPresentationData, title: nil, text: strongSelf.presentationData.strings.Conversation_UnpinMessageAlert, actions: [TextAlertAction(type: .genericAction, title: strongSelf.presentationData.strings.Conversation_Unpin, action: {
                            action()
                        }), TextAlertAction(type: .defaultAction, title: strongSelf.presentationData.strings.Common_Cancel, action: {})], actionLayout: .vertical), in: .window(.root))
                    } else {
                        action()
                    }
                } else {
                    if let pinnedMessage = strongSelf.presentationInterfaceState.pinnedMessage {
                        let previousClosedPinnedMessageId = strongSelf.presentationInterfaceState.interfaceState.messageActionsState.closedPinnedMessageId
                        
                        strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, {
                            return $0.updatedInterfaceState({ $0.withUpdatedMessageActionsState({ value in
                                var value = value
                                value.closedPinnedMessageId = pinnedMessage.topMessageId
                                return value
                            }) })
                        })
                        strongSelf.present(
                            UndoOverlayController(
                                presentationData: strongSelf.presentationData,
                                content: .messagesUnpinned(
                                    title: strongSelf.presentationData.strings.Chat_PinnedMessagesHiddenTitle,
                                    text: strongSelf.presentationData.strings.Chat_PinnedMessagesHiddenText,
                                    undo: true,
                                    isHidden: false
                                ),
                                elevatedLayout: false,
                                action: { action in
                                    guard let strongSelf = self else {
                                        return true
                                    }
                                    switch action {
                                    case .commit:
                                        break
                                    case .undo:
                                        strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, {
                                            return $0.updatedInterfaceState({ $0.withUpdatedMessageActionsState({ value in
                                                var value = value
                                                value.closedPinnedMessageId = previousClosedPinnedMessageId
                                                return value
                                            }) })
                                        })
                                    default:
                                        break
                                    }
                                    return true
                                }
                            ),
                            in: .current
                        )
                        strongSelf.updatedClosedPinnedMessageId?(pinnedMessage.topMessageId)
                    }
                }
            }
            
            if let contextController = contextController {
                contextController.dismiss(completion: {
                    impl()
                })
            } else {
                impl()
            }
        }, unpinAllMessages: { [weak self] in
            guard let strongSelf = self else {
                return
            }
            
            let topPinnedMessage: Signal<ChatPinnedMessage?, NoError> = strongSelf.topPinnedMessageSignal(latest: true)
            |> take(1)
            
            let _ = (topPinnedMessage
            |> deliverOnMainQueue).startStandalone(next: { topPinnedMessage in
                guard let strongSelf = self, let topPinnedMessage = topPinnedMessage else {
                    return
                }
                
                if strongSelf.canManagePin() {
                    let count = strongSelf.presentationInterfaceState.pinnedMessage?.totalCount ?? 1
                    
                    strongSelf.requestedUnpinAllMessages?(count, topPinnedMessage.topMessageId)
                    strongSelf.dismiss()
                } else {
                    strongSelf.updatedClosedPinnedMessageId?(topPinnedMessage.topMessageId)
                    strongSelf.dismiss()
                }
            })
        }, openPinnedList: { [weak self] messageId in
            guard let strongSelf = self else {
                return
            }
            strongSelf.openPinnedMessages(at: messageId)
        }, shareAccountContact: { [weak self] in
            self?.shareAccountContact()
        }, reportPeer: { [weak self] in
            self?.reportPeer()
        }, presentPeerContact: { [weak self] in
            self?.addPeerContact()
        }, dismissReportPeer: { [weak self] in
            self?.dismissPeerContactOptions()
        }, deleteChat: { [weak self] in
            self?.deleteChat(reportChatSpam: false)
        }, beginCall: { [weak self] isVideo in
            if let strongSelf = self, case let .peer(peerId) = strongSelf.chatLocation {
                strongSelf.controllerInteraction?.callPeer(peerId, isVideo)
            }
        }, toggleMessageStickerStarred: { [weak self] messageId in
            if let strongSelf = self, let message = strongSelf.chatDisplayNode.historyNode.messageInCurrentHistoryView(messageId) {
                var stickerFile: TelegramMediaFile?
                for media in message.media {
                    if let file = media as? TelegramMediaFile, file.isSticker {
                        stickerFile = file
                    }
                }
                if let stickerFile = stickerFile {
                    let context = strongSelf.context
                    let _ = (context.engine.stickers.isStickerSaved(id: stickerFile.fileId)
                    |> castError(AddSavedStickerError.self)
                    |> mapToSignal { isSaved -> Signal<(SavedStickerResult, Bool), AddSavedStickerError> in
                        return context.engine.stickers.toggleStickerSaved(file: stickerFile, saved: !isSaved)
                        |> map { result -> (SavedStickerResult, Bool) in
                            return (result, !isSaved)
                        }
                    }
                    |> deliverOnMainQueue).startStandalone(next: { [weak self] result, added in
                        if let strongSelf = self {
                            switch result {
                                case .generic:
                                    strongSelf.presentInGlobalOverlay(UndoOverlayController(presentationData: strongSelf.presentationData, content: .sticker(context: strongSelf.context, file: stickerFile, loop: true, title: nil, text: added ? strongSelf.presentationData.strings.Conversation_StickerAddedToFavorites : strongSelf.presentationData.strings.Conversation_StickerRemovedFromFavorites, undoText: nil, customAction: nil), elevatedLayout: true, action: { _ in return false }), with: nil)
                                case let .limitExceeded(limit, premiumLimit):
                                    let premiumConfiguration = PremiumConfiguration.with(appConfiguration: context.currentAppConfiguration.with { $0 })
                                    let text: String
                                    if limit == premiumLimit || premiumConfiguration.isPremiumDisabled {
                                        text = strongSelf.presentationData.strings.Premium_MaxFavedStickersFinalText
                                    } else {
                                        text = strongSelf.presentationData.strings.Premium_MaxFavedStickersText("\(premiumLimit)").string
                                    }
                                    strongSelf.presentInGlobalOverlay(UndoOverlayController(presentationData: strongSelf.presentationData, content: .sticker(context: strongSelf.context, file: stickerFile, loop: true, title: strongSelf.presentationData.strings.Premium_MaxFavedStickersTitle("\(limit)").string, text: text, undoText: nil, customAction: nil), elevatedLayout: true, action: { [weak self] action in
                                        if let strongSelf = self {
                                            if case .info = action {
                                                let controller = PremiumIntroScreen(context: strongSelf.context, source: .savedStickers)
                                                strongSelf.push(controller)
                                                return true
                                            }
                                        }
                                        return false
                                    }), with: nil)
                            }
                        }
                    })
                }
            }
        }, presentController: { [weak self] controller, arguments in
            self?.present(controller, in: .window(.root), with: arguments)
        }, presentControllerInCurrent: { [weak self] controller, arguments in
            if controller is UndoOverlayController {
                self?.dismissAllTooltips()
            }
            self?.present(controller, in: .current, with: arguments)
        }, getNavigationController: { [weak self] in
            return self?.navigationController as? NavigationController
        }, presentGlobalOverlayController: { [weak self] controller, arguments in
            self?.presentInGlobalOverlay(controller, with: arguments)
        }, navigateFeed: { [weak self] in
            if let strongSelf = self {
                strongSelf.chatDisplayNode.historyNode.scrollToNextMessage()
            }
        }, openGrouping: {
        }, toggleSilentPost: { [weak self] in
            if let strongSelf = self {
                var value: Bool = false
                strongSelf.updateChatPresentationInterfaceState(interactive: true, {
                    $0.updatedInterfaceState {
                        value = !$0.silentPosting
                        return $0.withUpdatedSilentPosting(value)
                    }
                })
                strongSelf.saveInterfaceState()
                
                if let navigationController = strongSelf.navigationController as? NavigationController {
                    for controller in navigationController.globalOverlayControllers {
                        if controller is VoiceChatOverlayController {
                            return
                        }
                    }
                }
                
                var rect: CGRect? = strongSelf.chatDisplayNode.frameForInputPanelAccessoryButton(.silentPost(true))
                if rect == nil {
                    rect = strongSelf.chatDisplayNode.frameForInputPanelAccessoryButton(.silentPost(false))
                }
                
                let text: String
                if !value {
                    text = strongSelf.presentationData.strings.Conversation_SilentBroadcastTooltipOn
                } else {
                    text = strongSelf.presentationData.strings.Conversation_SilentBroadcastTooltipOff
                }
                
                if let tooltipController = strongSelf.silentPostTooltipController {
                    tooltipController.updateContent(.text(text), animated: true, extendTimer: true)
                } else if let rect = rect {
                    let tooltipController = TooltipController(content: .text(text), baseFontSize: strongSelf.presentationData.listsFontSize.baseDisplaySize)
                    strongSelf.silentPostTooltipController = tooltipController
                    tooltipController.dismissed = { [weak tooltipController] _ in
                        if let strongSelf = self, let tooltipController = tooltipController, strongSelf.silentPostTooltipController === tooltipController {
                            strongSelf.silentPostTooltipController = nil
                        }
                    }
                    strongSelf.present(tooltipController, in: .window(.root), with: TooltipControllerPresentationArguments(sourceNodeAndRect: {
                        if let strongSelf = self {
                            return (strongSelf.chatDisplayNode, rect)
                        }
                        return nil
                    }))
                }
            }
        }, requestUnvoteInMessage: { [weak self] id in
            guard let strongSelf = self else {
                return
            }
            
            var signal = strongSelf.context.engine.messages.requestMessageSelectPollOption(messageId: id, opaqueIdentifiers: [])
            let disposables: DisposableDict<MessageId>
            if let current = strongSelf.selectMessagePollOptionDisposables {
                disposables = current
            } else {
                disposables = DisposableDict()
                strongSelf.selectMessagePollOptionDisposables = disposables
            }
            
            var cancelImpl: (() -> Void)?
            let presentationData = strongSelf.context.sharedContext.currentPresentationData.with { $0 }
            let progressSignal = Signal<Never, NoError> { subscriber in
                let controller = OverlayStatusController(theme: presentationData.theme, type: .loading(cancelled: {
                    cancelImpl?()
                }))
                //strongSelf.present(controller, in: .window(.root), with: ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
                return ActionDisposable { [weak controller] in
                    Queue.mainQueue().async() {
                        controller?.dismiss()
                    }
                }
            }
            |> runOn(Queue.mainQueue())
            |> delay(0.3, queue: Queue.mainQueue())
            let progressDisposable = progressSignal.startStrict()
            
            signal = signal
            |> afterDisposed {
                Queue.mainQueue().async {
                    progressDisposable.dispose()
                }
            }
            cancelImpl = {
                disposables.set(nil, forKey: id)
            }
            
            disposables.set((signal
            |> deliverOnMainQueue).startStrict(completed: { [weak self] in
                guard let self else {
                    return
                }
                if self.selectPollOptionFeedback == nil {
                    self.selectPollOptionFeedback = HapticFeedback()
                }
                self.selectPollOptionFeedback?.success()
            }), forKey: id)
        }, requestStopPollInMessage: { [weak self] id in
            guard let strongSelf = self, let message = strongSelf.chatDisplayNode.historyNode.messageInCurrentHistoryView(id) else {
                return
            }
            
            var maybePoll: TelegramMediaPoll?
            for media in message.media {
                if let poll = media as? TelegramMediaPoll {
                    maybePoll = poll
                    break
                }
            }
            
            guard let poll = maybePoll else {
                return
            }
            
            let actionTitle: String
            let actionButtonText: String
            switch poll.kind {
            case .poll:
                actionTitle = strongSelf.presentationData.strings.Conversation_StopPollConfirmationTitle
                actionButtonText = strongSelf.presentationData.strings.Conversation_StopPollConfirmation
            case .quiz:
                actionTitle = strongSelf.presentationData.strings.Conversation_StopQuizConfirmationTitle
                actionButtonText = strongSelf.presentationData.strings.Conversation_StopQuizConfirmation
            }
            
            let actionSheet = ActionSheetController(presentationData: strongSelf.presentationData)
            actionSheet.setItemGroups([ActionSheetItemGroup(items: [
                ActionSheetTextItem(title: actionTitle),
                ActionSheetButtonItem(title: actionButtonText, color: .destructive, action: { [weak self, weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    guard let strongSelf = self else {
                        return
                    }
                    let disposables: DisposableDict<MessageId>
                    if let current = strongSelf.selectMessagePollOptionDisposables {
                        disposables = current
                    } else {
                        disposables = DisposableDict()
                        strongSelf.selectMessagePollOptionDisposables = disposables
                    }
                    let controller = OverlayStatusController(theme: strongSelf.presentationData.theme, type: .loading(cancelled: nil))
                    strongSelf.present(controller, in: .window(.root))
                    let signal = strongSelf.context.engine.messages.requestClosePoll(messageId: id)
                    |> afterDisposed { [weak controller] in
                        Queue.mainQueue().async {
                            controller?.dismiss()
                        }
                    }
                    disposables.set((signal
                    |> deliverOnMainQueue).startStrict(error: { _ in
                    }, completed: {
                        guard let strongSelf = self else {
                            return
                        }
                        if strongSelf.selectPollOptionFeedback == nil {
                            strongSelf.selectPollOptionFeedback = HapticFeedback()
                        }
                        strongSelf.selectPollOptionFeedback?.success()
                    }), forKey: id)
                })
            ]), ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: strongSelf.presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                })
            ])])
            
            strongSelf.chatDisplayNode.dismissInput()
            strongSelf.present(actionSheet, in: .window(.root))
        }, updateInputLanguage: { [weak self] f in
            if let strongSelf = self {
                strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, {
                    return $0.updatedInterfaceState({ $0.withUpdatedInputLanguage(f($0.inputLanguage)) })
                })
            }
        }, unarchiveChat: { [weak self] in
            guard let strongSelf = self, case let .peer(peerId) = strongSelf.chatLocation else {
                return
            }
            let _ = (strongSelf.context.engine.peers.updatePeersGroupIdInteractively(peerIds: [peerId], groupId: .root)
            |> deliverOnMainQueue).startStandalone()
        }, openLinkEditing: { [weak self] in
            if let strongSelf = self {
                var selectionRange: Range<Int>?
                var text: NSAttributedString?
                var inputMode: ChatInputMode?
                strongSelf.updateChatPresentationInterfaceState(animated: false, interactive: false, { state in
                    selectionRange = state.interfaceState.effectiveInputState.selectionRange
                    if let selectionRange = selectionRange {
                        text = state.interfaceState.effectiveInputState.inputText.attributedSubstring(from: NSRange(location: selectionRange.startIndex, length: selectionRange.count))
                    }
                    inputMode = state.inputMode
                    return state
                })
                
                var link: String?
                if let text {
                    text.enumerateAttributes(in: NSMakeRange(0, text.length)) { attributes, _, _ in
                        if let linkAttribute = attributes[ChatTextInputAttributes.textUrl] as? ChatTextInputTextUrlAttribute {
                            link = linkAttribute.url
                        }
                    }
                }
                
                let controller = chatTextLinkEditController(sharedContext: strongSelf.context.sharedContext, updatedPresentationData: strongSelf.updatedPresentationData, account: strongSelf.context.account, text: text?.string ?? "", link: link, apply: { [weak self] link in
                    if let strongSelf = self, let inputMode = inputMode, let selectionRange = selectionRange {
                        if let link = link {
                            strongSelf.interfaceInteraction?.updateTextInputStateAndMode { current, inputMode in
                                return (chatTextInputAddLinkAttribute(current, selectionRange: selectionRange, url: link), inputMode)
                            }
                        } else {
                            
                        }
                        strongSelf.updateChatPresentationInterfaceState(animated: false, interactive: true, {
                            return $0.updatedInputMode({ _ in return inputMode }).updatedInterfaceState({
                                $0.withUpdatedEffectiveInputState(ChatTextInputState(inputText: $0.effectiveInputState.inputText, selectionRange: selectionRange.endIndex ..< selectionRange.endIndex))
                            })
                        })
                    }
                })
                strongSelf.present(controller, in: .window(.root))
                
                strongSelf.updateChatPresentationInterfaceState(animated: false, interactive: false, { $0.updatedInputMode({ _ in return .none }) })
            }
        }, reportPeerIrrelevantGeoLocation: { [weak self] in
            guard let strongSelf = self, case let .peer(peerId) = strongSelf.chatLocation else {
                return
            }
            
            strongSelf.chatDisplayNode.dismissInput()
            
            let actions = [TextAlertAction(type: .genericAction, title: strongSelf.presentationData.strings.Common_Cancel, action: {
            }), TextAlertAction(type: .defaultAction, title: strongSelf.presentationData.strings.ReportGroupLocation_Report, action: { [weak self] in
                guard let strongSelf = self else {
                    return
                }
                strongSelf.reportIrrelvantGeoDisposable = (strongSelf.context.engine.peers.reportPeer(peerId: peerId, reason: .irrelevantLocation, message: "")
                |> deliverOnMainQueue).startStrict(completed: { [weak self] in
                    if let strongSelf = self {
                        strongSelf.reportIrrelvantGeoNoticePromise.set(.single(true))
                        let _ = ApplicationSpecificNotice.setIrrelevantPeerGeoReport(engine: strongSelf.context.engine, peerId: peerId).startStandalone()
                        
                        strongSelf.present(UndoOverlayController(presentationData: strongSelf.presentationData, content: .emoji(name: "PoliceCar", text: strongSelf.presentationData.strings.Report_Succeed), elevatedLayout: false, action: { _ in return false }), in: .current)
                    }
                })
            })]
            strongSelf.present(textAlertController(context: strongSelf.context, updatedPresentationData: strongSelf.updatedPresentationData, title: strongSelf.presentationData.strings.ReportGroupLocation_Title, text: strongSelf.presentationData.strings.ReportGroupLocation_Text, actions: actions), in: .window(.root))
        }, displaySlowmodeTooltip: { [weak self] sourceView, nodeRect in
            guard let strongSelf = self, let slowmodeState = strongSelf.presentationInterfaceState.slowmodeState else {
                return
            }
            
            if let boostsToUnrestrict = (strongSelf.peerView?.cachedData as? CachedChannelData)?.boostsToUnrestrict, boostsToUnrestrict > 0 {
                strongSelf.interfaceInteraction?.openBoostToUnrestrict()
                return
            }
            
            let rect = sourceView.convert(nodeRect, to: strongSelf.view)
            if let slowmodeTooltipController = strongSelf.slowmodeTooltipController {
                if let arguments = slowmodeTooltipController.presentationArguments as? TooltipControllerPresentationArguments, case let .node(f) = arguments.sourceAndRect, let (previousNode, previousRect) = f() {
                    if previousNode === strongSelf.chatDisplayNode && previousRect == rect {
                        return
                    }
                }
                
                strongSelf.slowmodeTooltipController = nil
                slowmodeTooltipController.dismiss()
            }
            let slowmodeTooltipController = ChatSlowmodeHintController(presentationData: strongSelf.presentationData, slowmodeState: 
                slowmodeState)
            slowmodeTooltipController.presentationArguments = TooltipControllerPresentationArguments(sourceNodeAndRect: {
                if let strongSelf = self {
                    return (strongSelf.chatDisplayNode, rect)
                }
                return nil
            })
            strongSelf.slowmodeTooltipController = slowmodeTooltipController
            
            strongSelf.window?.presentInGlobalOverlay(slowmodeTooltipController)
        }, displaySendMessageOptions: { [weak self] node, gesture in
            guard let self else {
                return
            }
            chatMessageDisplaySendMessageOptions(selfController: self, node: node, gesture: gesture)
        }, openScheduledMessages: { [weak self] in
            if let strongSelf = self {
                strongSelf.openScheduledMessages()
            }
        }, openPeersNearby: { [weak self] in
            if let strongSelf = self {
                let controller = strongSelf.context.sharedContext.makePeersNearbyController(context: strongSelf.context)
                controller.navigationPresentation = .master
                strongSelf.effectiveNavigationController?.pushViewController(controller, animated: true, completion: { })
            }
        }, displaySearchResultsTooltip: { [weak self] node, nodeRect in
            if let strongSelf = self {
                strongSelf.searchResultsTooltipController?.dismiss()
                let tooltipController = TooltipController(content: .text(strongSelf.presentationData.strings.ChatSearch_ResultsTooltip), baseFontSize: strongSelf.presentationData.listsFontSize.baseDisplaySize, dismissByTapOutside: true, dismissImmediatelyOnLayoutUpdate: true)
                strongSelf.searchResultsTooltipController = tooltipController
                tooltipController.dismissed = { [weak tooltipController] _ in
                    if let strongSelf = self, let tooltipController = tooltipController, strongSelf.searchResultsTooltipController === tooltipController {
                        strongSelf.searchResultsTooltipController = nil
                    }
                }
                strongSelf.present(tooltipController, in: .window(.root), with: TooltipControllerPresentationArguments(sourceNodeAndRect: {
                    if let strongSelf = self {
                        var rect = node.view.convert(node.view.bounds, to: strongSelf.chatDisplayNode.view)
                        rect = CGRect(origin: rect.origin.offsetBy(dx: nodeRect.minX, dy: nodeRect.minY - node.bounds.minY), size: nodeRect.size)
                        return (strongSelf.chatDisplayNode, rect)
                    }
                    return nil
                }))
           }
        }, unarchivePeer: { [weak self] in
            guard let strongSelf = self, case let .peer(peerId) = strongSelf.chatLocation else {
                return
            }
            unarchiveAutomaticallyArchivedPeer(account: strongSelf.context.account, peerId: peerId)
            
            strongSelf.present(UndoOverlayController(presentationData: strongSelf.presentationData, content: .succeed(text: strongSelf.presentationData.strings.Conversation_UnarchiveDone, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false }), in: .current)
        }, scrollToTop: { [weak self] in
            guard let strongSelf = self else {
                return
            }
            
            strongSelf.chatDisplayNode.historyNode.scrollToStartOfHistory()
        }, viewReplies: { [weak self] sourceMessageId, replyThreadResult in
            guard let strongSelf = self else {
                return
            }
            
            if let navigationController = strongSelf.effectiveNavigationController {
                let subject: ChatControllerSubject? = sourceMessageId.flatMap { ChatControllerSubject.message(id: .id($0), highlight: ChatControllerSubject.MessageHighlight(quote: nil), timecode: nil) }
                strongSelf.context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: strongSelf.context, chatLocation: .replyThread(replyThreadResult), subject: subject, keepStack: .always))
            }
        }, activatePinnedListPreview: { [weak self] node, gesture in
            guard let strongSelf = self else {
                return
            }
            guard let peerId = strongSelf.chatLocation.peerId else {
                return
            }
            guard let pinnedMessage = strongSelf.presentationInterfaceState.pinnedMessage else {
                return
            }
            let count = pinnedMessage.totalCount
            let topMessageId = pinnedMessage.topMessageId
            
            var items: [ContextMenuItem] = []
            
            items.append(.action(ContextMenuActionItem(text: strongSelf.presentationData.strings.Chat_PinnedListPreview_ShowAllMessages, icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/PinnedList"), color: theme.contextMenu.primaryColor)
            }, action: { [weak self] _, f in
                guard let strongSelf = self else {
                    return
                }
                strongSelf.openPinnedMessages(at: nil)
                f(.dismissWithoutContent)
            })))
            
            if strongSelf.canManagePin() {
                items.append(.action(ContextMenuActionItem(text: strongSelf.presentationData.strings.Chat_PinnedListPreview_UnpinAllMessages, icon: { theme in
                    return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Unpin"), color: theme.contextMenu.primaryColor)
                }, action: { [weak self] _, f in
                    guard let strongSelf = self else {
                        return
                    }
                    strongSelf.performRequestedUnpinAllMessages(count: count, pinnedMessageId: topMessageId)
                    f(.dismissWithoutContent)
                })))
            } else {
                items.append(.action(ContextMenuActionItem(text: strongSelf.presentationData.strings.Chat_PinnedListPreview_HidePinnedMessages, icon: { theme in
                    return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Unpin"), color: theme.contextMenu.primaryColor)
                }, action: { [weak self] _, f in
                    guard let strongSelf = self else {
                        return
                    }
                    
                    strongSelf.performUpdatedClosedPinnedMessageId(pinnedMessageId: topMessageId)
                    f(.dismissWithoutContent)
                })))
            }
            
            let chatLocation: ChatLocation
            if let _ = strongSelf.chatLocation.threadId {
                chatLocation = strongSelf.chatLocation
            } else {
                chatLocation = .peer(id: peerId)
            }
            
            let chatController = strongSelf.context.sharedContext.makeChatController(context: strongSelf.context, chatLocation: chatLocation, subject: .pinnedMessages(id: pinnedMessage.message.id), botStart: nil, mode: .standard(.previewing))
            chatController.canReadHistory.set(false)
            
            strongSelf.chatDisplayNode.messageTransitionNode.dismissMessageReactionContexts()
            
            let contextController = ContextController(presentationData: strongSelf.presentationData, source: .controller(ChatContextControllerContentSourceImpl(controller: chatController, sourceNode: node, passthroughTouches: true)), items: .single(ContextController.Items(content: .list(items))), gesture: gesture)
            strongSelf.presentInGlobalOverlay(contextController)
        }, joinGroupCall: { [weak self] activeCall in
            guard let strongSelf = self, let peer = strongSelf.presentationInterfaceState.renderedPeer?.peer else {
                return
            }
            strongSelf.joinGroupCall(peerId: peer.id, invite: nil, activeCall: EngineGroupCallDescription(activeCall))
        }, presentInviteMembers: { [weak self] in
            guard let strongSelf = self, let peer = strongSelf.presentationInterfaceState.renderedPeer?.peer else {
                return
            }
            if !(peer is TelegramGroup || peer is TelegramChannel) {
                return
            }
            presentAddMembersImpl(context: strongSelf.context, updatedPresentationData: strongSelf.updatedPresentationData, parentController: strongSelf, groupPeer: peer, selectAddMemberDisposable: strongSelf.selectAddMemberDisposable, addMemberDisposable: strongSelf.addMemberDisposable)
        }, presentGigagroupHelp: { [weak self] in
            if let strongSelf = self {
                strongSelf.present(UndoOverlayController(presentationData: strongSelf.presentationData, content: .info(title: nil, text: strongSelf.presentationData.strings.Conversation_GigagroupDescription, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return true }), in: .current)
            }
        }, editMessageMedia: { [weak self] messageId, draw in
            if let strongSelf = self {
                strongSelf.controllerInteraction?.editMessageMedia(messageId, draw)
            }
        }, updateShowCommands: { [weak self] f in
            if let strongSelf = self {
                strongSelf.updateChatPresentationInterfaceState(interactive: true, {
                    return $0.updatedShowCommands(f($0.showCommands))
                })
            }
        }, updateShowSendAsPeers: { [weak self] f in
            if let strongSelf = self {
                strongSelf.updateChatPresentationInterfaceState(interactive: true, {
                    return $0.updatedShowSendAsPeers(f($0.showSendAsPeers))
                })
            }
        }, openInviteRequests: { [weak self] in
            if let strongSelf = self, let peer = strongSelf.presentationInterfaceState.renderedPeer?.peer {
                let controller = inviteRequestsController(context: strongSelf.context, updatedPresentationData: strongSelf.updatedPresentationData, peerId: peer.id, existingContext: strongSelf.inviteRequestsContext)
                controller.navigationPresentation = .modal
                strongSelf.push(controller)
            }
        }, openSendAsPeer: { [weak self] node, gesture in
            guard let strongSelf = self, let peerId = strongSelf.chatLocation.peerId, let node = node as? ContextReferenceContentNode, let peers = strongSelf.presentationInterfaceState.sendAsPeers, let layout = strongSelf.validLayout else {
                return
            }
            
            let isPremium = strongSelf.presentationInterfaceState.isPremium
                        
            let cleanInsets = layout.intrinsicInsets
            let insets = layout.insets(options: .input)
            let bottomInset = max(insets.bottom, cleanInsets.bottom) + 43.0
            
            let defaultMyPeerId: PeerId
            if let channel = strongSelf.presentationInterfaceState.renderedPeer?.chatMainPeer as? TelegramChannel, case .group = channel.info, channel.hasPermission(.canBeAnonymous) {
                defaultMyPeerId = channel.id
            } else {
                defaultMyPeerId = strongSelf.context.account.peerId
            }
            let myPeerId = strongSelf.presentationInterfaceState.currentSendAsPeerId ?? defaultMyPeerId
            
            var items: [ContextMenuItem] = []
            items.append(.custom(ChatSendAsPeerTitleContextItem(text: strongSelf.presentationInterfaceState.strings.Conversation_SendMesageAs.uppercased()), false))
            items.append(.custom(ChatSendAsPeerListContextItem(context: strongSelf.context, chatPeerId: peerId, peers: peers, selectedPeerId: myPeerId, isPremium: isPremium, presentToast: { [weak self] peer in
                if let strongSelf = self {
                    let hapticFeedback = HapticFeedback()
                    hapticFeedback.impact()
                    
                    strongSelf.present(UndoOverlayController(presentationData: strongSelf.presentationData, content: .invitedToVoiceChat(context: strongSelf.context, peer: peer, text: strongSelf.presentationData.strings.Conversation_SendMesageAsPremiumInfo, action: strongSelf.presentationData.strings.EmojiInput_PremiumEmojiToast_Action, duration: 3), elevatedLayout: false, action: { [weak self] action in
                        guard let strongSelf = self else {
                            return true
                        }
                        if case .undo = action {
                            strongSelf.chatDisplayNode.dismissTextInput()
                            
                            let controller = PremiumIntroScreen(context: strongSelf.context, source: .settings)
                            strongSelf.push(controller)
                        }
                        return true
                    }), in: .current)
                }
                
            }), false))
            
            strongSelf.chatDisplayNode.messageTransitionNode.dismissMessageReactionContexts()
            
            let contextController = ContextController(presentationData: strongSelf.presentationData, source: .reference(ChatControllerContextReferenceContentSource(controller: strongSelf, sourceView: node.view, insets: UIEdgeInsets(top: 0.0, left: 0.0, bottom: bottomInset, right: 0.0))), items: .single(ContextController.Items(content: .list(items))), gesture: gesture, workaroundUseLegacyImplementation: true)
            contextController.dismissed = { [weak self] in
                if let strongSelf = self {
                    strongSelf.updateChatPresentationInterfaceState(interactive: true, {
                        return $0.updatedShowSendAsPeers(false)
                    })
                }
            }
            strongSelf.presentInGlobalOverlay(contextController)
            
            strongSelf.updateChatPresentationInterfaceState(interactive: true, {
                return $0.updatedShowSendAsPeers(true)
            })
        }, presentChatRequestAdminInfo: { [weak self] in
            self?.presentChatRequestAdminInfo()
        }, displayCopyProtectionTip: { [weak self] node, save in
            if let strongSelf = self, let peer = strongSelf.presentationInterfaceState.renderedPeer?.peer, let messageIds = strongSelf.presentationInterfaceState.interfaceState.selectionState?.selectedIds {
                let _ = (strongSelf.context.engine.data.get(EngineDataMap(
                    messageIds.map(TelegramEngine.EngineData.Item.Messages.Message.init)
                ))
                |> map { messages -> [EngineMessage] in
                    return messages.values.compactMap { $0 }
                }
                |> deliverOnMainQueue).startStandalone(next: { [weak self] messages in
                    guard let strongSelf = self else {
                        return
                    }
                    enum PeerType {
                        case group
                        case channel
                        case bot
                        case user
                    }
                    var isBot = false
                    for message in messages {
                        if let author = message.author, case let .user(user) = author, user.botInfo != nil {
                            isBot = true
                            break
                        }
                    }
                    let type: PeerType
                    if isBot {
                        type = .bot
                    } else if let user = peer as? TelegramUser {
                        if user.botInfo != nil {
                            type = .bot
                        } else {
                            type = .user
                        }
                    } else if let channel = peer as? TelegramChannel, case .broadcast = channel.info {
                        type = .channel
                    }  else {
                        type = .group
                    }
                    
                    let text: String
                    switch type {
                    case .group:
                        text = save ? strongSelf.presentationInterfaceState.strings.Conversation_CopyProtectionSavingDisabledGroup : strongSelf.presentationInterfaceState.strings.Conversation_CopyProtectionForwardingDisabledGroup
                    case .channel:
                        text = save ? strongSelf.presentationInterfaceState.strings.Conversation_CopyProtectionSavingDisabledChannel : strongSelf.presentationInterfaceState.strings.Conversation_CopyProtectionForwardingDisabledChannel
                    case .bot:
                        text = save ? strongSelf.presentationInterfaceState.strings.Conversation_CopyProtectionSavingDisabledBot : strongSelf.presentationInterfaceState.strings.Conversation_CopyProtectionForwardingDisabledBot
                    case .user:
                        text = save ? strongSelf.presentationData.strings.Conversation_CopyProtectionSavingDisabledSecret : strongSelf.presentationData.strings.Conversation_CopyProtectionForwardingDisabledSecret
                    }
                    
                    strongSelf.copyProtectionTooltipController?.dismiss()
                    let tooltipController = TooltipController(content: .text(text), baseFontSize: strongSelf.presentationData.listsFontSize.baseDisplaySize, dismissByTapOutside: true, dismissImmediatelyOnLayoutUpdate: true)
                    strongSelf.copyProtectionTooltipController = tooltipController
                    tooltipController.dismissed = { [weak tooltipController] _ in
                        if let strongSelf = self, let tooltipController = tooltipController, strongSelf.copyProtectionTooltipController === tooltipController {
                            strongSelf.copyProtectionTooltipController = nil
                        }
                    }
                    strongSelf.present(tooltipController, in: .window(.root), with: TooltipControllerPresentationArguments(sourceNodeAndRect: {
                        if let strongSelf = self {
                            let rect = node.view.convert(node.view.bounds, to: strongSelf.chatDisplayNode.view).offsetBy(dx: 0.0, dy: 3.0)
                            return (strongSelf.chatDisplayNode, rect)
                        }
                        return nil
                    }))
                })
           }
        }, openWebView: { [weak self] buttonText, url, simple, source in
            if let strongSelf = self {
                strongSelf.controllerInteraction?.openWebView(buttonText, url, simple, source)
            }
        }, updateShowWebView: { [weak self] f in
            if let strongSelf = self {
                strongSelf.updateChatPresentationInterfaceState(interactive: true, {
                    return $0.updatedShowWebView(f($0.showWebView))
                })
            }
        }, insertText: { [weak self] text in
            guard let strongSelf = self, let interfaceInteraction = strongSelf.interfaceInteraction else {
                return
            }
            if !strongSelf.chatDisplayNode.isTextInputPanelActive {
                return
            }
            
            interfaceInteraction.updateTextInputStateAndMode { textInputState, inputMode in
                let inputText = NSMutableAttributedString(attributedString: textInputState.inputText)
                
                let range = textInputState.selectionRange
                
                let updatedText = NSMutableAttributedString(attributedString: text)
                if range.lowerBound < inputText.length {
                    if let quote = inputText.attribute(ChatTextInputAttributes.block, at: range.lowerBound, effectiveRange: nil) {
                        updatedText.addAttribute(ChatTextInputAttributes.block, value: quote, range: NSRange(location: 0, length: updatedText.length))
                    }
                }
                inputText.replaceCharacters(in: NSMakeRange(range.lowerBound, range.count), with: updatedText)
                
                let selectionPosition = range.lowerBound + (updatedText.string as NSString).length
                
                return (ChatTextInputState(inputText: inputText, selectionRange: selectionPosition ..< selectionPosition), inputMode)
            }
            
            strongSelf.chatDisplayNode.updateTypingActivity(true)
        }, backwardsDeleteText: { [weak self] in
            guard let strongSelf = self else {
                return
            }
            if !strongSelf.chatDisplayNode.isTextInputPanelActive {
                return
            }
            guard let textInputPanelNode = strongSelf.chatDisplayNode.textInputPanelNode else {
                return
            }
            textInputPanelNode.backwardsDeleteText()
        }, restartTopic: { [weak self] in
            guard let strongSelf = self, let peerId = strongSelf.chatLocation.peerId, let threadId = strongSelf.chatLocation.threadId else {
                return
            }
            let _ = strongSelf.context.engine.peers.setForumChannelTopicClosed(id: peerId, threadId: threadId, isClosed: false).startStandalone()
        }, toggleTranslation: { [weak self] type in
            guard let strongSelf = self, let peerId = strongSelf.chatLocation.peerId else {
                return
            }
            let _ = (updateChatTranslationStateInteractively(engine: strongSelf.context.engine, peerId: peerId, { current in
                return current?.withIsEnabled(type == .translated)
            })
            |> deliverOnMainQueue).startStandalone(completed: { [weak self] in
                if let strongSelf = self, type == .translated {
                    Queue.mainQueue().after(0.15) {
                        strongSelf.chatDisplayNode.historyNode.refreshPollActionsForVisibleMessages()
                    }
                }
            })
        }, changeTranslationLanguage: { [weak self] langCode in
            guard let strongSelf = self, let peerId = strongSelf.chatLocation.peerId else {
                return
            }
            var langCode = langCode
            if langCode == "nb" {
                langCode = "no"
            } else if langCode == "pt-br" {
                langCode = "pt"
            }
            let _ = updateChatTranslationStateInteractively(engine: strongSelf.context.engine, peerId: peerId, { current in
                return current?.withToLang(langCode).withIsEnabled(true)
            }).startStandalone()
        }, addDoNotTranslateLanguage: { [weak self] langCode in
            guard let strongSelf = self, let peerId = strongSelf.chatLocation.peerId else {
                return
            }
            let _ = updateTranslationSettingsInteractively(accountManager: strongSelf.context.sharedContext.accountManager, { current in
                var updated = current
                if var ignoredLanguages = updated.ignoredLanguages {
                    if !ignoredLanguages.contains(langCode) {
                        ignoredLanguages.append(langCode)
                    }
                    updated.ignoredLanguages = ignoredLanguages
                } else {
                    var ignoredLanguages = Set<String>()
                    ignoredLanguages.insert(strongSelf.presentationData.strings.baseLanguageCode)
                    for language in systemLanguageCodes() {
                        ignoredLanguages.insert(language)
                    }
                    ignoredLanguages.insert(langCode)
                    updated.ignoredLanguages = Array(ignoredLanguages)
                }
                return updated
            }).startStandalone()
            let _ = updateChatTranslationStateInteractively(engine: strongSelf.context.engine, peerId: peerId, { current in
                return nil
            }).startStandalone()
            
            let presentationData = strongSelf.context.sharedContext.currentPresentationData.with { $0 }
            var languageCode = presentationData.strings.baseLanguageCode
            let rawSuffix = "-raw"
            if languageCode.hasSuffix(rawSuffix) {
                languageCode = String(languageCode.dropLast(rawSuffix.count))
            }
            let locale = Locale(identifier: languageCode)
            let fromLanguage: String = locale.localizedString(forLanguageCode: langCode) ?? ""
            
            strongSelf.present(UndoOverlayController(presentationData: presentationData, content: .image(image: generateTintedImage(image: UIImage(bundleImageName: "Chat/Title Panels/Translate"), color: .white)!, title: nil, text: presentationData.strings.Conversation_Translation_AddedToDoNotTranslateText(fromLanguage).string, round: false, undoText: presentationData.strings.Conversation_Translation_Settings), elevatedLayout: false, animateInAsReplacement: false, action: { [weak self] action in
                if case .undo = action, let strongSelf = self {
                    let controller = translationSettingsController(context: strongSelf.context)
                    controller.navigationPresentation = .modal
                    strongSelf.push(controller)
                }
                return true
            }), in: .current)
        }, hideTranslationPanel: { [weak self] in
            guard let strongSelf = self, let peerId = strongSelf.chatLocation.peerId else {
                return
            }
            let context = strongSelf.context
            let presentationData = strongSelf.presentationData
            let _ = context.engine.messages.togglePeerMessagesTranslationHidden(peerId: peerId, hidden: true).startStandalone()

            var text: String = ""
            if let peer = strongSelf.presentationInterfaceState.renderedPeer?.peer {
                if peer is TelegramGroup {
                    text = presentationData.strings.Conversation_Translation_TranslationBarHiddenGroupText
                } else if let peer = peer as? TelegramChannel {
                    switch peer.info {
                    case .group:
                        text = presentationData.strings.Conversation_Translation_TranslationBarHiddenGroupText
                    case .broadcast:
                        text = presentationData.strings.Conversation_Translation_TranslationBarHiddenChannelText
                    }
                } else {
                    text = presentationData.strings.Conversation_Translation_TranslationBarHiddenChatText
                }
            }
            strongSelf.present(UndoOverlayController(presentationData: presentationData, content: .image(image: generateTintedImage(image: UIImage(bundleImageName: "Chat/Title Panels/Translate"), color: .white)!, title: nil, text: text, round: false, undoText: presentationData.strings.Undo_Undo), elevatedLayout: false, animateInAsReplacement: false, action: { action in
                    if case .undo = action {
                        let _ = context.engine.messages.togglePeerMessagesTranslationHidden(peerId: peerId, hidden: false).startStandalone()
                    }
                    return true
            }), in: .current)
        }, openPremiumGift: { [weak self] in
            guard let strongSelf = self, let peerId = strongSelf.chatLocation.peerId else {
                return
            }
            strongSelf.presentAttachmentMenu(subject: .gift)
            Queue.mainQueue().after(0.5) {
                let _ = ApplicationSpecificNotice.incrementDismissedPremiumGiftSuggestion(accountManager: strongSelf.context.sharedContext.accountManager, peerId: peerId).startStandalone()
            }
        }, openPremiumRequiredForMessaging: { [weak self] in
            guard let self else {
                return
            }
            let controller = PremiumIntroScreen(context: self.context, source: .settings)
            self.push(controller)
        }, openBoostToUnrestrict: { [weak self] in
            guard let self, let peerId = self.chatLocation.peerId, let cachedData = self.peerView?.cachedData as? CachedChannelData, let boostToUnrestrict = cachedData.boostsToUnrestrict else {
                return
            }
            let _ = combineLatest(queue: Queue.mainQueue(),
                context.engine.peers.getChannelBoostStatus(peerId: peerId),
                context.engine.peers.getMyBoostStatus()
            ).startStandalone(next: { [weak self] boostStatus, myBoostStatus in
                guard let self, let boostStatus, let myBoostStatus else {
                    return
                }
                let boostController = PremiumBoostLevelsScreen(
                    context: self.context,
                    peerId: peerId,
                    mode: .user(mode: .unrestrict(Int(boostToUnrestrict))),
                    status: boostStatus,
                    myBoostStatus: myBoostStatus
                )
                self.push(boostController)
            })
        }, updateHistoryFilter: { [weak self] update in
            guard let self else {
                return
            }
            self.updateChatPresentationInterfaceState(animated: false, interactive: true, { state in
                var updatedFilter = update(state.historyFilter)
                if let value = updatedFilter {
                    if value.customTags.count == 0 {
                        updatedFilter = nil
                    } else if value.customTags.count > 1 {
                        updatedFilter?.customTags.removeFirst(value.customTags.count - 1)
                    }
                }
                
                var state = state.updatedHistoryFilter(updatedFilter)
                if let updatedFilter, !updatedFilter.isActive, let reactionData = updatedFilter.customTags.first, let reaction = ReactionsMessageAttribute.reactionFromMessageTag(tag: reactionData) {
                    state = state.updatedSearch(ChatSearchData(domain: .tag(reaction)))
                } else {
                    state = state.updatedSearch(ChatSearchData())
                }
                return state
            })
        }, requestLayout: { [weak self] transition in
            if let strongSelf = self, let layout = strongSelf.validLayout {
                strongSelf.containerLayoutUpdated(layout, transition: transition)
            }
        }, chatController: { [weak self] in
            return self
        }, statuses: ChatPanelInterfaceInteractionStatuses(editingMessage: self.editingMessage.get(), startingBot: self.startingBot.get(), unblockingPeer: self.unblockingPeer.get(), searching: self.searching.get(), loadingMessage: self.loadingMessage.get(), inlineSearch: self.performingInlineSearch.get()))
        
        do {
            let peerId = self.chatLocation.peerId
            if let subject = self.subject, case .scheduledMessages = subject {
            } else {
                let throttledUnreadCountSignal = self.context.chatLocationUnreadCount(for: self.chatLocation, contextHolder: self.chatLocationContextHolder)
                |> mapToThrottled { value -> Signal<Int, NoError> in
                    return .single(value) |> then(.complete() |> delay(0.2, queue: Queue.mainQueue()))
                }
                self.buttonUnreadCountDisposable = (throttledUnreadCountSignal
                |> deliverOnMainQueue).startStrict(next: { [weak self] count in
                    guard let strongSelf = self else {
                        return
                    }
                    strongSelf.chatDisplayNode.navigateButtons.unreadCount = Int32(count)
                })

                if case let .peer(peerId) = self.chatLocation {
                    self.chatUnreadCountDisposable = (self.context.engine.data.subscribe(
                        TelegramEngine.EngineData.Item.Messages.PeerUnreadCount(id: peerId),
                        TelegramEngine.EngineData.Item.Messages.TotalReadCounters(),
                        TelegramEngine.EngineData.Item.Peer.NotificationSettings(id: peerId)
                    )
                    |> deliverOnMainQueue).startStrict(next: { [weak self] peerUnreadCount, totalReadCounters, notificationSettings in
                        guard let strongSelf = self else {
                            return
                        }
                        let unreadCount: Int32 = Int32(peerUnreadCount)
                        
                        let inAppSettings = strongSelf.context.sharedContext.currentInAppNotificationSettings.with { $0 }
                        let totalChatCount: Int32 = renderedTotalUnreadCount(inAppSettings: inAppSettings, totalUnreadState: totalReadCounters._asCounters()).0
                        
                        var globalRemainingUnreadChatCount = totalChatCount
                        if !notificationSettings._asNotificationSettings().isRemovedFromTotalUnreadCount(default: false) && unreadCount > 0 {
                            if case .messages = inAppSettings.totalUnreadCountDisplayCategory {
                                globalRemainingUnreadChatCount -= unreadCount
                            } else {
                                globalRemainingUnreadChatCount -= 1
                            }
                        }
                        
                        if globalRemainingUnreadChatCount > 0 {
                            strongSelf.navigationItem.badge = "\(globalRemainingUnreadChatCount)"
                        } else {
                            strongSelf.navigationItem.badge = ""
                        }
                    })
                
                    self.chatUnreadMentionCountDisposable = (self.context.account.viewTracker.unseenPersonalMessagesAndReactionCount(peerId: peerId, threadId: nil) |> deliverOnMainQueue).startStrict(next: { [weak self] mentionCount, reactionCount in
                        if let strongSelf = self {
                            if case .standard(.previewing) = strongSelf.presentationInterfaceState.mode {
                                strongSelf.chatDisplayNode.navigateButtons.mentionCount = 0
                                strongSelf.chatDisplayNode.navigateButtons.reactionsCount = 0
                            } else {
                                strongSelf.chatDisplayNode.navigateButtons.mentionCount = mentionCount
                                strongSelf.chatDisplayNode.navigateButtons.reactionsCount = reactionCount
                            }
                        }
                    })
                } else if let peerId = self.chatLocation.peerId, let threadId = self.chatLocation.threadId {
                    self.chatUnreadMentionCountDisposable = (self.context.account.viewTracker.unseenPersonalMessagesAndReactionCount(peerId: peerId, threadId: threadId) |> deliverOnMainQueue).startStrict(next: { [weak self] mentionCount, reactionCount in
                        if let strongSelf = self {
                            if case .standard(.previewing) = strongSelf.presentationInterfaceState.mode {
                                strongSelf.chatDisplayNode.navigateButtons.mentionCount = 0
                                strongSelf.chatDisplayNode.navigateButtons.reactionsCount = 0
                            } else {
                                strongSelf.chatDisplayNode.navigateButtons.mentionCount = mentionCount
                                strongSelf.chatDisplayNode.navigateButtons.reactionsCount = reactionCount
                            }
                        }
                    })
                }
                
                let engine = self.context.engine
                let previousPeerCache = Atomic<[PeerId: Peer]>(value: [:])

                let activitySpace: PeerActivitySpace?
                switch self.chatLocation {
                case let .peer(peerId):
                    activitySpace = PeerActivitySpace(peerId: peerId, category: .global)
                case let .replyThread(replyThreadMessage):
                    activitySpace = PeerActivitySpace(peerId: replyThreadMessage.peerId, category: .thread(replyThreadMessage.threadId))
                case .feed:
                    activitySpace = nil
                }
                
                if let activitySpace = activitySpace, let peerId = peerId {
                    self.peerInputActivitiesDisposable = (self.context.account.peerInputActivities(peerId: activitySpace)
                    |> mapToSignal { activities -> Signal<[(Peer, PeerInputActivity)], NoError> in
                        var foundAllPeers = true
                        var cachedResult: [(Peer, PeerInputActivity)] = []
                        previousPeerCache.with { dict -> Void in
                            for (peerId, activity) in activities {
                                if let peer = dict[peerId] {
                                    cachedResult.append((peer, activity))
                                } else {
                                    foundAllPeers = false
                                    break
                                }
                            }
                        }
                        if foundAllPeers {
                            return .single(cachedResult)
                        } else {
                            return engine.data.get(EngineDataMap(
                                activities.map { TelegramEngine.EngineData.Item.Peer.Peer(id: $0.0) }
                            ))
                            |> map { peerMap -> [(Peer, PeerInputActivity)] in
                                var result: [(Peer, PeerInputActivity)] = []
                                var peerCache: [PeerId: Peer] = [:]
                                for (peerId, activity) in activities {
                                    if let maybePeer = peerMap[peerId], let peer = maybePeer {
                                        result.append((peer._asPeer(), activity))
                                        peerCache[peerId] = peer._asPeer()
                                    }
                                }
                                let _ = previousPeerCache.swap(peerCache)
                                return result
                            }
                        }
                    }
                    |> deliverOnMainQueue).startStrict(next: { [weak self] activities in
                        if let strongSelf = self {
                            let displayActivities = activities.filter({
                                switch $0.1 {
                                    case .speakingInGroupCall, .interactingWithEmoji:
                                        return false
                                    default:
                                        return true
                                }
                            })
                            strongSelf.chatTitleView?.inputActivities = (peerId, displayActivities)
                            
                            strongSelf.peerInputActivitiesPromise.set(.single(activities))
                            
                            for activity in activities {
                                if case let .interactingWithEmoji(emoticon, messageId, maybeInteraction) = activity.1, let interaction = maybeInteraction {
                                    var found = false
                                    strongSelf.chatDisplayNode.historyNode.forEachVisibleItemNode({ itemNode in
                                        if !found, let itemNode = itemNode as? ChatMessageAnimatedStickerItemNode, let item = itemNode.item {
                                            if item.message.id == messageId {
                                                itemNode.playEmojiInteraction(interaction)
                                                found = true
                                            }
                                        }
                                    })
                                    
                                    if found {
                                        let _ = strongSelf.context.account.updateLocalInputActivity(peerId: activitySpace, activity: .seeingEmojiInteraction(emoticon: emoticon), isPresent: true)
                                    }
                                }
                            }
                        }
                    })
                }
            }
            
            if let peerId = peerId {
                self.sentMessageEventsDisposable.set((self.context.account.pendingMessageManager.deliveredMessageEvents(peerId: peerId)
                |> deliverOnMainQueue).startStrict(next: { [weak self] namespace, silent in
                    if let strongSelf = self {
                        let inAppNotificationSettings = strongSelf.context.sharedContext.currentInAppNotificationSettings.with { $0 }
                        if inAppNotificationSettings.playSounds && !silent {
                            serviceSoundManager.playMessageDeliveredSound()
                        }
                        if strongSelf.presentationInterfaceState.subject != .scheduledMessages && namespace == Namespaces.Message.ScheduledCloud {
                            strongSelf.openScheduledMessages()
                        }
                        
                        if strongSelf.shouldDisplayChecksTooltip {
                            Queue.mainQueue().after(1.0) {
                                strongSelf.displayChecksTooltip()
                            }
                            strongSelf.shouldDisplayChecksTooltip = false
                            strongSelf.checksTooltipDisposable.set(dismissServerProvidedSuggestion(account: strongSelf.context.account, suggestion: .newcomerTicks).startStrict())
                        }
                    }
                }))
            
                self.failedMessageEventsDisposable.set((self.context.account.pendingMessageManager.failedMessageEvents(peerId: peerId)
                |> deliverOnMainQueue).startStrict(next: { [weak self] reason in
                    if let strongSelf = self, strongSelf.currentFailedMessagesAlertController == nil {
                        let text: String
                        var title: String?
                        let moreInfo: Bool
                        switch reason {
                        case .flood:
                            text = strongSelf.presentationData.strings.Conversation_SendMessageErrorFlood
                            moreInfo = true
                        case .sendingTooFast:
                            text = strongSelf.presentationData.strings.Conversation_SendMessageErrorTooFast
                            title = strongSelf.presentationData.strings.Conversation_SendMessageErrorTooFastTitle
                            moreInfo = false
                        case .publicBan:
                            text = strongSelf.presentationData.strings.Conversation_SendMessageErrorGroupRestricted
                            moreInfo = true
                        case .mediaRestricted:
                            text = strongSelf.restrictedSendingContentsText()
                            moreInfo = false
                        case .slowmodeActive:
                            text = strongSelf.presentationData.strings.Chat_SlowmodeSendError
                            moreInfo = false
                        case .tooMuchScheduled:
                            text = strongSelf.presentationData.strings.Conversation_SendMessageErrorTooMuchScheduled
                            moreInfo = false
                        case .voiceMessagesForbidden:
                            strongSelf.interfaceInteraction?.displayRestrictedInfo(.premiumVoiceMessages, .alert)
                            return
                        }
                        let actions: [TextAlertAction]
                        if moreInfo {
                            actions = [TextAlertAction(type: .defaultAction, title: strongSelf.presentationData.strings.Generic_ErrorMoreInfo, action: {
                                self?.openPeerMention("spambot", navigation: .chat(textInputState: nil, subject: nil, peekData: nil))
                            }), TextAlertAction(type: .genericAction, title: strongSelf.presentationData.strings.Common_OK, action: {})]
                        } else {
                            actions = [TextAlertAction(type: .defaultAction, title: strongSelf.presentationData.strings.Common_OK, action: {})]
                        }
                        let controller = textAlertController(context: strongSelf.context, updatedPresentationData: strongSelf.updatedPresentationData, title: title, text: text, actions: actions)
                        strongSelf.currentFailedMessagesAlertController = controller
                        strongSelf.present(controller, in: .window(.root))
                    }
                }))
                
                self.sentPeerMediaMessageEventsDisposable.set(
                    (self.context.account.pendingPeerMediaUploadManager.sentMessageEvents(peerId: peerId)
                    |> deliverOnMainQueue).startStrict(next: { [weak self] _ in
                        if let self {
                            self.chatDisplayNode.historyNode.scrollToEndOfHistory()
                        }
                    })
                )
            }
        }
        
        self.interfaceInteraction = interfaceInteraction
        
        if let search = self.focusOnSearchAfterAppearance {
            self.focusOnSearchAfterAppearance = nil
            self.interfaceInteraction?.beginMessageSearch(search.0, search.1)
        }
        
        self.chatDisplayNode.interfaceInteraction = interfaceInteraction
        
        self.context.sharedContext.mediaManager.galleryHiddenMediaManager.addTarget(self)
        self.galleryHiddenMesageAndMediaDisposable.set(self.context.sharedContext.mediaManager.galleryHiddenMediaManager.hiddenIds().startStrict(next: { [weak self] ids in
            if let strongSelf = self, let controllerInteraction = strongSelf.controllerInteraction {
                var messageIdAndMedia: [MessageId: [Media]] = [:]
                
                for id in ids {
                    if case let .chat(accountId, messageId, media) = id, accountId == strongSelf.context.account.id {
                        messageIdAndMedia[messageId] = [media]
                    }
                }
                
                controllerInteraction.hiddenMedia = messageIdAndMedia
            
                strongSelf.chatDisplayNode.historyNode.forEachItemNode { itemNode in
                    if let itemNode = itemNode as? ChatMessageItemView {
                        itemNode.updateHiddenMedia()
                    }
                }
            }
        }))
        
        self.chatDisplayNode.dismissAsOverlay = { [weak self] in
            if let strongSelf = self {
                strongSelf.statusBar.statusBarStyle = .Ignore
                strongSelf.chatDisplayNode.animateDismissAsOverlay(completion: {
                    self?.dismiss()
                })
            }
        }
        
        let hasActiveCalls: Signal<Bool, NoError>
        if let callManager = self.context.sharedContext.callManager as? PresentationCallManagerImpl {
            hasActiveCalls = callManager.hasActiveCalls
            
            self.hasActiveGroupCallDisposable = ((callManager.currentGroupCallSignal
            |> map { call -> Bool in
                return call != nil
            }) |> deliverOnMainQueue).startStrict(next: { [weak self] hasActiveGroupCall in
                self?.updateChatPresentationInterfaceState(animated: true, interactive: false, { state in
                    return state.updatedHasActiveGroupCall(hasActiveGroupCall)
                })
            })
        } else {
            hasActiveCalls = .single(false)
        }
        
        let shouldBeActive = combineLatest(self.context.sharedContext.mediaManager.audioSession.isPlaybackActive() |> deliverOnMainQueue, self.chatDisplayNode.historyNode.hasVisiblePlayableItemNodes, hasActiveCalls)
        |> mapToSignal { [weak self] isPlaybackActive, hasVisiblePlayableItemNodes, hasActiveCalls -> Signal<Bool, NoError> in
            if hasVisiblePlayableItemNodes && !isPlaybackActive && !hasActiveCalls {
                return Signal<Bool, NoError> { [weak self] subscriber in
                    guard let strongSelf = self else {
                        subscriber.putCompletion()
                        return EmptyDisposable
                    }
                    
                    subscriber.putNext(strongSelf.traceVisibility() && isTopmostChatController(strongSelf) && !strongSelf.context.sharedContext.mediaManager.audioSession.isOtherAudioPlaying())
                    subscriber.putCompletion()
                    return EmptyDisposable
                } |> then(.complete() |> delay(1.0, queue: Queue.mainQueue())) |> restart
            } else {
                return .single(false)
            }
        }
        
        let buttonAction = { [weak self] in
            guard let self, self.traceVisibility() && isTopmostChatController(self) else {
                return
            }
            self.videoUnmuteTooltipController?.dismiss()
            
            var actions: [(Bool, (Double?) -> Void)] = []
            var hasUnconsumed = false
            self.chatDisplayNode.historyNode.forEachVisibleItemNode { itemNode in
                if let itemNode = itemNode as? ChatMessageItemView, let (action, _, _, isUnconsumed, _) = itemNode.playMediaWithSound() {
                    if case let .visible(fraction, _) = itemNode.visibility, fraction > 0.7 {
                        actions.insert((isUnconsumed, action), at: 0)
                        if !hasUnconsumed && isUnconsumed {
                            hasUnconsumed = true
                        }
                    }
                }
            }
            for (isUnconsumed, action) in actions {
                if (!hasUnconsumed || isUnconsumed) {
                    action(nil)
                    break
                }
            }
        }
        self.volumeButtonsListener = VolumeButtonsListener(
            shouldBeActive: shouldBeActive,
            upPressed: buttonAction,
            downPressed: buttonAction
        )

        self.chatDisplayNode.historyNode.openNextChannelToRead = { [weak self] peer, location in
            guard let strongSelf = self else {
                return
            }
            if let navigationController = strongSelf.effectiveNavigationController {
                let _ = ApplicationSpecificNotice.incrementNextChatSuggestionTip(accountManager: strongSelf.context.sharedContext.accountManager).startStandalone()

                let snapshotState = strongSelf.chatDisplayNode.prepareSnapshotState(
                    titleViewSnapshotState: strongSelf.chatTitleView?.prepareSnapshotState(),
                    avatarSnapshotState: (strongSelf.chatInfoNavigationButton?.buttonItem.customDisplayNode as? ChatAvatarNavigationNode)?.prepareSnapshotState()
                )

                var nextFolderId: Int32?
                switch location {
                case let .folder(id, _):
                    nextFolderId = id
                case .same:
                    nextFolderId = strongSelf.currentChatListFilter
                default:
                    nextFolderId = nil
                }
                
                var updatedChatNavigationStack = strongSelf.chatNavigationStack
                updatedChatNavigationStack.removeAll(where: { $0 == ChatNavigationStackItem(peerId: peer.id, threadId: nil) })
                if let peerId = strongSelf.chatLocation.peerId {
                    updatedChatNavigationStack.insert(ChatNavigationStackItem(peerId: peerId, threadId: strongSelf.chatLocation.threadId), at: 0)
                }

                strongSelf.context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: strongSelf.context, chatLocation: .peer(peer), animated: false, chatListFilter: nextFolderId, chatNavigationStack: updatedChatNavigationStack, completion: { nextController in
                    (nextController as! ChatControllerImpl).animateFromPreviousController(snapshotState: snapshotState)
                }))
            }
        }
        
        self.displayNodeDidLoad()
    }

    var storedAnimateFromSnapshotState: ChatControllerNode.SnapshotState?

    func animateFromPreviousController(snapshotState: ChatControllerNode.SnapshotState) {
        self.storedAnimateFromSnapshotState = snapshotState
    }
    
    override public func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
                
        if self.willAppear {
            self.chatDisplayNode.historyNode.refreshPollActionsForVisibleMessages()
        } else {
            self.willAppear = true
            
            // Limit this to reply threads just to be safe now
            if case .replyThread = self.chatLocation {
                self.chatDisplayNode.historyNode.refocusOnUnreadMessagesIfNeeded()
            }
        }
        
        if case let .replyThread(message) = self.chatLocation, message.isForumPost {
            if self.keepMessageCountersSyncrhonizedDisposable == nil {
                self.keepMessageCountersSyncrhonizedDisposable = self.context.engine.messages.keepMessageCountersSyncrhonized(peerId: message.peerId, threadId: message.threadId).startStrict()
            }
        } else if case .peer(self.context.account.peerId) = self.chatLocation {
            if self.keepMessageCountersSyncrhonizedDisposable == nil {
                self.keepMessageCountersSyncrhonizedDisposable = self.context.engine.messages.keepMessageCountersSyncrhonized(peerId: self.context.account.peerId).startStrict()
            }
        }
        
        if let scheduledActivateInput = scheduledActivateInput, case .text = scheduledActivateInput {
            self.scheduledActivateInput = nil
            
            self.updateChatPresentationInterfaceState(animated: true, interactive: true, { state in
                return state.updatedInputMode({ _ in
                    switch scheduledActivateInput {
                    case .text:
                        return .text
                    case .entityInput:
                        return .media(mode: .other, expanded: nil, focused: false)
                    }
                })
            })
        }
        
        var chatNavigationStack: [ChatNavigationStackItem] = self.chatNavigationStack
        if let peerId = self.chatLocation.peerId {
            if let summary = self.customNavigationDataSummary as? ChatControllerNavigationDataSummary {
                chatNavigationStack.removeAll()
                chatNavigationStack = summary.peerNavigationItems.filter({ $0 != ChatNavigationStackItem(peerId: peerId, threadId: self.chatLocation.threadId) })
            }
            if let _ = self.chatLocation.threadId {
                if !chatNavigationStack.contains(ChatNavigationStackItem(peerId: peerId, threadId: nil)) {
                    chatNavigationStack.append(ChatNavigationStackItem(peerId: peerId, threadId: nil))
                }
            }
        }
        
        if !chatNavigationStack.isEmpty {
            self.chatDisplayNode.navigationBar?.backButtonNode.isGestureEnabled = true
            self.chatDisplayNode.navigationBar?.backButtonNode.activated = { [weak self] gesture, _ in
                guard let strongSelf = self, let backButtonNode = strongSelf.chatDisplayNode.navigationBar?.backButtonNode, let navigationController = strongSelf.effectiveNavigationController else {
                    gesture.cancel()
                    return
                }
                let nextFolderId: Int32? = strongSelf.currentChatListFilter
                PeerInfoScreenImpl.displayChatNavigationMenu(
                    context: strongSelf.context,
                    chatNavigationStack: chatNavigationStack,
                    nextFolderId: nextFolderId,
                    parentController: strongSelf,
                    backButtonView: backButtonNode.view,
                    navigationController: navigationController,
                    gesture: gesture
                )
            }
        }
    }
    
    var returnInputViewFocus = false
    
    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        self.didAppear = true
        
        self.chatDisplayNode.historyNode.experimentalSnapScrollToItem = false
        self.chatDisplayNode.historyNode.canReadHistory.set(combineLatest(context.sharedContext.applicationBindings.applicationInForeground, self.canReadHistory.get()) |> map { a, b in
            return a && b
        })
        
        self.chatDisplayNode.loadInputPanels(theme: self.presentationInterfaceState.theme, strings: self.presentationInterfaceState.strings, fontSize: self.presentationInterfaceState.fontSize)
        
        if self.recentlyUsedInlineBotsDisposable == nil {
            self.recentlyUsedInlineBotsDisposable = (self.context.engine.peers.recentlyUsedInlineBots() |> deliverOnMainQueue).startStrict(next: { [weak self] peers in
                self?.recentlyUsedInlineBotsValue = peers.filter({ $0.1 >= 0.14 }).map({ $0.0._asPeer() })
            })
        }
        
        if case .standard(.default) = self.presentationInterfaceState.mode, self.raiseToListen == nil {
            self.raiseToListen = RaiseToListenManager(shouldActivate: { [weak self] in
                if let strongSelf = self, strongSelf.isNodeLoaded && strongSelf.canReadHistoryValue, strongSelf.presentationInterfaceState.interfaceState.editMessage == nil, strongSelf.playlistStateAndType == nil {
                    if !strongSelf.context.sharedContext.currentMediaInputSettings.with({ $0.enableRaiseToSpeak }) {
                        return false
                    }
                    
                    if strongSelf.effectiveNavigationController?.topViewController !== strongSelf {
                        return false
                    }
                    
                    if strongSelf.presentationInterfaceState.inputTextPanelState.mediaRecordingState != nil {
                        return false
                    }
                    
                    if !strongSelf.traceVisibility() {
                        return false
                    }
                    if strongSelf.currentContextController != nil {
                        return false
                    }
                    if !isTopmostChatController(strongSelf) {
                        return false
                    }
                    
                    if strongSelf.firstLoadedMessageToListen() != nil || strongSelf.chatDisplayNode.isTextInputPanelActive {
                        if strongSelf.context.sharedContext.immediateHasOngoingCall {
                            return false
                        }
                        
                        if case .media = strongSelf.presentationInterfaceState.inputMode {
                            return false
                        }
                        return true
                    }
                }
                return false
            }, activate: { [weak self] in
                self?.activateRaiseGesture()
            }, deactivate: { [weak self] in
                self?.deactivateRaiseGesture()
            })
            self.raiseToListen?.enabled = self.canReadHistoryValue
            self.tempVoicePlaylistEnded = { [weak self] in
                guard let strongSelf = self else {
                    return
                }
                if !canSendMessagesToChat(strongSelf.presentationInterfaceState) {
                    return
                }
                
                if let raiseToListen = strongSelf.raiseToListen {
                    strongSelf.voicePlaylistDidEndTimestamp = CACurrentMediaTime()
                    raiseToListen.activateBasedOnProximity(delay: 0.0)
                }
                
                if strongSelf.returnInputViewFocus {
                    strongSelf.returnInputViewFocus = false
                    strongSelf.chatDisplayNode.ensureInputViewFocused()
                }
            }
            self.tempVoicePlaylistItemChanged = { [weak self] previousItem, currentItem in
                guard let strongSelf = self else {
                    return
                }
                
                strongSelf.chatDisplayNode.historyNode.voicePlaylistItemChanged(previousItem, currentItem)
            }
        }
        
        if let arguments = self.presentationArguments as? ChatControllerOverlayPresentationData {
            //TODO clear arguments
            self.chatDisplayNode.animateInAsOverlay(from: arguments.expandData.0, completion: {
                arguments.expandData.1()
            })
        }
        
        if !self.didSetup3dTouch {
            self.didSetup3dTouch = true
            if #available(iOSApplicationExtension 11.0, iOS 11.0, *) {
                let dropInteraction = UIDropInteraction(delegate: self)
                self.chatDisplayNode.view.addInteraction(dropInteraction)
            }
        }
        
        if !self.checkedPeerChatServiceActions {
            self.checkedPeerChatServiceActions = true
            
            if case let .peer(peerId) = self.chatLocation, self.screenCaptureManager == nil {
                if peerId.namespace == Namespaces.Peer.SecretChat {
                    self.screenCaptureManager = ScreenCaptureDetectionManager(check: { [weak self] in
                        if let strongSelf = self, strongSelf.traceVisibility() {
                            if strongSelf.canReadHistoryValue {
                                let _ = strongSelf.context.engine.messages.addSecretChatMessageScreenshot(peerId: peerId).startStandalone()
                            }
                            return true
                        } else {
                            return false
                        }
                    })
                } else if peerId.namespace == Namespaces.Peer.CloudUser && peerId.id._internalGetInt64Value() == 777000 {
                    self.screenCaptureManager = ScreenCaptureDetectionManager(check: { [weak self] in
                        if let strongSelf = self, strongSelf.traceVisibility() {
                            let loginCodeRegex = try? NSRegularExpression(pattern: "[\\d\\-]{5,7}", options: [])
                            var loginCodesToInvalidate: [String] = []
                            strongSelf.chatDisplayNode.historyNode.forEachVisibleMessageItemNode({ itemNode in
                                if let text = itemNode.item?.message.text, let matches = loginCodeRegex?.matches(in: text, options: [], range: NSMakeRange(0, (text as NSString).length)), let match = matches.first {
                                    loginCodesToInvalidate.append((text as NSString).substring(with: match.range))
                                }
                            })
                            if !loginCodesToInvalidate.isEmpty {
                                let _ = strongSelf.context.engine.auth.invalidateLoginCodes(codes: loginCodesToInvalidate).startStandalone()
                            }
                            return true
                        } else {
                            return false
                        }
                    })
                } else if peerId.namespace == Namespaces.Peer.CloudUser {
                    self.screenCaptureManager = ScreenCaptureDetectionManager(check: { [weak self] in
                        guard let self else {
                            return false
                        }
                        
                        let _ = (self.context.sharedContext.mediaManager.globalMediaPlayerState
                        |> take(1)
                        |> deliverOnMainQueue).startStandalone(next: { [weak self] playlistStateAndType in
                            if let self, let (_, playbackState, _) = playlistStateAndType, case let .state(state) = playbackState {
                                if let source = state.item.playbackData?.source, case let .telegramFile(_, _, isViewOnce) = source, isViewOnce {
                                    self.context.sharedContext.mediaManager.setPlaylist(nil, type: .voice, control: .playback(.pause))
                                }
                            }
                        })
                        return true
                    })
                }
            }
            
            if case let .peer(peerId) = self.chatLocation {
                let _ = self.context.engine.peers.checkPeerChatServiceActions(peerId: peerId).startStandalone()
            }
            
            if self.chatDisplayNode.frameForInputActionButton() != nil {
                let inputText = self.presentationInterfaceState.interfaceState.effectiveInputState.inputText.string
                if !inputText.isEmpty {
                    if inputText.count > 4 {
                        let _ = (ApplicationSpecificNotice.getChatMessageOptionsTip(accountManager: self.context.sharedContext.accountManager)
                        |> deliverOnMainQueue).startStandalone(next: { [weak self] counter in
                            if let strongSelf = self, counter < 3 {
                                let _ = ApplicationSpecificNotice.incrementChatMessageOptionsTip(accountManager: strongSelf.context.sharedContext.accountManager).startStandalone()
                                strongSelf.displaySendingOptionsTooltip()
                            }
                        })
                    }
                } else if self.presentationInterfaceState.interfaceState.mediaRecordingMode == .audio {
                    var canSendMedia = false
                    if let channel = self.presentationInterfaceState.renderedPeer?.peer as? TelegramChannel {
                        if channel.hasBannedPermission(.banSendMedia) == nil && channel.hasBannedPermission(.banSendVoice) == nil {
                            canSendMedia = true
                        }
                    } else if let group = self.presentationInterfaceState.renderedPeer?.peer as? TelegramGroup {
                        if !group.hasBannedPermission(.banSendMedia) && !group.hasBannedPermission(.banSendVoice) {
                            canSendMedia = true
                        }
                    } else {
                        canSendMedia = true
                    }
                    if canSendMedia && self.presentationInterfaceState.voiceMessagesAvailable {
                        let _ = (ApplicationSpecificNotice.getChatMediaMediaRecordingTips(accountManager: self.context.sharedContext.accountManager)
                        |> deliverOnMainQueue).startStandalone(next: { [weak self] counter in
                            guard let strongSelf = self else {
                                return
                            }
                            var displayTip = false
                            if counter == 0 {
                                displayTip = true
                            } else if counter < 3 && arc4random_uniform(4) == 1 {
                                displayTip = true
                            }
                            if displayTip {
                                let _ = ApplicationSpecificNotice.incrementChatMediaMediaRecordingTips(accountManager: strongSelf.context.sharedContext.accountManager).startStandalone()
                                strongSelf.displayMediaRecordingTooltip()
                            }
                        })
                    }
                }
            }
            
            self.editMessageErrorsDisposable.set((self.context.account.pendingUpdateMessageManager.errors
            |> deliverOnMainQueue).startStrict(next: { [weak self] (_, error) in
                guard let strongSelf = self else {
                    return
                }
                
                let text: String
                switch error {
                case .generic, .textTooLong, .invalidGrouping:
                    text = strongSelf.presentationData.strings.Channel_EditMessageErrorGeneric
                case .restricted:
                    text = strongSelf.presentationData.strings.Group_ErrorSendRestrictedMedia
                }
                strongSelf.present(textAlertController(context: strongSelf.context, updatedPresentationData: strongSelf.updatedPresentationData, title: nil, text: text, actions: [TextAlertAction(type: .defaultAction, title: strongSelf.presentationData.strings.Common_OK, action: {
                })]), in: .window(.root))
            }))
            
            if case let .peer(peerId) = self.chatLocation {
                let context = self.context
                self.keepPeerInfoScreenDataHotDisposable.set(keepPeerInfoScreenDataHot(context: context, peerId: peerId, chatLocation: self.chatLocation, chatLocationContextHolder: self.chatLocationContextHolder).startStrict())
                
                if peerId.namespace == Namespaces.Peer.CloudUser {
                    self.preloadAvatarDisposable.set((peerInfoProfilePhotosWithCache(context: context, peerId: peerId)
                    |> mapToSignal { (complete, result) -> Signal<Never, NoError> in
                        var signals: [Signal<Never, NoError>] = [.complete()]
                        for i in 0 ..< min(1, result.count) {
                            if let video = result[i].videoRepresentations.first {
                                let duration: Double = (video.representation.startTimestamp ?? 0.0) + (i == 0 ? 4.0 : 2.0)
                                signals.append(preloadVideoResource(postbox: context.account.postbox, userLocation: .other, userContentType: .video, resourceReference: video.reference, duration: duration))
                            }
                        }
                        return combineLatest(signals) |> mapToSignal { _ in
                            return .never()
                        }
                    }).startStrict())
                }
            }
            
            self.preloadAttachBotIconsDisposables = AttachmentController.preloadAttachBotIcons(context: self.context)
        }
        
        if let _ = self.focusOnSearchAfterAppearance {
            self.focusOnSearchAfterAppearance = nil
            if let searchNode = self.navigationBar?.contentNode as? ChatSearchNavigationContentNode {
                searchNode.activate()
            }
        }
        
        if let peekData = self.peekData, case let .peer(peerId) = self.chatLocation {
            let timestamp = Int32(Date().timeIntervalSince1970)
            let remainingTime = max(1, peekData.deadline - timestamp)
            self.peekTimerDisposable.set((
                combineLatest(
                    self.context.account.postbox.peerView(id: peerId),
                    Signal<Bool, NoError>.single(true)
                    |> suspendAwareDelay(Double(remainingTime), granularity: 2.0, queue: .mainQueue())
                )
                |> deliverOnMainQueue
            ).startStrict(next: { [weak self] peerView, _ in
                guard let strongSelf = self, let peer = peerViewMainPeer(peerView) else {
                    return
                }
                if let peer = peer as? TelegramChannel {
                    switch peer.participationStatus {
                    case .member:
                        return
                    default:
                        break
                    }
                }
                strongSelf.present(textAlertController(
                    context: strongSelf.context,
                    title: strongSelf.presentationData.strings.Conversation_PrivateChannelTimeLimitedAlertTitle,
                    text: strongSelf.presentationData.strings.Conversation_PrivateChannelTimeLimitedAlertText,
                    actions: [
                        TextAlertAction(type: .genericAction, title: strongSelf.presentationData.strings.Conversation_PrivateChannelTimeLimitedAlertJoin, action: {
                            guard let strongSelf = self else {
                                return
                            }
                            strongSelf.peekTimerDisposable.set(
                                (strongSelf.context.engine.peers.joinChatInteractively(with: peekData.linkData)
                                |> deliverOnMainQueue).startStrict(next: { peerId in
                                    guard let strongSelf = self else {
                                        return
                                    }
                                    if peerId == nil {
                                        strongSelf.dismiss()
                                    }
                                }, error: { _ in
                                    guard let strongSelf = self else {
                                        return
                                    }
                                    strongSelf.dismiss()
                                })
                            )
                        }),
                        TextAlertAction(type: .defaultAction, title: strongSelf.presentationData.strings.Common_Cancel, action: {
                            guard let strongSelf = self else {
                                return
                            }
                            strongSelf.dismiss()
                        })
                    ],
                    actionLayout: .vertical,
                    dismissOnOutsideTap: false
                ), in: .window(.root))
            }))
        }
        
        self.checksTooltipDisposable.set((getServerProvidedSuggestions(account: self.context.account)
        |> deliverOnMainQueue).startStrict(next: { [weak self] values in
            guard let strongSelf = self, strongSelf.chatLocation.peerId != strongSelf.context.account.peerId else {
                return
            }
            if !values.contains(.newcomerTicks) {
                return
            }
            strongSelf.shouldDisplayChecksTooltip = true
        }))
        
        if case let .peer(peerId) = self.chatLocation {
            self.peerSuggestionsDisposable.set((getPeerSpecificServerProvidedSuggestions(postbox: self.context.account.postbox, peerId: peerId)
            |> deliverOnMainQueue).startStrict(next: { [weak self] values in
                guard let strongSelf = self else {
                    return
                }
                
                if !strongSelf.traceVisibility() || strongSelf.navigationController?.topViewController != strongSelf {
                    return
                }
                
                if values.contains(.convertToGigagroup) && !strongSelf.displayedConvertToGigagroupSuggestion {
                    strongSelf.displayedConvertToGigagroupSuggestion = true
                    
                    let attributedTitle = NSAttributedString(string: strongSelf.presentationData.strings.BroadcastGroups_LimitAlert_Title, font: Font.semibold(strongSelf.presentationData.listsFontSize.baseDisplaySize), textColor: strongSelf.presentationData.theme.actionSheet.primaryTextColor, paragraphAlignment: .center)
                    let body = MarkdownAttributeSet(font: Font.regular(strongSelf.presentationData.listsFontSize.baseDisplaySize * 13.0 / 17.0), textColor: strongSelf.presentationData.theme.actionSheet.primaryTextColor)
                    let bold = MarkdownAttributeSet(font: Font.semibold(strongSelf.presentationData.listsFontSize.baseDisplaySize * 13.0 / 17.0), textColor: strongSelf.presentationData.theme.actionSheet.primaryTextColor)
                    
                    let participantsLimit = strongSelf.context.currentLimitsConfiguration.with { $0 }.maxSupergroupMemberCount
                    let text = strongSelf.presentationData.strings.BroadcastGroups_LimitAlert_Text(presentationStringsFormattedNumber(participantsLimit, strongSelf.presentationData.dateTimeFormat.groupingSeparator)).string
                    let attributedText = parseMarkdownIntoAttributedString(text, attributes: MarkdownAttributes(body: body, bold: bold, link: body, linkAttribute: { _ in return nil }), textAlignment: .center)
                    
                    let controller = richTextAlertController(context: strongSelf.context, title: attributedTitle, text: attributedText, actions: [TextAlertAction(type: .genericAction, title: strongSelf.presentationData.strings.Common_Cancel, action: {
                        strongSelf.present(UndoOverlayController(presentationData: strongSelf.presentationData, content: .info(title: nil, text: strongSelf.presentationData.strings.BroadcastGroups_LimitAlert_SettingsTip, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false }), in: .current)
                    }), TextAlertAction(type: .defaultAction, title: strongSelf.presentationData.strings.BroadcastGroups_LimitAlert_LearnMore, action: {
                        
                        let context = strongSelf.context
                        let presentationData = strongSelf.presentationData
                        let controller = PermissionController(context: context, splashScreen: true)
                        controller.navigationPresentation = .modal
                        controller.setState(.custom(icon: .animation("BroadcastGroup"), title: presentationData.strings.BroadcastGroups_IntroTitle, subtitle: nil, text: presentationData.strings.BroadcastGroups_IntroText, buttonTitle: presentationData.strings.BroadcastGroups_Convert, secondaryButtonTitle: presentationData.strings.BroadcastGroups_Cancel, footerText: nil), animated: false)
                        controller.proceed = { [weak controller] result in
                            let attributedTitle = NSAttributedString(string: presentationData.strings.BroadcastGroups_ConfirmationAlert_Title, font: Font.semibold(presentationData.listsFontSize.baseDisplaySize), textColor: presentationData.theme.actionSheet.primaryTextColor, paragraphAlignment: .center)
                            let body = MarkdownAttributeSet(font: Font.regular(presentationData.listsFontSize.baseDisplaySize * 13.0 / 17.0), textColor: presentationData.theme.actionSheet.primaryTextColor)
                            let bold = MarkdownAttributeSet(font: Font.semibold(presentationData.listsFontSize.baseDisplaySize * 13.0 / 17.0), textColor: presentationData.theme.actionSheet.primaryTextColor)
                            let attributedText = parseMarkdownIntoAttributedString(presentationData.strings.BroadcastGroups_ConfirmationAlert_Text, attributes: MarkdownAttributes(body: body, bold: bold, link: body, linkAttribute: { _ in return nil }), textAlignment: .center)
                            
                            let alertController = richTextAlertController(context: context, title: attributedTitle, text: attributedText, actions: [TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {
                                let _ = dismissPeerSpecificServerProvidedSuggestion(account: context.account, peerId: peerId, suggestion: .convertToGigagroup).startStandalone()
                            }), TextAlertAction(type: .defaultAction, title: presentationData.strings.BroadcastGroups_ConfirmationAlert_Convert, action: { [weak controller] in
                                controller?.dismiss()
                                
                                let _ = dismissPeerSpecificServerProvidedSuggestion(account: context.account, peerId: peerId, suggestion: .convertToGigagroup).startStandalone()
                                
                                let _ = (convertGroupToGigagroup(account: context.account, peerId: peerId)
                                |> deliverOnMainQueue).startStandalone(completed: {
                                    let participantsLimit = context.currentLimitsConfiguration.with { $0 }.maxSupergroupMemberCount
                                    strongSelf.present(UndoOverlayController(presentationData: presentationData, content: .gigagroupConversion(text: presentationData.strings.BroadcastGroups_Success(presentationStringsFormattedNumber(participantsLimit, presentationData.dateTimeFormat.decimalSeparator)).string), elevatedLayout: false, action: { _ in return false }), in: .current)
                                })
                            })])
                            controller?.present(alertController, in: .window(.root))
                        }
                        strongSelf.push(controller)
                    })])
                    strongSelf.present(controller, in: .window(.root))
                }
            }))
        }
        
        if let scheduledActivateInput = self.scheduledActivateInput {
            self.scheduledActivateInput = nil
            
            switch scheduledActivateInput {
            case .text:
                self.updateChatPresentationInterfaceState(animated: true, interactive: true, { state in
                    return state.updatedInputMode({ _ in
                        return .text
                    })
                })
            case .entityInput:
                self.chatDisplayNode.openStickers(beginWithEmoji: true)
            }
        }

        if let snapshotState = self.storedAnimateFromSnapshotState {
            self.storedAnimateFromSnapshotState = nil

            if let titleViewSnapshotState = snapshotState.titleViewSnapshotState {
                self.chatTitleView?.animateFromSnapshot(titleViewSnapshotState)
            }
            if let avatarSnapshotState = snapshotState.avatarSnapshotState {
                (self.chatInfoNavigationButton?.buttonItem.customDisplayNode as? ChatAvatarNavigationNode)?.animateFromSnapshot(avatarSnapshotState)
            }
            self.chatDisplayNode.animateFromSnapshot(snapshotState, completion: { [weak self] in
                guard let strongSelf = self else {
                    return
                }
                strongSelf.chatDisplayNode.historyNode.preloadPages = true
            })
        } else {
            self.chatDisplayNode.historyNode.preloadPages = true
        }
        
        if let attachBotStart = self.attachBotStart {
            self.attachBotStart = nil
            self.presentAttachmentBot(botId: attachBotStart.botId, payload: attachBotStart.payload, justInstalled: attachBotStart.justInstalled)
        }
        
        if self.powerSavingMonitoringDisposable == nil {
            self.powerSavingMonitoringDisposable = (self.context.sharedContext.automaticMediaDownloadSettings
            |> mapToSignal { settings -> Signal<Bool, NoError> in
                return automaticEnergyUsageShouldBeOn(settings: settings)
            }
            |> distinctUntilChanged).startStrict(next: { [weak self] isPowerSavingEnabled in
                guard let self else {
                    return
                }
                var previousValueValue: Bool?
                
                previousValueValue = ChatListControllerImpl.sharedPreviousPowerSavingEnabled
                ChatListControllerImpl.sharedPreviousPowerSavingEnabled = isPowerSavingEnabled
                
                /*#if DEBUG
                previousValueValue = false
                #endif*/
                
                if isPowerSavingEnabled != previousValueValue && previousValueValue != nil && isPowerSavingEnabled {
                    let batteryLevel = UIDevice.current.batteryLevel
                    if batteryLevel > 0.0 && self.view.window != nil {
                        let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
                        let batteryPercentage = Int(batteryLevel * 100.0)
                        
                        self.dismissAllUndoControllers()
                        self.present(UndoOverlayController(presentationData: presentationData, content: .universal(animation: "lowbattery_30", scale: 1.0, colors: [:], title: presentationData.strings.PowerSaving_AlertEnabledTitle, text: presentationData.strings.PowerSaving_AlertEnabledText("\(batteryPercentage)").string, customUndoText: presentationData.strings.PowerSaving_AlertEnabledAction, timeout: 5.0), elevatedLayout: false, action: { [weak self] action in
                            if case .undo = action, let self {
                                let _ = updateMediaDownloadSettingsInteractively(accountManager: self.context.sharedContext.accountManager, { settings in
                                    var settings = settings
                                    settings.energyUsageSettings.activationThreshold = 4
                                    return settings
                                }).startStandalone()
                            }
                            return false
                        }), in: .current)
                    }
                }
            })
        }
    }
    
    override public func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        UIView.performWithoutAnimation {
            self.view.endEditing(true)
        }
        
        self.chatDisplayNode.historyNode.canReadHistory.set(.single(false))
        self.saveInterfaceState()
        
        self.dismissAllTooltips()
        
        self.sendMessageActionsController?.dismiss()
        self.themeScreen?.dismiss()
        
        self.attachmentController?.dismiss()
        
        self.chatDisplayNode.messageTransitionNode.dismissMessageReactionContexts()
        
        if let _ = self.peekData {
            self.peekTimerDisposable.set(nil)
        }
    }
    
    func saveInterfaceState(includeScrollState: Bool = true) {
        if case .messageOptions = self.subject {
            return
        }
        
        var peerId: PeerId
        var threadId: Int64?
        switch self.chatLocation {
        case let .peer(peerIdValue):
            peerId = peerIdValue
        case let .replyThread(replyThreadMessage):
            peerId = replyThreadMessage.peerId
            threadId = replyThreadMessage.threadId
        case .feed:
            return
        }
        
        let timestamp = Int32(Date().timeIntervalSince1970)
        var interfaceState = self.presentationInterfaceState.interfaceState.withUpdatedTimestamp(timestamp)
        if includeScrollState && threadId == nil {
            let scrollState = self.chatDisplayNode.historyNode.immediateScrollState()
            interfaceState = interfaceState.withUpdatedHistoryScrollState(scrollState)
        }
        interfaceState = interfaceState.withUpdatedInputLanguage(self.chatDisplayNode.currentTextInputLanguage)
        if case .peer = self.chatLocation, let channel = self.presentationInterfaceState.renderedPeer?.peer as? TelegramChannel, channel.flags.contains(.isForum) {
            interfaceState = interfaceState.withUpdatedComposeInputState(ChatTextInputState()).withUpdatedReplyMessageSubject(nil)
        }
        let _ = ChatInterfaceState.update(engine: self.context.engine, peerId: peerId, threadId: threadId, { _ in
            return interfaceState
        }).startStandalone()
    }
        
    override public func viewWillLeaveNavigation() {
        self.chatDisplayNode.willNavigateAway()
    }
    
    override public func inFocusUpdated(isInFocus: Bool) {
        self.disableStickerAnimationsPromise.set(!isInFocus)
        self.chatDisplayNode.inFocusUpdated(isInFocus: isInFocus)
    }
    
    func canManagePin() -> Bool {
        guard let peer = self.presentationInterfaceState.renderedPeer?.peer else {
            return false
        }
        
        var canManagePin = false
        if let channel = peer as? TelegramChannel {
            canManagePin = channel.hasPermission(.pinMessages)
        } else if let group = peer as? TelegramGroup {
            switch group.role {
                case .creator, .admin:
                    canManagePin = true
                default:
                    if let defaultBannedRights = group.defaultBannedRights {
                        canManagePin = !defaultBannedRights.flags.contains(.banPinMessages)
                    } else {
                        canManagePin = true
                    }
            }
        } else if let _ = peer as? TelegramUser, self.presentationInterfaceState.explicitelyCanPinMessages {
            canManagePin = true
        }
        
        return canManagePin
    }

    var suspendNavigationBarLayout: Bool = false
    var suspendedNavigationBarLayout: ContainerViewLayout?
    var additionalNavigationBarBackgroundHeight: CGFloat = 0.0
    var additionalNavigationBarHitTestSlop: CGFloat = 0.0

    override public func updateNavigationBarLayout(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        if self.suspendNavigationBarLayout {
            self.suspendedNavigationBarLayout = layout
            return
        }
        self.applyNavigationBarLayout(layout, navigationLayout: self.navigationLayout(layout: layout), additionalBackgroundHeight: self.additionalNavigationBarBackgroundHeight, transition: transition)
    }
    
    override public func preferredContentSizeForLayout(_ layout: ContainerViewLayout) -> CGSize? {
        return nil
    }
    
    public func updateIsScrollingLockedAtTop(isScrollingLockedAtTop: Bool) {
        self.chatDisplayNode.isScrollingLockedAtTop = isScrollingLockedAtTop
    }
    
    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        self.suspendNavigationBarLayout = true
        super.containerLayoutUpdated(layout, transition: transition)
        
        self.validLayout = layout
        self.chatTitleView?.layout = layout
        
        switch self.presentationInterfaceState.mode {
        case .standard, .inline:
            break
        case .overlay:
            if case .Ignore = self.statusBar.statusBarStyle {
            } else if layout.safeInsets.top.isZero {
                self.statusBar.statusBarStyle = .Hide
            } else {
                self.statusBar.statusBarStyle = .Ignore
            }
        }
        
        var layout = layout
        if case .compact = layout.metrics.widthClass, let attachmentController = self.attachmentController, attachmentController.window != nil {
            layout = layout.withUpdatedInputHeight(nil)
        }
                
        var navigationBarTransition = transition
        self.chatDisplayNode.containerLayoutUpdated(layout, navigationBarHeight: self.navigationLayout(layout: layout).navigationFrame.maxY, transition: transition, listViewTransaction: { updateSizeAndInsets, additionalScrollDistance, scrollToTop, completion in
            self.chatDisplayNode.historyNode.updateLayout(transition: transition, updateSizeAndInsets: updateSizeAndInsets, additionalScrollDistance: additionalScrollDistance, scrollToTop: scrollToTop, completion: completion)
        }, updateExtraNavigationBarBackgroundHeight: { value, hitTestSlop, extraNavigationTransition in
            navigationBarTransition = extraNavigationTransition
            self.additionalNavigationBarBackgroundHeight = value
            self.additionalNavigationBarHitTestSlop = hitTestSlop
        })
        
        if case .compact = layout.metrics.widthClass {
            let hasOverlayNodes = self.context.sharedContext.mediaManager.overlayMediaManager.controller?.hasNodes ?? false
            if self.validLayout != nil && layout.size.width > layout.size.height && !hasOverlayNodes && self.traceVisibility() && isTopmostChatController(self) {
                var completed = false
                self.chatDisplayNode.historyNode.forEachVisibleItemNode { itemNode in
                    if !completed, let itemNode = itemNode as? ChatMessageItemView, let message = itemNode.item?.message, let (_, soundEnabled, _, _, _) = itemNode.playMediaWithSound(), soundEnabled {
                        let _ = self.controllerInteraction?.openMessage(message, OpenMessageParams(mode: .landscape))
                        completed = true
                    }
                }
            }
        }

        self.suspendNavigationBarLayout = false
        if let suspendedNavigationBarLayout = self.suspendedNavigationBarLayout {
            self.suspendedNavigationBarLayout = suspendedNavigationBarLayout
            self.applyNavigationBarLayout(suspendedNavigationBarLayout, navigationLayout: self.navigationLayout(layout: layout), additionalBackgroundHeight: self.additionalNavigationBarBackgroundHeight, transition: navigationBarTransition)
        }
        self.navigationBar?.additionalContentNode.hitTestSlop = UIEdgeInsets(top: 0.0, left: 0.0, bottom: self.additionalNavigationBarHitTestSlop, right: 0.0)
    }
    
    func updateChatPresentationInterfaceState(animated: Bool = true, interactive: Bool, saveInterfaceState: Bool = false, _ f: (ChatPresentationInterfaceState) -> ChatPresentationInterfaceState, completion: @escaping (ContainedViewLayoutTransition) -> Void = { _ in }) {
        self.updateChatPresentationInterfaceState(transition: animated ? .animated(duration: 0.4, curve: .spring) : .immediate, interactive: interactive, saveInterfaceState: saveInterfaceState, f, completion: completion)
    }
    
    func updateChatPresentationInterfaceState(transition: ContainedViewLayoutTransition, interactive: Bool, saveInterfaceState: Bool = false, _ f: (ChatPresentationInterfaceState) -> ChatPresentationInterfaceState, completion: @escaping (ContainedViewLayoutTransition) -> Void = { _ in }) {
        updateChatPresentationInterfaceStateImpl(
            selfController: self,
            transition: transition,
            interactive: interactive,
            saveInterfaceState: saveInterfaceState,
            f,
            completion: completion
        )
    }
    
    func updateItemNodesSelectionStates(animated: Bool) {
        self.chatDisplayNode.historyNode.forEachItemNode { itemNode in
            if let itemNode = itemNode as? ChatMessageItemView {
                itemNode.updateSelectionState(animated: animated)
            }
        }

        self.chatDisplayNode.historyNode.forEachItemHeaderNode{ itemHeaderNode in
            if let avatarNode = itemHeaderNode as? ChatMessageAvatarHeaderNode {
                avatarNode.updateSelectionState(animated: animated)
            }
        }
    }
    
    func updatePollTooltipMessageState(animated: Bool) {
        self.chatDisplayNode.historyNode.forEachItemNode { itemNode in
            if let itemNode = itemNode as? ChatMessageBubbleItemNode {
                for contentNode in itemNode.contentNodes {
                    if let contentNode = contentNode as? ChatMessagePollBubbleContentNode {
                        contentNode.updatePollTooltipMessageState(animated: animated)
                    }
                }
                itemNode.updatePsaTooltipMessageState(animated: animated)
            }
        }
    }
    
    func updateItemNodesSearchTextHighlightStates() {
        var searchString: String?
        var resultsMessageIndices: [MessageIndex]?
        if let search = self.presentationInterfaceState.search, let resultsState = search.resultsState, !resultsState.messageIndices.isEmpty {
            searchString = search.query
            resultsMessageIndices = resultsState.messageIndices
        }
        if searchString != self.controllerInteraction?.searchTextHighightState?.0 || resultsMessageIndices?.count != self.controllerInteraction?.searchTextHighightState?.1.count {
            var searchTextHighightState: (String, [MessageIndex])?
            if let searchString = searchString, let resultsMessageIndices = resultsMessageIndices {
                searchTextHighightState = (searchString, resultsMessageIndices)
            }
            self.controllerInteraction?.searchTextHighightState = searchTextHighightState
            self.chatDisplayNode.historyNode.forEachItemNode { itemNode in
                if let itemNode = itemNode as? ChatMessageItemView {
                    itemNode.updateSearchTextHighlightState()
                }
            }
        }
    }
    
    func updateItemNodesHighlightedStates(animated: Bool) {
        self.chatDisplayNode.historyNode.forEachItemNode { itemNode in
            if let itemNode = itemNode as? ChatMessageItemView {
                itemNode.updateHighlightedState(animated: animated)
            }
        }
    }
    
    @objc func leftNavigationButtonAction() {
        if let button = self.leftNavigationButton {
            self.navigationButtonAction(button.action)
        }
    }
    
    @objc func rightNavigationButtonAction() {
        if let button = self.rightNavigationButton {
            if case let .peer(peerId) = self.chatLocation, case .openChatInfo(expandAvatar: true, _) = button.action, let storyStats = self.storyStats, storyStats.unseenCount != 0, let avatarNode = self.avatarNode {
                self.openStories(peerId: peerId, avatarHeaderNode: nil, avatarNode: avatarNode.avatarNode)
            } else {
                self.navigationButtonAction(button.action)
            }
        }
    }
    
    @objc func moreButtonPressed() {
        self.moreBarButton.play()
        self.moreBarButton.contextAction?(self.moreBarButton.containerNode, nil)
    }
    
    public func beginClearHistory(type: InteractiveHistoryClearingType) {
        guard case let .peer(peerId) = self.chatLocation else {
            return
        }
        self.updateChatPresentationInterfaceState(animated: true, interactive: true, { $0.updatedInterfaceState { $0.withoutSelectionState() } })
        self.chatDisplayNode.historyNode.historyAppearsCleared = true
        
        let statusText: String
        if case .scheduledMessages = self.presentationInterfaceState.subject {
            statusText = self.presentationData.strings.Undo_ScheduledMessagesCleared
        } else if case .forEveryone = type {
            if peerId.namespace == Namespaces.Peer.CloudUser {
                statusText = self.presentationData.strings.Undo_ChatClearedForBothSides
            } else {
                statusText = self.presentationData.strings.Undo_ChatClearedForEveryone
            }
        } else {
            statusText = self.presentationData.strings.Undo_ChatCleared
        }
        
        self.present(UndoOverlayController(presentationData: self.context.sharedContext.currentPresentationData.with { $0 }, content: .removedChat(title: statusText, text: nil), elevatedLayout: false, action: { [weak self] value in
            guard let strongSelf = self else {
                return false
            }
            if value == .commit {
                let _ = strongSelf.context.engine.messages.clearHistoryInteractively(peerId: peerId, threadId: nil, type: type).startStandalone(completed: {
                    self?.chatDisplayNode.historyNode.historyAppearsCleared = false
                })
                return true
            } else if value == .undo {
                strongSelf.chatDisplayNode.historyNode.historyAppearsCleared = false
                return true
            }
            return false
        }), in: .current)
    }
    
    public func cancelSelectingMessages() {
        self.navigationButtonAction(.cancelMessageSelection)
    }
    
    func navigationButtonAction(_ action: ChatNavigationButtonAction) {
        switch action {
        case .spacer, .toggleInfoPanel:
            break
        case .cancelMessageSelection:
            self.updateChatPresentationInterfaceState(animated: true, interactive: true, { $0.updatedInterfaceState { $0.withoutSelectionState() } })
        case .clearHistory:
            if case let .peer(peerId) = self.chatLocation {
                let beginClear: (InteractiveHistoryClearingType) -> Void = { [weak self] type in
                    self?.beginClearHistory(type: type)
                }
                
                let context = self.context
                let _ = (self.context.engine.data.get(
                    TelegramEngine.EngineData.Item.Peer.ParticipantCount(id: peerId),
                    TelegramEngine.EngineData.Item.Peer.CanDeleteHistory(id: peerId)
                )
                |> map { participantCount, canDeleteHistory -> (isLargeGroupOrChannel: Bool, canClearChannel: Bool) in
                    if let participantCount = participantCount {
                        return (participantCount > 1000, canDeleteHistory)
                    } else {
                        return (false, false)
                    }
                }
                |> deliverOnMainQueue).startStandalone(next: { [weak self] parameters in
                    guard let strongSelf = self else {
                        return
                    }
                    
                    let (isLargeGroupOrChannel, canClearChannel) = parameters
                    
                    guard let peer = strongSelf.presentationInterfaceState.renderedPeer, let chatPeer = peer.peers[peer.peerId], let mainPeer = peer.chatMainPeer else {
                        return
                    }
                    
                    enum ClearType {
                        case savedMessages
                        case secretChat
                        case group
                        case channel
                        case user
                    }
                    
                    let canClearCache: Bool
                    let canClearForMyself: ClearType?
                    let canClearForEveryone: ClearType?
                    
                    if peerId == strongSelf.context.account.peerId {
                        canClearCache = false
                        canClearForMyself = .savedMessages
                        canClearForEveryone = nil
                    } else if chatPeer is TelegramSecretChat {
                        canClearCache = false
                        canClearForMyself = .secretChat
                        canClearForEveryone = nil
                    } else if let group = chatPeer as? TelegramGroup {
                        canClearCache = false
                        
                        switch group.role {
                        case .creator:
                            canClearForMyself = .group
                            canClearForEveryone = nil
                        case .admin, .member:
                            canClearForMyself = .group
                            canClearForEveryone = nil
                        }
                    } else if let channel = chatPeer as? TelegramChannel {
                        if let username = channel.addressName, !username.isEmpty {
                            if isLargeGroupOrChannel {
                                canClearCache = true
                                canClearForMyself = nil
                                canClearForEveryone = canClearChannel ? .channel : nil
                            } else {
                                canClearCache = true
                                canClearForMyself = nil
                                
                                switch channel.info {
                                case .broadcast:
                                    if channel.flags.contains(.isCreator) {
                                        canClearForEveryone = canClearChannel ? .channel : nil
                                    } else {
                                        canClearForEveryone = canClearChannel ? .channel : nil
                                    }
                                case .group:
                                    if channel.flags.contains(.isCreator) {
                                        canClearForEveryone = canClearChannel ? .channel : nil
                                    } else {
                                        canClearForEveryone = canClearChannel ? .channel : nil
                                    }
                                }
                            }
                        } else {
                            if isLargeGroupOrChannel {
                                switch channel.info {
                                case .broadcast:
                                    canClearCache = true
                                    
                                    canClearForMyself = .channel
                                    canClearForEveryone = nil
                                case .group:
                                    canClearCache = false
                                    
                                    canClearForMyself = .channel
                                    canClearForEveryone = nil
                                }
                            } else {
                                switch channel.info {
                                case .broadcast:
                                    canClearCache = true
                                    
                                    if channel.flags.contains(.isCreator) {
                                        canClearForMyself = .channel
                                        canClearForEveryone = nil
                                    } else {
                                        canClearForMyself = .channel
                                        canClearForEveryone = nil
                                    }
                                case .group:
                                    canClearCache = false
                                    
                                    if channel.flags.contains(.isCreator) {
                                        canClearForMyself = .group
                                        canClearForEveryone = nil
                                    } else {
                                        canClearForMyself = .group
                                        canClearForEveryone = nil
                                    }
                                }
                            }
                        }
                    } else {
                        canClearCache = false
                        canClearForMyself = .user
                        
                        if let user = chatPeer as? TelegramUser, user.botInfo != nil {
                            canClearForEveryone = nil
                        } else {
                            canClearForEveryone = .user
                        }
                    }
                    
                    let actionSheet = ActionSheetController(presentationData: strongSelf.presentationData)
                    var items: [ActionSheetItem] = []
                    
                    if case .scheduledMessages = strongSelf.presentationInterfaceState.subject {
                        items.append(ActionSheetButtonItem(title: strongSelf.presentationData.strings.ScheduledMessages_ClearAllConfirmation, color: .destructive, action: { [weak actionSheet] in
                            actionSheet?.dismissAnimated()
                            
                            guard let strongSelf = self else {
                                return
                            }
                            
                            strongSelf.present(standardTextAlertController(theme: AlertControllerTheme(presentationData: strongSelf.presentationData), title: strongSelf.presentationData.strings.ChatList_DeleteSavedMessagesConfirmationTitle, text: strongSelf.presentationData.strings.ChatList_DeleteSavedMessagesConfirmationText, actions: [
                                TextAlertAction(type: .genericAction, title: strongSelf.presentationData.strings.Common_Cancel, action: {
                                }),
                                TextAlertAction(type: .destructiveAction, title: strongSelf.presentationData.strings.ChatList_DeleteSavedMessagesConfirmationAction, action: {
                                    beginClear(.scheduledMessages)
                                })
                            ], parseMarkdown: true), in: .window(.root))
                        }))
                    } else {
                        if let _ = canClearForMyself ?? canClearForEveryone {
                            items.append(DeleteChatPeerActionSheetItem(context: strongSelf.context, peer: EnginePeer(mainPeer), chatPeer: EnginePeer(chatPeer), action: .clearHistory(canClearCache: canClearCache), strings: strongSelf.presentationData.strings, nameDisplayOrder: strongSelf.presentationData.nameDisplayOrder))
                            
                            if let canClearForEveryone = canClearForEveryone {
                                let text: String
                                let confirmationText: String
                                switch canClearForEveryone {
                                case .user:
                                    text = strongSelf.presentationData.strings.ChatList_DeleteForEveryone(EnginePeer(mainPeer).compactDisplayTitle).string
                                    confirmationText = strongSelf.presentationData.strings.ChatList_DeleteForEveryoneConfirmationText
                                default:
                                    text = strongSelf.presentationData.strings.Conversation_DeleteMessagesForEveryone
                                    confirmationText = strongSelf.presentationData.strings.ChatList_DeleteForAllMembersConfirmationText
                                }
                                items.append(ActionSheetButtonItem(title: text, color: .destructive, action: { [weak actionSheet] in
                                    actionSheet?.dismissAnimated()
                                    
                                    guard let strongSelf = self else {
                                        return
                                    }
                                    
                                    strongSelf.present(standardTextAlertController(theme: AlertControllerTheme(presentationData: strongSelf.presentationData), title: strongSelf.presentationData.strings.ChatList_DeleteForEveryoneConfirmationTitle, text: confirmationText, actions: [
                                        TextAlertAction(type: .genericAction, title: strongSelf.presentationData.strings.Common_Cancel, action: {
                                        }),
                                        TextAlertAction(type: .destructiveAction, title: strongSelf.presentationData.strings.ChatList_DeleteForEveryoneConfirmationAction, action: {
                                            beginClear(.forEveryone)
                                        })
                                    ], parseMarkdown: true), in: .window(.root))
                                }))
                            }
                            if let canClearForMyself = canClearForMyself {
                                let text: String
                                switch canClearForMyself {
                                case .savedMessages, .secretChat:
                                    text = strongSelf.presentationData.strings.Conversation_ClearAll
                                default:
                                    text = strongSelf.presentationData.strings.ChatList_DeleteForCurrentUser
                                }
                                items.append(ActionSheetButtonItem(title: text, color: .destructive, action: { [weak self, weak actionSheet] in
                                    actionSheet?.dismissAnimated()
                                    if mainPeer.id == context.account.peerId, let strongSelf = self {
                                        strongSelf.present(standardTextAlertController(theme: AlertControllerTheme(presentationData: strongSelf.presentationData), title: strongSelf.presentationData.strings.ChatList_DeleteSavedMessagesConfirmationTitle, text: strongSelf.presentationData.strings.ChatList_DeleteSavedMessagesConfirmationText, actions: [
                                            TextAlertAction(type: .genericAction, title: strongSelf.presentationData.strings.Common_Cancel, action: {
                                            }),
                                            TextAlertAction(type: .destructiveAction, title: strongSelf.presentationData.strings.ChatList_DeleteSavedMessagesConfirmationAction, action: {
                                                beginClear(.forLocalPeer)
                                            })
                                        ], parseMarkdown: true), in: .window(.root))
                                    } else {
                                        beginClear(.forLocalPeer)
                                    }
                                }))
                            }
                        }
                        
                        if canClearCache {
                            items.append(ActionSheetButtonItem(title: strongSelf.presentationData.strings.Conversation_ClearCache, color: .accent, action: { [weak actionSheet] in
                                actionSheet?.dismissAnimated()
                                
                                guard let strongSelf = self else {
                                    return
                                }
                                
                                strongSelf.navigationButtonAction(.clearCache)
                            }))
                        }
                        
                        if chatPeer.canSetupAutoremoveTimeout(accountPeerId: strongSelf.context.account.peerId) {
                            items.append(ActionSheetButtonItem(title: strongSelf.presentationInterfaceState.autoremoveTimeout == nil ? strongSelf.presentationData.strings.Conversation_AutoremoveActionEnable : strongSelf.presentationData.strings.Conversation_AutoremoveActionEdit, color: .accent, action: { [weak actionSheet] in
                                guard let actionSheet = actionSheet else {
                                    return
                                }
                                guard let strongSelf = self else {
                                    return
                                }
                                
                                actionSheet.dismissAnimated()
                                
                                strongSelf.presentAutoremoveSetup()
                            }))
                        }
                    }

                    actionSheet.setItemGroups([ActionSheetItemGroup(items: items), ActionSheetItemGroup(items: [
                        ActionSheetButtonItem(title: strongSelf.presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                            actionSheet?.dismissAnimated()
                        })
                    ])])
                    
                    strongSelf.chatDisplayNode.dismissInput()
                    strongSelf.present(actionSheet, in: .window(.root))
                })
            }
        case let .openChatInfo(expandAvatar, recommendedChannels):
            let _ = self.presentVoiceMessageDiscardAlert(action: {
                switch self.chatLocationInfoData {
                case let .peer(peerView):
                    self.navigationActionDisposable.set((peerView.get()
                    |> take(1)
                    |> deliverOnMainQueue).startStrict(next: { [weak self] peerView in
                        if let strongSelf = self, let peer = peerView.peers[peerView.peerId], peer.restrictionText(platform: "ios", contentSettings: strongSelf.context.currentContentSettings.with { $0 }) == nil && !strongSelf.presentationInterfaceState.isNotAccessible {
                            if peer.id == strongSelf.context.account.peerId {
                                if let peer = strongSelf.presentationInterfaceState.renderedPeer?.chatMainPeer, let infoController = strongSelf.context.sharedContext.makePeerInfoController(context: strongSelf.context, updatedPresentationData: strongSelf.updatedPresentationData, peer: peer, mode: .generic, avatarInitiallyExpanded: false, fromChat: true, requestsContext: nil) {
                                    strongSelf.effectiveNavigationController?.pushViewController(infoController)
                                }
                            } else {
                                var expandAvatar = expandAvatar
                                if peer.smallProfileImage == nil {
                                    expandAvatar = false
                                }
                                if let validLayout = strongSelf.validLayout, validLayout.deviceMetrics.type == .tablet {
                                    expandAvatar = false
                                }
                                if let infoController = strongSelf.context.sharedContext.makePeerInfoController(context: strongSelf.context, updatedPresentationData: strongSelf.updatedPresentationData, peer: peer, mode: recommendedChannels ? .recommendedChannels : .generic, avatarInitiallyExpanded: expandAvatar, fromChat: true, requestsContext: strongSelf.inviteRequestsContext) {
                                    strongSelf.effectiveNavigationController?.pushViewController(infoController)
                                }
                            }
                        }
                    }))
                case .replyThread:
                    if let peer = self.presentationInterfaceState.renderedPeer?.peer, case let .replyThread(replyThreadMessage) = self.chatLocation, replyThreadMessage.peerId == self.context.account.peerId {
                        if let infoController = self.context.sharedContext.makePeerInfoController(context: self.context, updatedPresentationData: self.updatedPresentationData, peer: peer, mode: .forumTopic(thread: replyThreadMessage), avatarInitiallyExpanded: false, fromChat: true, requestsContext: nil) {
                            self.effectiveNavigationController?.pushViewController(infoController)
                        }
                    } else if let channel = self.presentationInterfaceState.renderedPeer?.peer as? TelegramChannel, channel.flags.contains(.isForum), case let .replyThread(message) = self.chatLocation {
                        if let infoController = self.context.sharedContext.makePeerInfoController(context: self.context, updatedPresentationData: self.updatedPresentationData, peer: channel, mode: .forumTopic(thread: message), avatarInitiallyExpanded: false, fromChat: true, requestsContext: self.inviteRequestsContext) {
                            self.effectiveNavigationController?.pushViewController(infoController)
                        }
                    }
                case .feed:
                    break
                }
            })
        case .search:
            self.interfaceInteraction?.beginMessageSearch(.everything, "")
        case .dismiss:
            self.dismiss()
        case .clearCache:
            let controller = OverlayStatusController(theme: self.presentationData.theme, type: .loading(cancelled: nil))
            self.present(controller, in: .window(.root))
            
            let disposable: MetaDisposable
            if let currentDisposable = self.clearCacheDisposable {
                disposable = currentDisposable
            } else {
                disposable = MetaDisposable()
                self.clearCacheDisposable = disposable
            }
        
            switch self.chatLocationInfoData {
            case let .peer(peerView):
                self.navigationActionDisposable.set((peerView.get()
                |> take(1)
                |> deliverOnMainQueue).startStrict(next: { [weak self] peerView in
                    guard let strongSelf = self, let peer = peerView.peers[peerView.peerId] else {
                        return
                    }
                    let peerId = peer.id
                    
                    let _ = (strongSelf.context.engine.resources.collectCacheUsageStats(peerId: peer.id)
                    |> deliverOnMainQueue).startStandalone(next: { [weak self, weak controller] result in
                        controller?.dismiss()
                        
                        guard let strongSelf = self, case let .result(stats) = result, let categories = stats.media[peer.id] else {
                            return
                        }
                        let presentationData = strongSelf.presentationData
                        let controller = ActionSheetController(presentationData: presentationData)
                        let dismissAction: () -> Void = { [weak controller] in
                            controller?.dismissAnimated()
                        }
                        
                        var sizeIndex: [PeerCacheUsageCategory: (Bool, Int64)] = [:]
                        
                        var itemIndex = 1
                        
                        var selectedSize: Int64 = 0
                        let updateTotalSize: () -> Void = { [weak controller] in
                            controller?.updateItem(groupIndex: 0, itemIndex: itemIndex, { item in
                                let title: String
                                let filteredSize = sizeIndex.values.reduce(0, { $0 + ($1.0 ? $1.1 : 0) })
                                selectedSize = filteredSize
                                
                                if filteredSize == 0 {
                                    title = presentationData.strings.Cache_ClearNone
                                } else {
                                    title = presentationData.strings.Cache_Clear("\(dataSizeString(filteredSize, formatting: DataSizeStringFormatting(presentationData: presentationData)))").string
                                }
                                
                                if let item = item as? ActionSheetButtonItem {
                                    return ActionSheetButtonItem(title: title, color: filteredSize != 0 ? .accent : .disabled, enabled: filteredSize != 0, action: item.action)
                                }
                                return item
                            })
                        }
                        
                        let toggleCheck: (PeerCacheUsageCategory, Int) -> Void = { [weak controller] category, itemIndex in
                            if let (value, size) = sizeIndex[category] {
                                sizeIndex[category] = (!value, size)
                            }
                            controller?.updateItem(groupIndex: 0, itemIndex: itemIndex, { item in
                                if let item = item as? ActionSheetCheckboxItem {
                                    return ActionSheetCheckboxItem(title: item.title, label: item.label, value: !item.value, action: item.action)
                                }
                                return item
                            })
                            updateTotalSize()
                        }
                        var items: [ActionSheetItem] = []
                        
                        items.append(DeleteChatPeerActionSheetItem(context: strongSelf.context, peer: EnginePeer(peer), chatPeer: EnginePeer(peer), action: .clearCache, strings: presentationData.strings, nameDisplayOrder: presentationData.nameDisplayOrder))
                        
                        let validCategories: [PeerCacheUsageCategory] = [.image, .video, .audio, .file]
                        
                        var totalSize: Int64 = 0
                        
                        func stringForCategory(strings: PresentationStrings, category: PeerCacheUsageCategory) -> String {
                            switch category {
                                case .image:
                                    return strings.Cache_Photos
                                case .video:
                                    return strings.Cache_Videos
                                case .audio:
                                    return strings.Cache_Music
                                case .file:
                                    return strings.Cache_Files
                            }
                        }
                        
                        for categoryId in validCategories {
                            if let media = categories[categoryId] {
                                var categorySize: Int64 = 0
                                for (_, size) in media {
                                    categorySize += size
                                }
                                sizeIndex[categoryId] = (true, categorySize)
                                totalSize += categorySize
                                if categorySize > 1024 {
                                    let index = itemIndex
                                    items.append(ActionSheetCheckboxItem(title: stringForCategory(strings: presentationData.strings, category: categoryId), label: dataSizeString(categorySize, formatting: DataSizeStringFormatting(presentationData: presentationData)), value: true, action: { value in
                                        toggleCheck(categoryId, index)
                                    }))
                                    itemIndex += 1
                                }
                            }
                        }
                        selectedSize = totalSize
                        
                        if items.isEmpty {
                            strongSelf.presentClearCacheSuggestion()
                        } else {
                            items.append(ActionSheetButtonItem(title: presentationData.strings.Cache_Clear("\(dataSizeString(totalSize, formatting: DataSizeStringFormatting(presentationData: presentationData)))").string, action: {
                                let clearCategories = sizeIndex.keys.filter({ sizeIndex[$0]!.0 })
                                var clearMediaIds = Set<MediaId>()
                                
                                var media = stats.media
                                if var categories = media[peerId] {
                                    for category in clearCategories {
                                        if let contents = categories[category] {
                                            for (mediaId, _) in contents {
                                                clearMediaIds.insert(mediaId)
                                            }
                                        }
                                        categories.removeValue(forKey: category)
                                    }
                                    
                                    media[peerId] = categories
                                }
                                
                                var clearResourceIds = Set<MediaResourceId>()
                                for id in clearMediaIds {
                                    if let ids = stats.mediaResourceIds[id] {
                                        for resourceId in ids {
                                            clearResourceIds.insert(resourceId)
                                        }
                                    }
                                }
                                
                                var signal = strongSelf.context.engine.resources.clearCachedMediaResources(mediaResourceIds: clearResourceIds)
                                
                                var cancelImpl: (() -> Void)?
                                let presentationData = strongSelf.context.sharedContext.currentPresentationData.with { $0 }
                                let progressSignal = Signal<Never, NoError> { subscriber in
                                    let controller = OverlayStatusController(theme: presentationData.theme,  type: .loading(cancelled: {
                                        cancelImpl?()
                                    }))
                                    strongSelf.present(controller, in: .window(.root), with: ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
                                    return ActionDisposable { [weak controller] in
                                        Queue.mainQueue().async() {
                                            controller?.dismiss()
                                        }
                                    }
                                }
                                |> runOn(Queue.mainQueue())
                                |> delay(0.15, queue: Queue.mainQueue())
                                let progressDisposable = progressSignal.startStrict()
                                
                                signal = signal
                                |> afterDisposed {
                                    Queue.mainQueue().async {
                                        progressDisposable.dispose()
                                    }
                                }
                                cancelImpl = {
                                    disposable.set(nil)
                                }
                                disposable.set((signal
                                |> deliverOnMainQueue).startStrict(completed: { [weak self] in
                                    if let strongSelf = self, let _ = strongSelf.validLayout {
                                        strongSelf.present(UndoOverlayController(presentationData: presentationData, content: .succeed(text: presentationData.strings.ClearCache_Success("\(dataSizeString(selectedSize, formatting: DataSizeStringFormatting(presentationData: presentationData)))", stringForDeviceType()).string, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false }), in: .current)
                                    }
                                }))

                                dismissAction()
                                strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, { $0.updatedInterfaceState({ $0.withoutSelectionState() }) })
                            }))
                            
                            items.append(ActionSheetButtonItem(title: presentationData.strings.ClearCache_StorageUsage, action: { [weak self] in
                                dismissAction()
                                strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, { $0.updatedInterfaceState({ $0.withoutSelectionState() }) })
                                
                                if let strongSelf = self {
                                    let context = strongSelf.context
                                    let controller = StorageUsageScreen(context: context, makeStorageUsageExceptionsScreen: { category in
                                        return storageUsageExceptionsScreen(context: context, category: category)
                                    })
                                    strongSelf.present(controller, in: .window(.root), with: ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
                                }
                            }))
                            
                            controller.setItemGroups([
                                ActionSheetItemGroup(items: items),
                                ActionSheetItemGroup(items: [ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, action: { dismissAction() })])
                            ])
                            strongSelf.chatDisplayNode.dismissInput()
                            strongSelf.present(controller, in: .window(.root))
                        }
                    })
                }))
            case .replyThread:
                break
            case .feed:
                break
            }
        }
    }
    
    func editMessageMediaWithMessages(_ messages: [EnqueueMessage]) {
        if let message = messages.first, case let .message(text, attributes, _, maybeMediaReference, _, _, _, _, _, _) = message, let mediaReference = maybeMediaReference {
            self.updateChatPresentationInterfaceState(animated: true, interactive: true, { state in
                var entities: [MessageTextEntity] = []
                for attribute in attributes {
                    if let entitiesAttrbute = attribute as? TextEntitiesMessageAttribute {
                        entities = entitiesAttrbute.entities
                    }
                }
                let attributedText = chatInputStateStringWithAppliedEntities(text, entities: entities)
                
                var state = state
                if let editMessageState = state.editMessageState, case let .media(options) = editMessageState.content, !options.isEmpty {
                    state = state.updatedEditMessageState(ChatEditInterfaceMessageState(content: editMessageState.content, mediaReference: mediaReference))
                }
                if !text.isEmpty {
                    state = state.updatedInterfaceState { state in
                        if let editMessage = state.editMessage {
                            return state.withUpdatedEditMessage(editMessage.withUpdatedInputState(ChatTextInputState(inputText: attributedText)))
                        }
                        return state
                    }
                }
                return state
            })
            self.interfaceInteraction?.editMessage()
        }
    }
    
    func editMessageMediaWithLegacySignals(_ signals: [Any]) {
        let _ = (legacyAssetPickerEnqueueMessages(context: self.context, account: self.context.account, signals: signals)
        |> deliverOnMainQueue).startStandalone(next: { [weak self] messages in
            self?.editMessageMediaWithMessages(messages.map { $0.message })
        })
    }
    
    public func presentAttachmentBot(botId: PeerId, payload: String?, justInstalled: Bool) {
        self.attachmentController?.dismiss(animated: true, completion: nil)
        self.presentAttachmentMenu(subject: .bot(id: botId, payload: payload, justInstalled: justInstalled))
    }
    
    public func presentBotApp(botApp: BotApp, botPeer: EnginePeer, payload: String?, concealed: Bool = false, commit: @escaping () -> Void = {}) {
        guard let peerId = self.chatLocation.peerId else {
            return
        }
        self.attachmentController?.dismiss(animated: true, completion: nil)
        
        let openBotApp: (Bool, Bool) -> Void = { [weak self] allowWrite, justInstalled in
            guard let strongSelf = self else {
                return
            }
            commit()
            
            strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, {
                return $0.updatedTitlePanelContext {
                    if !$0.contains(where: {
                        switch $0 {
                        case .requestInProgress:
                            return true
                        default:
                            return false
                        }
                    }) {
                        var updatedContexts = $0
                        updatedContexts.append(.requestInProgress)
                        return updatedContexts.sorted()
                    }
                    return $0
                }
            })
            
            let updateProgress = { [weak self] in
                Queue.mainQueue().async {
                    if let strongSelf = self {
                        strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, {
                            return $0.updatedTitlePanelContext {
                                if let index = $0.firstIndex(where: {
                                    switch $0 {
                                    case .requestInProgress:
                                        return true
                                    default:
                                        return false
                                    }
                                }) {
                                    var updatedContexts = $0
                                    updatedContexts.remove(at: index)
                                    return updatedContexts
                                }
                                return $0
                            }
                        })
                    }
                }
            }
            
            let botAddress = botPeer.addressName ?? ""
            strongSelf.messageActionCallbackDisposable.set(((strongSelf.context.engine.messages.requestAppWebView(peerId: peerId, appReference: .id(id: botApp.id, accessHash: botApp.accessHash), payload: payload, themeParams: generateWebAppThemeParams(strongSelf.presentationData.theme), allowWrite: allowWrite)
            |> afterDisposed {
                updateProgress()
            })
            |> deliverOnMainQueue).startStrict(next: { [weak self] url in
                guard let strongSelf = self else {
                    return
                }
                let params = WebAppParameters(source: .generic, peerId: peerId, botId: botPeer.id, botName: botApp.title, url: url, queryId: 0, payload: payload, buttonText: "", keepAliveSignal: nil, forceHasSettings: botApp.flags.contains(.hasSettings))
                let controller = standaloneWebAppController(context: strongSelf.context, updatedPresentationData: strongSelf.updatedPresentationData, params: params, threadId: strongSelf.chatLocation.threadId, openUrl: { [weak self] url, concealed, commit in
                    self?.openUrl(url, concealed: concealed, forceExternal: true, commit: commit)
                }, requestSwitchInline: { [weak self] query, chatTypes, completion in
                    if let strongSelf = self {
                        if let chatTypes {
                            let controller = strongSelf.context.sharedContext.makePeerSelectionController(PeerSelectionControllerParams(context: strongSelf.context, filter: [.excludeRecent, .doNotSearchMessages], requestPeerType: chatTypes, hasContactSelector: false, hasCreation: false))
                            controller.peerSelected = { [weak self, weak controller] peer, _ in
                                if let strongSelf = self {
                                    completion()
                                    controller?.dismiss()
                                    strongSelf.controllerInteraction?.activateSwitchInline(peer.id, "@\(botAddress) \(query)", nil)
                                }
                            }
                            strongSelf.push(controller)
                        } else {
                            strongSelf.controllerInteraction?.activateSwitchInline(peerId, "@\(botAddress) \(query)", nil)
                        }
                    }
                }, completion: { [weak self] in
                    self?.chatDisplayNode.historyNode.scrollToEndOfHistory()
                }, getNavigationController: { [weak self] in
                    return self?.effectiveNavigationController
                })
                controller.navigationPresentation = .flatModal
                strongSelf.currentWebAppController = controller
                strongSelf.push(controller)
                
                if justInstalled {
                    let content: UndoOverlayContent = .succeed(text: strongSelf.presentationData.strings.WebApp_ShortcutsSettingsAdded(botPeer.compactDisplayTitle).string, timeout: 5.0, customUndoText: nil)
                    controller.present(UndoOverlayController(presentationData: strongSelf.presentationData, content: content, elevatedLayout: false, position: .top, action: { _ in return false }), in: .current)
                }
            }, error: { [weak self] error in
                if let strongSelf = self {
                    strongSelf.present(textAlertController(context: strongSelf.context, updatedPresentationData: strongSelf.updatedPresentationData, title: nil, text: strongSelf.presentationData.strings.Login_UnknownError, actions: [TextAlertAction(type: .defaultAction, title: strongSelf.presentationData.strings.Common_OK, action: {
                    })]), in: .window(.root))
                }
            }))
        }
        
        let _ = combineLatest(
            queue: Queue.mainQueue(),
            ApplicationSpecificNotice.getBotGameNotice(accountManager: self.context.sharedContext.accountManager, peerId: botPeer.id),
            self.context.engine.messages.attachMenuBots(),
            self.context.engine.messages.getAttachMenuBot(botId: botPeer.id, cached: true)
            |> map(Optional.init)
            |> `catch` { _ -> Signal<AttachMenuBot?, NoError> in
                return .single(nil)
            }
        ).startStandalone(next: { [weak self] value, attachMenuBots, attachMenuBot in
            guard let self else {
                return
            }
            
            var isAttachMenuBotInstalled: Bool?
            if let _ = attachMenuBot {
                if let _ = attachMenuBots.first(where: { $0.peer.id == botPeer.id && !$0.flags.contains(.notActivated) }) {
                    isAttachMenuBotInstalled = true
                } else {
                    isAttachMenuBotInstalled = false
                }
            }
            
            let context = self.context
            if !value || concealed || botApp.flags.contains(.notActivated) || isAttachMenuBotInstalled == false {
                if let isAttachMenuBotInstalled, let attachMenuBot {
                    if !isAttachMenuBotInstalled {
                        let controller = webAppTermsAlertController(context: context, updatedPresentationData: self.updatedPresentationData, bot: attachMenuBot, completion: { allowWrite in
                            let _ = ApplicationSpecificNotice.setBotGameNotice(accountManager: context.sharedContext.accountManager, peerId: botPeer.id).startStandalone()
                            let _ = (context.engine.messages.addBotToAttachMenu(botId: botPeer.id, allowWrite: allowWrite)
                            |> deliverOnMainQueue).startStandalone(error: { _ in
                            }, completed: {
                                openBotApp(allowWrite, true)
                            })
                        })
                        self.present(controller, in: .window(.root))
                    } else {
                        openBotApp(false, false)
                    }
                } else {
                    let controller = webAppLaunchConfirmationController(context: context, updatedPresentationData: self.updatedPresentationData, peer: botPeer, requestWriteAccess: botApp.flags.contains(.notActivated) && botApp.flags.contains(.requiresWriteAccess), completion: { allowWrite in
                        let _ = ApplicationSpecificNotice.setBotGameNotice(accountManager: context.sharedContext.accountManager, peerId: botPeer.id).startStandalone()
                        openBotApp(allowWrite, false)
                    }, showMore: { [weak self] in
                        if let self {
                            self.openResolved(result: .peer(botPeer._asPeer(), .info(nil)), sourceMessageId: nil)
                        }
                    })
                    self.present(controller, in: .window(.root))
                }
            } else {
                openBotApp(false, false)
            }
        })
    }
    
    func displayPollSolution(solution: TelegramMediaPollResults.Solution, sourceNode: ASDisplayNode, isAutomatic: Bool) {
        var maybeFoundItemNode: ChatMessageItemView?
        self.chatDisplayNode.historyNode.forEachItemNode { itemNode in
            if let itemNode = itemNode as? ChatMessageItemView {
                if sourceNode.view.isDescendant(of: itemNode.view) {
                    maybeFoundItemNode = itemNode
                }
            }
        }
        guard let foundItemNode = maybeFoundItemNode, let item = foundItemNode.item else {
            return
        }
        
        var found = false
        self.forEachController({ controller in
            if let controller = controller as? TooltipScreen {
                if controller.text == .entities(text: solution.text, entities: solution.entities) {
                    found = true
                    controller.dismiss()
                    return false
                }
            }
            return true
        })
        if found {
            return
        }
        
        let tooltipScreen = TooltipScreen(account: self.context.account, sharedContext: self.context.sharedContext, text: .entities(text: solution.text, entities: solution.entities), icon: .animation(name: "anim_infotip", delay: 0.2, tintColor: nil), location: .top, shouldDismissOnTouch: { point, _ in
            return .ignore
        }, openActiveTextItem: { [weak self] item, action in
            guard let strongSelf = self else {
                return
            }
            switch item {
            case let .url(url, concealed):
                switch action {
                case .tap:
                    strongSelf.openUrl(url, concealed: concealed)
                case .longTap:
                    strongSelf.controllerInteraction?.longTap(.url(url), nil)
                }
            case let .mention(peerId, mention):
                switch action {
                case .tap:
                    let _ = (strongSelf.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
                    |> deliverOnMainQueue).startStandalone(next: { peer in
                        if let strongSelf = self, let peer = peer {
                            strongSelf.controllerInteraction?.openPeer(peer, .default, nil, .default)
                        }
                    })
                case .longTap:
                    strongSelf.controllerInteraction?.longTap(.peerMention(peerId, mention), nil)
                }
            case let .textMention(mention):
                switch action {
                case .tap:
                    strongSelf.controllerInteraction?.openPeerMention(mention, nil)
                case .longTap:
                    strongSelf.controllerInteraction?.longTap(.mention(mention), nil)
                }
            case let .botCommand(command):
                switch action {
                case .tap:
                    strongSelf.controllerInteraction?.sendBotCommand(nil, command)
                case .longTap:
                    strongSelf.controllerInteraction?.longTap(.command(command), nil)
                }
            case let .hashtag(hashtag):
                switch action {
                case .tap:
                    strongSelf.controllerInteraction?.openHashtag(nil, hashtag)
                case .longTap:
                    strongSelf.controllerInteraction?.longTap(.hashtag(hashtag), nil)
                }
            }
        })
        
        let messageId = item.message.id
        self.controllerInteraction?.currentPollMessageWithTooltip = messageId
        self.updatePollTooltipMessageState(animated: !isAutomatic)
        
        tooltipScreen.willBecomeDismissed = { [weak self] tooltipScreen in
            guard let strongSelf = self else {
                return
            }
            if strongSelf.controllerInteraction?.currentPollMessageWithTooltip == messageId {
                strongSelf.controllerInteraction?.currentPollMessageWithTooltip = nil
                strongSelf.updatePollTooltipMessageState(animated: true)
            }
        }
        
        self.forEachController({ controller in
            if let controller = controller as? TooltipScreen {
                controller.dismiss()
            }
            return true
        })
        
        self.present(tooltipScreen, in: .current)
    }
    
    public func displayPromoAnnouncement(text: String) {
        let psaText: String = text
        let psaEntities: [MessageTextEntity] = generateTextEntities(psaText, enabledTypes: .allUrl)
        
        var found = false
        self.forEachController({ controller in
            if let controller = controller as? TooltipScreen {
                if controller.text == .plain(text: psaText) {
                    found = true
                    controller.dismiss()
                    return false
                }
            }
            return true
        })
        if found {
            return
        }
        
        let tooltipScreen = TooltipScreen(account: self.context.account, sharedContext: self.context.sharedContext, text: .entities(text: psaText, entities: psaEntities), icon: .animation(name: "anim_infotip", delay: 0.2, tintColor: nil), location: .top, displayDuration: .custom(10.0), shouldDismissOnTouch: { point, _ in
            return .ignore
        }, openActiveTextItem: { [weak self] item, action in
            guard let strongSelf = self else {
                return
            }
            switch item {
            case let .url(url, concealed):
                switch action {
                case .tap:
                    strongSelf.openUrl(url, concealed: concealed)
                case .longTap:
                    strongSelf.controllerInteraction?.longTap(.url(url), nil)
                }
            case let .mention(peerId, mention):
                switch action {
                case .tap:
                    let _ = (strongSelf.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
                    |> deliverOnMainQueue).startStandalone(next: { peer in
                        if let strongSelf = self, let peer = peer {
                            strongSelf.controllerInteraction?.openPeer(peer, .default, nil, .default)
                        }
                    })
                case .longTap:
                    strongSelf.controllerInteraction?.longTap(.peerMention(peerId, mention), nil)
                }
            case let .textMention(mention):
                switch action {
                case .tap:
                    strongSelf.controllerInteraction?.openPeerMention(mention, nil)
                case .longTap:
                    strongSelf.controllerInteraction?.longTap(.mention(mention), nil)
                }
            case let .botCommand(command):
                switch action {
                case .tap:
                    strongSelf.controllerInteraction?.sendBotCommand(nil, command)
                case .longTap:
                    strongSelf.controllerInteraction?.longTap(.command(command), nil)
                }
            case let .hashtag(hashtag):
                switch action {
                case .tap:
                    strongSelf.controllerInteraction?.openHashtag(nil, hashtag)
                case .longTap:
                    strongSelf.controllerInteraction?.longTap(.hashtag(hashtag), nil)
                }
            }
        })
        
        self.forEachController({ controller in
            if let controller = controller as? TooltipScreen {
                controller.dismiss()
            }
            return true
        })
        
        self.present(tooltipScreen, in: .current)
    }
    
    func displayPsa(type: String, sourceNode: ASDisplayNode, isAutomatic: Bool) {
        var maybeFoundItemNode: ChatMessageItemView?
        self.chatDisplayNode.historyNode.forEachItemNode { itemNode in
            if let itemNode = itemNode as? ChatMessageItemView {
                if sourceNode.view.isDescendant(of: itemNode.view) {
                    maybeFoundItemNode = itemNode
                }
            }
        }
        guard let foundItemNode = maybeFoundItemNode, let item = foundItemNode.item else {
            return
        }
        
        var psaText = self.presentationData.strings.Chat_GenericPsaTooltip
        let key = "Chat.PsaTooltip.\(type)"
        if let string = self.presentationData.strings.primaryComponent.dict[key] {
            psaText = string
        } else if let string = self.presentationData.strings.secondaryComponent?.dict[key] {
            psaText = string
        }
        
        let psaEntities: [MessageTextEntity] = generateTextEntities(psaText, enabledTypes: .allUrl)
        
        let messageId = item.message.id
        
        var found = false
        self.forEachController({ controller in
            if let controller = controller as? TooltipScreen {
                if controller.text == .plain(text: psaText) {
                    found = true
                    controller.resetDismissTimeout()
                    
                    controller.willBecomeDismissed = { [weak self] tooltipScreen in
                        guard let strongSelf = self else {
                            return
                        }
                        if strongSelf.controllerInteraction?.currentPsaMessageWithTooltip == messageId {
                            strongSelf.controllerInteraction?.currentPsaMessageWithTooltip = nil
                            strongSelf.updatePollTooltipMessageState(animated: true)
                        }
                    }
                    
                    return false
                }
            }
            return true
        })
        if found {
            self.controllerInteraction?.currentPsaMessageWithTooltip = messageId
            self.updatePollTooltipMessageState(animated: !isAutomatic)
            
            return
        }
        
        let tooltipScreen = TooltipScreen(account: self.context.account, sharedContext: self.context.sharedContext, text: .entities(text: psaText, entities: psaEntities), icon: .animation(name: "anim_infotip", delay: 0.2, tintColor: nil), location: .top, displayDuration: .custom(10.0), shouldDismissOnTouch: { point, _ in
            return .ignore
        }, openActiveTextItem: { [weak self] item, action in
            guard let strongSelf = self else {
                return
            }
            switch item {
            case let .url(url, concealed):
                switch action {
                case .tap:
                    strongSelf.openUrl(url, concealed: concealed)
                case .longTap:
                    strongSelf.controllerInteraction?.longTap(.url(url), nil)
                }
            case let .mention(peerId, mention):
                switch action {
                case .tap:
                    let _ = (strongSelf.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
                    |> deliverOnMainQueue).startStandalone(next: { peer in
                        if let strongSelf = self, let peer = peer {
                            strongSelf.controllerInteraction?.openPeer(peer, .default, nil, .default)
                        }
                    })
                case .longTap:
                    strongSelf.controllerInteraction?.longTap(.peerMention(peerId, mention), nil)
                }
            case let .textMention(mention):
                switch action {
                case .tap:
                    strongSelf.controllerInteraction?.openPeerMention(mention, nil)
                case .longTap:
                    strongSelf.controllerInteraction?.longTap(.mention(mention), nil)
                }
            case let .botCommand(command):
                switch action {
                case .tap:
                    strongSelf.controllerInteraction?.sendBotCommand(nil, command)
                case .longTap:
                    strongSelf.controllerInteraction?.longTap(.command(command), nil)
                }
            case let .hashtag(hashtag):
                switch action {
                case .tap:
                    strongSelf.controllerInteraction?.openHashtag(nil, hashtag)
                case .longTap:
                    strongSelf.controllerInteraction?.longTap(.hashtag(hashtag), nil)
                }
            }
        })
        
        self.controllerInteraction?.currentPsaMessageWithTooltip = messageId
        self.updatePollTooltipMessageState(animated: !isAutomatic)
        
        tooltipScreen.willBecomeDismissed = { [weak self] tooltipScreen in
            guard let strongSelf = self else {
                return
            }
            if strongSelf.controllerInteraction?.currentPsaMessageWithTooltip == messageId {
                strongSelf.controllerInteraction?.currentPsaMessageWithTooltip = nil
                strongSelf.updatePollTooltipMessageState(animated: true)
            }
        }
        
        self.forEachController({ controller in
            if let controller = controller as? TooltipScreen {
                controller.dismiss()
            }
            return true
        })
        
        self.present(tooltipScreen, in: .current)
    }
        
    func configurePollCreation(isQuiz: Bool? = nil) -> CreatePollControllerImpl? {
        guard let peer = self.presentationInterfaceState.renderedPeer?.peer else {
            return nil
        }
        return createPollController(context: self.context, updatedPresentationData: self.updatedPresentationData, peer: EnginePeer(peer), isQuiz: isQuiz, completion: { [weak self] poll in
            guard let strongSelf = self else {
                return
            }
            let replyMessageSubject = strongSelf.presentationInterfaceState.interfaceState.replyMessageSubject
            strongSelf.chatDisplayNode.setupSendActionOnViewUpdate({
                if let strongSelf = self {
                    strongSelf.chatDisplayNode.collapseInput()
                    
                    strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: false, {
                        $0.updatedInterfaceState { $0.withUpdatedReplyMessageSubject(nil) }
                    })
                }
            }, nil)
            let message: EnqueueMessage = .message(
                text: "",
                attributes: [],
                inlineStickers: [:],
                mediaReference: .standalone(media: TelegramMediaPoll(
                    pollId: MediaId(namespace: Namespaces.Media.LocalPoll, id: Int64.random(in: Int64.min ... Int64.max)),
                    publicity: poll.publicity,
                    kind: poll.kind,
                    text: poll.text,
                    options: poll.options,
                    correctAnswers: poll.correctAnswers,
                    results: poll.results,
                    isClosed: false,
                    deadlineTimeout: poll.deadlineTimeout
                )),
                threadId: strongSelf.chatLocation.threadId,
                replyToMessageId: nil,
                replyToStoryId: nil,
                localGroupingKey: nil,
                correlationId: nil,
                bubbleUpEmojiOrStickersets: []
            )
            strongSelf.sendMessages([message.withUpdatedReplyToMessageId(replyMessageSubject?.subjectModel)])
        })
    }
    
    func transformEnqueueMessages(_ messages: [EnqueueMessage]) -> [EnqueueMessage] {
        let silentPosting = self.presentationInterfaceState.interfaceState.silentPosting
        return transformEnqueueMessages(messages, silentPosting: silentPosting)
    }
    
    @discardableResult func dismissAllUndoControllers() -> UndoOverlayController? {
        var currentOverlayController: UndoOverlayController?
        
        self.window?.forEachController({ controller in
            if let controller = controller as? UndoOverlayController {
                currentOverlayController = controller
            }
        })
        self.forEachController({ controller in
            if let controller = controller as? UndoOverlayController {
                currentOverlayController = controller
            }
            return true
        })
        
        return currentOverlayController
    }
    
    func displayPremiumStickerTooltip(file: TelegramMediaFile, message: Message) {
        let premiumConfiguration = PremiumConfiguration.with(appConfiguration: self.context.currentAppConfiguration.with { $0 })
        guard !premiumConfiguration.isPremiumDisabled else {
            return
        }
        
        let currentOverlayController: UndoOverlayController? = self.dismissAllUndoControllers()
        
        if let currentOverlayController = currentOverlayController {
            if case .sticker = currentOverlayController.content {
                return
            }
            currentOverlayController.dismissWithCommitAction()
        }
        
        var stickerPackReference: StickerPackReference?
        for attribute in file.attributes {
            if case let .Sticker(_, packReference, _) = attribute, let packReference = packReference {
                stickerPackReference = packReference
                break
            }
        }
        
        if let stickerPackReference = stickerPackReference {
            let _ = (self.context.engine.stickers.loadedStickerPack(reference: stickerPackReference, forceActualized: false)
            |> deliverOnMainQueue).startStandalone(next: { [weak self] stickerPack in
                if let strongSelf = self, case let .result(info, _, _) = stickerPack {
                    strongSelf.present(UndoOverlayController(presentationData: strongSelf.presentationData, content: .sticker(context: strongSelf.context, file: file, loop: true, title: info.title, text: strongSelf.presentationData.strings.Stickers_PremiumPackInfoText, undoText: strongSelf.presentationData.strings.Stickers_PremiumPackView, customAction: nil), elevatedLayout: false, action: { [weak self] action in
                        if let strongSelf = self, action == .undo {
                            let _ = strongSelf.controllerInteraction?.openMessage(message, OpenMessageParams(mode: .default))
                        }
                        return false
                    }), in: .current)
                }
            })
        }
    }
    
    func displayEmojiPackTooltip(file: TelegramMediaFile, message: Message) {
        let premiumConfiguration = PremiumConfiguration.with(appConfiguration: self.context.currentAppConfiguration.with { $0 })
        guard !premiumConfiguration.isPremiumDisabled else {
            return
        }
                
        var currentOverlayController: UndoOverlayController?
        
        self.window?.forEachController({ controller in
            if let controller = controller as? UndoOverlayController {
                currentOverlayController = controller
            }
        })
        self.forEachController({ controller in
            if let controller = controller as? UndoOverlayController {
                currentOverlayController = controller
            }
            return true
        })
        
        if let currentOverlayController = currentOverlayController {
            if case .sticker = currentOverlayController.content {
                return
            }
            currentOverlayController.dismissWithCommitAction()
        }
        
        var stickerPackReference: StickerPackReference?
        for attribute in file.attributes {
            if case let .CustomEmoji(_, _, _, packReference) = attribute {
                stickerPackReference = packReference
                break
            }
        }
        
        if let stickerPackReference = stickerPackReference {
            self.presentEmojiList(references: [stickerPackReference])
            
            /*let _ = (self.context.engine.stickers.loadedStickerPack(reference: stickerPackReference, forceActualized: false)
            |> deliverOnMainQueue).startStandalone(next: { [weak self] stickerPack in
                if let strongSelf = self, case let .result(info, _, _) = stickerPack {
                    strongSelf.present(UndoOverlayController(presentationData: strongSelf.presentationData, content: .sticker(context: strongSelf.context, file: file, loop: true, title: nil, text: strongSelf.presentationData.strings.Stickers_EmojiPackInfoText(info.title).string, undoText: strongSelf.presentationData.strings.Stickers_PremiumPackView, customAction: nil), elevatedLayout: false, action: { [weak self] action in
                        if let strongSelf = self, action == .undo {
                            strongSelf.presentEmojiList(references: [stickerPackReference])
                        }
                        return false
                    }), in: .current)
                }
            })*/
        }
    }
    
    func displayDiceTooltip(dice: TelegramMediaDice) {
        guard let _ = dice.value else {
            return
        }
        self.window?.forEachController({ controller in
            if let controller = controller as? UndoOverlayController {
                controller.dismissWithCommitAction()
            }
        })
        self.forEachController({ controller in
            if let controller = controller as? UndoOverlayController {
                controller.dismissWithCommitAction()
            }
            return true
        })
        
        let value: String?
        let emoji = dice.emoji.strippedEmoji
        switch emoji {
            case "🎲":
                value = self.presentationData.strings.Conversation_Dice_u1F3B2
            case "🎯":
                value = self.presentationData.strings.Conversation_Dice_u1F3AF
            case "🏀":
                value = self.presentationData.strings.Conversation_Dice_u1F3C0
            case "⚽":
                value = self.presentationData.strings.Conversation_Dice_u26BD
            case "🎰":
                value = self.presentationData.strings.Conversation_Dice_u1F3B0
            case "🎳":
                value = self.presentationData.strings.Conversation_Dice_u1F3B3
            default:
                let emojiHex = emoji.unicodeScalars.map({ String(format:"%02x", $0.value) }).joined().uppercased()
                let key = "Conversation.Dice.u\(emojiHex)"
                if let string = self.presentationData.strings.primaryComponent.dict[key] {
                    value = string
                } else if let string = self.presentationData.strings.secondaryComponent?.dict[key] {
                    value = string
                } else {
                    value = nil
                }
        }
        if let value = value {
            self.present(UndoOverlayController(presentationData: self.presentationData, content: .dice(dice: dice, context: self.context, text: value, action: canSendMessagesToChat(self.presentationInterfaceState) ? self.presentationData.strings.Conversation_SendDice : nil), elevatedLayout: false, action: { [weak self] action in
                if let strongSelf = self, canSendMessagesToChat(strongSelf.presentationInterfaceState), action == .undo {
                    strongSelf.sendMessages([.message(text: "", attributes: [], inlineStickers: [:], mediaReference: AnyMediaReference.standalone(media: TelegramMediaDice(emoji: dice.emoji)), threadId: strongSelf.chatLocation.threadId, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])])
                }
                return false
            }), in: .current)
        }
    }
    
    func transformEnqueueMessages(_ messages: [EnqueueMessage], silentPosting: Bool, scheduleTime: Int32? = nil) -> [EnqueueMessage] {
        var defaultReplyMessageSubject: EngineMessageReplySubject?
        switch self.chatLocation {
        case .peer:
            break
        case let .replyThread(replyThreadMessage):
            if let effectiveMessageId = replyThreadMessage.effectiveMessageId {
                defaultReplyMessageSubject = EngineMessageReplySubject(messageId: effectiveMessageId, quote: nil)
            }
        case .feed:
            break
        }
        
        return messages.map { message in
            var message = message
            
            if let defaultReplyMessageSubject = defaultReplyMessageSubject {
                switch message {
                case let .message(text, attributes, inlineStickers, mediaReference, threadId, replyToMessageId, replyToStoryId, localGroupingKey, correlationId, bubbleUpEmojiOrStickersets):
                    if replyToMessageId == nil {
                        message = .message(text: text, attributes: attributes, inlineStickers: inlineStickers, mediaReference: mediaReference, threadId: threadId, replyToMessageId: defaultReplyMessageSubject, replyToStoryId: replyToStoryId, localGroupingKey: localGroupingKey, correlationId: correlationId, bubbleUpEmojiOrStickersets: bubbleUpEmojiOrStickersets)
                    }
                case .forward:
                    break
                }
            }
            
            return message.withUpdatedAttributes { attributes in
                var attributes = attributes
                if silentPosting || scheduleTime != nil {
                    for i in (0 ..< attributes.count).reversed() {
                        if attributes[i] is NotificationInfoMessageAttribute {
                            attributes.remove(at: i)
                        } else if let _ = scheduleTime, attributes[i] is OutgoingScheduleInfoMessageAttribute {
                            attributes.remove(at: i)
                        }
                    }
                    if silentPosting {
                        attributes.append(NotificationInfoMessageAttribute(flags: .muted))
                    }
                    if let scheduleTime = scheduleTime {
                         attributes.append(OutgoingScheduleInfoMessageAttribute(scheduleTime: scheduleTime))
                    }
                }
                if let sendAsPeerId = self.presentationInterfaceState.currentSendAsPeerId {
                    if attributes.first(where: { $0 is SendAsMessageAttribute }) == nil {
                        attributes.append(SendAsMessageAttribute(peerId: sendAsPeerId))
                    }
                }
                return attributes
            }
        }
    }
    
    func sendMessages(_ messages: [EnqueueMessage], media: Bool = false, commit: Bool = false) {
        guard let peerId = self.chatLocation.peerId else {
            return
        }
        
        var isScheduledMessages = false
        if case .scheduledMessages = self.presentationInterfaceState.subject {
            isScheduledMessages = true
        }
        
        if commit || !isScheduledMessages {
            self.commitPurposefulAction()
            
            let _ = (enqueueMessages(account: self.context.account, peerId: peerId, messages: self.transformEnqueueMessages(messages))
            |> deliverOnMainQueue).startStandalone(next: { [weak self] _ in
                if let strongSelf = self, strongSelf.presentationInterfaceState.subject != .scheduledMessages {
                    strongSelf.chatDisplayNode.historyNode.scrollToEndOfHistory()
                }
            })
            
            donateSendMessageIntent(account: self.context.account, sharedContext: self.context.sharedContext, intentContext: .chat, peerIds: [peerId])
            
            self.updateChatPresentationInterfaceState(interactive: true, { $0.updatedShowCommands(false) })
        } else {
            self.presentScheduleTimePicker(style: media ? .media : .default, dismissByTapOutside: false, completion: { [weak self] time in
                if let strongSelf = self {
                    strongSelf.sendMessages(strongSelf.transformEnqueueMessages(messages, silentPosting: false, scheduleTime: time), commit: true)
                }
            })
        }
    }
    
    func enqueueMediaMessages(signals: [Any]?, silentPosting: Bool, scheduleTime: Int32? = nil, getAnimatedTransitionSource: ((String) -> UIView?)? = nil, completion: @escaping () -> Void = {}) {
        self.enqueueMediaMessageDisposable.set((legacyAssetPickerEnqueueMessages(context: self.context, account: self.context.account, signals: signals!)
        |> deliverOnMainQueue).startStrict(next: { [weak self] items in
            if let strongSelf = self {
                var completionImpl: (() -> Void)? = completion

                var usedCorrelationId: Int64?

                var mappedMessages: [EnqueueMessage] = []
                var addedTransitions: [(Int64, [String], () -> Void)] = []
                
                var groupedCorrelationIds: [Int64: Int64] = [:]
                
                var skipAddingTransitions = false
                
                for item in items {
                    var message = item.message
                    if message.groupingKey != nil {
                        if items.count > 10 {
                            skipAddingTransitions = true
                        }
                    } else if items.count > 3 {
                        skipAddingTransitions = true
                    }
                    
                    if let uniqueId = item.uniqueId, !item.isFile && !skipAddingTransitions {
                        let correlationId: Int64
                        var addTransition = scheduleTime == nil
                        if let groupingKey = message.groupingKey {
                            if let existing = groupedCorrelationIds[groupingKey] {
                                correlationId = existing
                                addTransition = false
                            } else {
                                correlationId = Int64.random(in: 0 ..< Int64.max)
                                groupedCorrelationIds[groupingKey] = correlationId
                            }
                        } else {
                            correlationId = Int64.random(in: 0 ..< Int64.max)
                        }
                        message = message.withUpdatedCorrelationId(correlationId)

                        if addTransition {
                            addedTransitions.append((correlationId, [uniqueId], addedTransitions.isEmpty ? completion : {}))
                        } else {
                            if let index = addedTransitions.firstIndex(where: { $0.0 == correlationId }) {
                                var (correlationId, uniqueIds, completion) = addedTransitions[index]
                                uniqueIds.append(uniqueId)
                                addedTransitions[index] = (correlationId, uniqueIds, completion)
                            }
                        }
                        
                        usedCorrelationId = correlationId
                        completionImpl = nil
                    }
                    mappedMessages.append(message)
                }
                        
                if addedTransitions.count > 1 {
                    var transitions: [(Int64, ChatMessageTransitionNodeImpl.Source, () -> Void)] = []
                    for (correlationId, uniqueIds, initiated) in addedTransitions {
                        var source: ChatMessageTransitionNodeImpl.Source?
                        if uniqueIds.count > 1 {
                            source = .groupedMediaInput(ChatMessageTransitionNodeImpl.Source.GroupedMediaInput(extractSnapshots: {
                                return uniqueIds.compactMap({ getAnimatedTransitionSource?($0) })
                            }))
                        } else if let uniqueId = uniqueIds.first {
                            source = .mediaInput(ChatMessageTransitionNodeImpl.Source.MediaInput(extractSnapshot: {
                                return getAnimatedTransitionSource?(uniqueId)
                            }))
                        }
                        if let source = source {
                            transitions.append((correlationId, source, initiated))
                        }
                    }
                    strongSelf.chatDisplayNode.messageTransitionNode.add(grouped: transitions)
                } else if let (correlationId, uniqueIds, initiated) = addedTransitions.first {
                    var source: ChatMessageTransitionNodeImpl.Source?
                    if uniqueIds.count > 1 {
                        source = .groupedMediaInput(ChatMessageTransitionNodeImpl.Source.GroupedMediaInput(extractSnapshots: {
                            return uniqueIds.compactMap({ getAnimatedTransitionSource?($0) })
                        }))
                    } else if let uniqueId = uniqueIds.first {
                        source = .mediaInput(ChatMessageTransitionNodeImpl.Source.MediaInput(extractSnapshot: {
                            return getAnimatedTransitionSource?(uniqueId)
                        }))
                    }
                    if let source = source {
                        strongSelf.chatDisplayNode.messageTransitionNode.add(correlationId: correlationId, source: source, initiated: {
                            initiated()
                        })
                    }
                }
                                                    
                let messages = strongSelf.transformEnqueueMessages(mappedMessages, silentPosting: silentPosting, scheduleTime: scheduleTime)
                let replyMessageSubject = strongSelf.presentationInterfaceState.interfaceState.replyMessageSubject
                strongSelf.chatDisplayNode.setupSendActionOnViewUpdate({
                    if let strongSelf = self {
                        strongSelf.chatDisplayNode.collapseInput()
                        
                        strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: false, {
                            $0.updatedInterfaceState { $0.withUpdatedReplyMessageSubject(nil) }
                        })
                    }
                    completionImpl?()
                }, usedCorrelationId)

                strongSelf.sendMessages(messages.map { $0.withUpdatedReplyToMessageId(replyMessageSubject?.subjectModel) }, media: true)
                
                if let _ = scheduleTime {
                    completion()
                }
            }
        }))
    }
    
    func displayPasteMenu(_ subjects: [MediaPickerScreen.Subject.Media]) {
        let _ = (self.context.sharedContext.accountManager.transaction { transaction -> GeneratedMediaStoreSettings in
            let entry = transaction.getSharedData(ApplicationSpecificSharedDataKeys.generatedMediaStoreSettings)?.get(GeneratedMediaStoreSettings.self)
            return entry ?? GeneratedMediaStoreSettings.defaultSettings
        }
        |> deliverOnMainQueue).startStandalone(next: { [weak self] settings in
            if let strongSelf = self, let peer = strongSelf.presentationInterfaceState.renderedPeer?.peer {
                strongSelf.chatDisplayNode.dismissInput()                
                let controller = mediaPasteboardScreen(
                    context: strongSelf.context,
                    updatedPresentationData: strongSelf.updatedPresentationData,
                    peer: EnginePeer(peer),
                    subjects: subjects,
                    presentMediaPicker: { [weak self] subject, saveEditedPhotos, bannedSendPhotos, bannedSendVideos, present in
                        if let strongSelf = self {
                            strongSelf.presentMediaPicker(subject: subject, saveEditedPhotos: saveEditedPhotos, bannedSendPhotos: bannedSendPhotos, bannedSendVideos: bannedSendVideos, present: present, updateMediaPickerContext: { _ in }, completion: { [weak self] signals, silentPosting, scheduleTime, getAnimatedTransitionSource, completion in
                                self?.enqueueMediaMessages(signals: signals, silentPosting: silentPosting, scheduleTime: scheduleTime, getAnimatedTransitionSource: getAnimatedTransitionSource, completion: completion)
                            })
                        }
                    },
                    getSourceRect: nil
                )
                controller.navigationPresentation = .flatModal
                strongSelf.push(controller)
            }
        })
    }
    
    func enqueueGifData(_ data: Data) {
        self.enqueueMediaMessageDisposable.set((legacyEnqueueGifMessage(account: self.context.account, data: data) |> deliverOnMainQueue).startStrict(next: { [weak self] message in
            if let strongSelf = self {
                let replyMessageSubject = strongSelf.presentationInterfaceState.interfaceState.replyMessageSubject
                strongSelf.chatDisplayNode.setupSendActionOnViewUpdate({
                    if let strongSelf = self {
                        strongSelf.chatDisplayNode.collapseInput()
                        
                        strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: false, {
                            $0.updatedInterfaceState { $0.withUpdatedReplyMessageSubject(nil) }
                        })
                    }
                }, nil)
                strongSelf.sendMessages([message].map { $0.withUpdatedReplyToMessageId(replyMessageSubject?.subjectModel) })
            }
        }))
    }
    
    func enqueueVideoData(_ data: Data) {
        self.enqueueMediaMessageDisposable.set((legacyEnqueueGifMessage(account: self.context.account, data: data) |> deliverOnMainQueue).startStrict(next: { [weak self] message in
            if let strongSelf = self {
                let replyMessageSubject = strongSelf.presentationInterfaceState.interfaceState.replyMessageSubject
                strongSelf.chatDisplayNode.setupSendActionOnViewUpdate({
                    if let strongSelf = self {
                        strongSelf.chatDisplayNode.collapseInput()
                        
                        strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: false, {
                            $0.updatedInterfaceState { $0.withUpdatedReplyMessageSubject(nil) }
                        })
                    }
                }, nil)
                strongSelf.sendMessages([message].map { $0.withUpdatedReplyToMessageId(replyMessageSubject?.subjectModel) })
            }
        }))
    }
    
    func enqueueStickerImage(_ image: UIImage, isMemoji: Bool) {
        let size = image.size.aspectFitted(CGSize(width: 512.0, height: 512.0))
        self.enqueueMediaMessageDisposable.set((convertToWebP(image: image, targetSize: size, targetBoundingSize: size, quality: 0.9) |> deliverOnMainQueue).startStrict(next: { [weak self] data in
            if let strongSelf = self, !data.isEmpty {
                let resource = LocalFileMediaResource(fileId: Int64.random(in: Int64.min ... Int64.max))
                strongSelf.context.account.postbox.mediaBox.storeResourceData(resource.id, data: data)
                
                var fileAttributes: [TelegramMediaFileAttribute] = []
                fileAttributes.append(.FileName(fileName: "sticker.webp"))
                fileAttributes.append(.Sticker(displayText: "", packReference: nil, maskData: nil))
                fileAttributes.append(.ImageSize(size: PixelDimensions(size)))
                
                let media = TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.LocalFile, id: Int64.random(in: Int64.min ... Int64.max)), partialReference: nil, resource: resource, previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil, mimeType: "image/webp", size: Int64(data.count), attributes: fileAttributes)
                let message = EnqueueMessage.message(text: "", attributes: [], inlineStickers: [:], mediaReference: .standalone(media: media), threadId: strongSelf.chatLocation.threadId, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])
                
                let replyMessageSubject = strongSelf.presentationInterfaceState.interfaceState.replyMessageSubject
                strongSelf.chatDisplayNode.setupSendActionOnViewUpdate({
                    if let strongSelf = self {
                        strongSelf.chatDisplayNode.collapseInput()
                        
                        strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: false, {
                            $0.updatedInterfaceState { $0.withUpdatedReplyMessageSubject(nil) }
                        })
                    }
                }, nil)
                strongSelf.sendMessages([message].map { $0.withUpdatedReplyToMessageId(replyMessageSubject?.subjectModel) })
            }
        }))
    }
    
    func enqueueChatContextResult(_ results: ChatContextResultCollection, _ result: ChatContextResult, hideVia: Bool = false, closeMediaInput: Bool = false, silentPosting: Bool = false, resetTextInputState: Bool = true) {
        if !canSendMessagesToChat(self.presentationInterfaceState) {
            return
        }
        
        guard let peerId = self.chatLocation.peerId else {
            return
        }
        
        var isScheduledMessages = false
        if case .scheduledMessages = self.presentationInterfaceState.subject {
            isScheduledMessages = true
        }

        let sendMessage: (Int32?) -> Void = { [weak self] scheduleTime in
            guard let self else {
                return
            }
            let replyMessageSubject = self.presentationInterfaceState.interfaceState.replyMessageSubject
            if self.context.engine.messages.enqueueOutgoingMessageWithChatContextResult(to: peerId, threadId: self.chatLocation.threadId, botId: results.botId, result: result, replyToMessageId: replyMessageSubject?.subjectModel, hideVia: hideVia, silentPosting: silentPosting, scheduleTime: scheduleTime) {
                self.chatDisplayNode.setupSendActionOnViewUpdate({ [weak self] in
                    if let strongSelf = self {
                        strongSelf.chatDisplayNode.collapseInput()
                        
                        strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, { state in
                            var state = state
                            if resetTextInputState {
                                state = state.updatedInterfaceState { interfaceState in
                                    var interfaceState = interfaceState
                                    interfaceState = interfaceState.withUpdatedReplyMessageSubject(nil)
                                    interfaceState = interfaceState.withUpdatedComposeInputState(ChatTextInputState(inputText: NSAttributedString(string: "")))
                                    interfaceState = interfaceState.withUpdatedComposeDisableUrlPreviews([])
                                    return interfaceState
                                }
                            }
                            state = state.updatedInputMode { current in
                                if case let .media(mode, maybeExpanded, focused) = current, maybeExpanded != nil  {
                                    return .media(mode: mode, expanded: nil, focused: focused)
                                }
                                return current
                            }
                            return state
                        })
                    }
                }, nil)
            }
        }
        
        if isScheduledMessages {
            self.presentScheduleTimePicker(style: .default, dismissByTapOutside: false, completion: { time in
                sendMessage(time)
            })
        } else {
            sendMessage(nil)
        }
    }
    
    func firstLoadedMessageToListen() -> Message? {
        var messageToListen: Message?
        self.chatDisplayNode.historyNode.forEachMessageInCurrentHistoryView { message in
            if message.flags.contains(.Incoming) && message.tags.contains(.voiceOrInstantVideo) {
                for attribute in message.attributes {
                    if let attribute = attribute as? ConsumableContentMessageAttribute, !attribute.consumed {
                        messageToListen = message
                        return false
                    }
                }
            }
            return true
        }
        return messageToListen
    }
    
    var raiseToListenActivateRecordingTimer: SwiftSignalKit.Timer?
    
    func activateRaiseGesture() {
        self.raiseToListenActivateRecordingTimer?.invalidate()
        self.raiseToListenActivateRecordingTimer = nil
        if let messageToListen = self.firstLoadedMessageToListen() {
            let _ = self.controllerInteraction?.openMessage(messageToListen, OpenMessageParams(mode: .default))
        } else {
            let timeout = (self.voicePlaylistDidEndTimestamp + 1.0) - CACurrentMediaTime()
            self.raiseToListenActivateRecordingTimer = SwiftSignalKit.Timer(timeout: max(0.0, timeout), repeat: false, completion: { [weak self] in
                self?.requestAudioRecorder(beginWithTone: true)
            }, queue: .mainQueue())
            self.raiseToListenActivateRecordingTimer?.start()
        }
    }
    
    func deactivateRaiseGesture() {
        self.raiseToListenActivateRecordingTimer?.invalidate()
        self.raiseToListenActivateRecordingTimer = nil
        self.dismissMediaRecorder(.pause)
    }
    
    func requestAudioRecorder(beginWithTone: Bool) {
        if self.audioRecorderValue == nil {
            if self.recorderFeedback == nil {
                self.recorderFeedback = HapticFeedback()
                self.recorderFeedback?.prepareImpact(.light)
            }
            
            self.audioRecorder.set(self.context.sharedContext.mediaManager.audioRecorder(beginWithTone: beginWithTone, applicationBindings: self.context.sharedContext.applicationBindings, beganWithTone: { _ in
            }))
        }
    }
    
    func requestVideoRecorder() {
        guard let peerId = self.chatLocation.peerId else {
            return
        }
        
        if self.videoRecorderValue == nil {
            if let currentInputPanelFrame = self.chatDisplayNode.currentInputPanelFrame() {
                if self.recorderFeedback == nil {
                    self.recorderFeedback = HapticFeedback()
                    self.recorderFeedback?.prepareImpact(.light)
                }
                
                var isScheduledMessages = false
                if case .scheduledMessages = self.presentationInterfaceState.subject {
                    isScheduledMessages = true
                }
                
                var isBot = false
                if let user = self.presentationInterfaceState.renderedPeer?.peer as? TelegramUser, user.botInfo != nil {
                    isBot = true
                }
                
                let controller = VideoMessageCameraScreen(
                    context: self.context,
                    updatedPresentationData: self.updatedPresentationData,
                    allowLiveUpload: peerId.namespace != Namespaces.Peer.SecretChat,
                    viewOnceAvailable: !isScheduledMessages && peerId.namespace == Namespaces.Peer.CloudUser && peerId != self.context.account.peerId && !isBot,
                    inputPanelFrame: currentInputPanelFrame,
                    chatNode: self.chatDisplayNode.historyNode,
                    completion: { [weak self] message, silentPosting, scheduleTime in
                        guard let self, let videoController = self.videoRecorderValue else {
                            return
                        }
                        
                        guard var message else {
                            self.recorderFeedback?.error()
                            self.recorderFeedback = nil
                            self.videoRecorder.set(.single(nil))
                            return
                        }
                        
                        let replyMessageSubject = self.presentationInterfaceState.interfaceState.replyMessageSubject
                        let correlationId = Int64.random(in: 0 ..< Int64.max)
                        message = message
                            .withUpdatedReplyToMessageId(replyMessageSubject?.subjectModel)
                            .withUpdatedCorrelationId(correlationId)
                        
                        var usedCorrelationId = false
                        if scheduleTime == nil, self.chatDisplayNode.shouldAnimateMessageTransition, let extractedView = videoController.extractVideoSnapshot() {
                            usedCorrelationId = true
                            self.chatDisplayNode.messageTransitionNode.add(correlationId: correlationId, source:  .videoMessage(ChatMessageTransitionNodeImpl.Source.VideoMessage(view: extractedView)), initiated: { [weak videoController, weak self] in
                                videoController?.hideVideoSnapshot()
                                guard let self else {
                                    return
                                }
                                self.videoRecorder.set(.single(nil))
                            })
                        } else {
                            self.videoRecorder.set(.single(nil))
                        }
                        
                        self.chatDisplayNode.setupSendActionOnViewUpdate({ [weak self] in
                            if let self {
                                self.chatDisplayNode.collapseInput()
                                
                                self.updateChatPresentationInterfaceState(animated: true, interactive: false, {
                                    $0.updatedInterfaceState { $0.withUpdatedReplyMessageSubject(nil).withUpdatedMediaDraftState(nil) }
                                })
                            }
                        }, usedCorrelationId ? correlationId : nil)
                        
                        let messages = [message]
                        let transformedMessages: [EnqueueMessage]
                        if let silentPosting {
                            transformedMessages = self.transformEnqueueMessages(messages, silentPosting: silentPosting)
                        } else if let scheduleTime {
                            transformedMessages = self.transformEnqueueMessages(messages, silentPosting: false, scheduleTime: scheduleTime)
                        } else {
                            transformedMessages = self.transformEnqueueMessages(messages)
                        }
                        
                        self.sendMessages(transformedMessages)
                    }
                )
                controller.onResume = { [weak self] in
                    guard let self else {
                        return
                    }
                    self.resumeMediaRecorder()
                }
                self.videoRecorder.set(.single(controller))
            }
        }
    }
    
    func dismissMediaRecorder(_ action: ChatFinishMediaRecordingAction) {
        var updatedAction = action
        var isScheduledMessages = false
        if case .scheduledMessages = self.presentationInterfaceState.subject {
            isScheduledMessages = true
        }
        
        if let _ = self.presentationInterfaceState.slowmodeState, !isScheduledMessages {
            updatedAction = .preview
        }
        
        if let audioRecorderValue = self.audioRecorderValue {
            switch action {
            case .pause:
                audioRecorderValue.pause()
            default:
                audioRecorderValue.stop()
            }
            
            switch updatedAction {
            case .dismiss:
                self.recorderDataDisposable.set(nil)
                self.chatDisplayNode.updateRecordedMediaDeleted(true)
                self.audioRecorder.set(.single(nil))
            case .preview, .pause:
                if case .preview = updatedAction {
                    self.audioRecorder.set(.single(nil))
                }
                self.updateChatPresentationInterfaceState(animated: true, interactive: true, {
                    $0.updatedInputTextPanelState { panelState in
                        return panelState.withUpdatedMediaRecordingState(.waitingForPreview)
                    }
                })
                self.recorderDataDisposable.set((audioRecorderValue.takenRecordedData()
                |> deliverOnMainQueue).startStrict(next: { [weak self] data in
                    if let strongSelf = self, let data = data {
                        if data.duration < 0.5 {
                            strongSelf.recorderFeedback?.error()
                            strongSelf.recorderFeedback = nil
                            strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, {
                                $0.updatedInputTextPanelState { panelState in
                                    return panelState.withUpdatedMediaRecordingState(nil)
                                }
                            })
                            strongSelf.recorderDataDisposable.set(nil)
                        } else if let waveform = data.waveform {
                            let resource = LocalFileMediaResource(fileId: Int64.random(in: Int64.min ... Int64.max), size: Int64(data.compressedData.count))
                            
                            strongSelf.context.account.postbox.mediaBox.storeResourceData(resource.id, data: data.compressedData)
                            
                            strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, {
                                $0.updatedInterfaceState { $0.withUpdatedMediaDraftState(.audio(ChatInterfaceMediaDraftState.Audio(resource: resource, fileSize: Int32(data.compressedData.count), duration: Int32(data.duration), waveform: AudioWaveform(bitstream: waveform, bitsPerSample: 5)))) }.updatedInputTextPanelState { panelState in
                                    return panelState.withUpdatedMediaRecordingState(nil)
                                }
                            })
                            strongSelf.recorderFeedback = nil
                            strongSelf.updateDownButtonVisibility()
                            strongSelf.recorderDataDisposable.set(nil)
                        }
                    }
                }))
            case let .send(viewOnce):
                self.chatDisplayNode.updateRecordedMediaDeleted(false)
                self.recorderDataDisposable.set((audioRecorderValue.takenRecordedData()
                |> deliverOnMainQueue).startStrict(next: { [weak self] data in
                    if let strongSelf = self, let data = data {
                        if data.duration < 0.5 {
                            strongSelf.recorderFeedback?.error()
                            strongSelf.recorderFeedback = nil
                            strongSelf.audioRecorder.set(.single(nil))
                        } else {
                            let randomId = Int64.random(in: Int64.min ... Int64.max)
                            
                            let resource = LocalFileMediaResource(fileId: randomId)
                            strongSelf.context.account.postbox.mediaBox.storeResourceData(resource.id, data: data.compressedData)
                            
                            let waveformBuffer: Data? = data.waveform
                            
                            let correlationId = Int64.random(in: 0 ..< Int64.max)
                            var usedCorrelationId = false
                            
                            if strongSelf.chatDisplayNode.shouldAnimateMessageTransition, let textInputPanelNode = strongSelf.chatDisplayNode.textInputPanelNode, let micButton = textInputPanelNode.micButton {
                                usedCorrelationId = true
                                strongSelf.chatDisplayNode.messageTransitionNode.add(correlationId: correlationId, source: .audioMicInput(ChatMessageTransitionNodeImpl.Source.AudioMicInput(micButton: micButton)), initiated: {
                                    guard let strongSelf = self else {
                                        return
                                    }
                                    strongSelf.audioRecorder.set(.single(nil))
                                })
                            } else {
                                strongSelf.audioRecorder.set(.single(nil))
                            }
                            
                            strongSelf.chatDisplayNode.setupSendActionOnViewUpdate({
                                if let strongSelf = self {
                                    strongSelf.chatDisplayNode.collapseInput()
                                    
                                    strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: false, {
                                        $0.updatedInterfaceState { $0.withUpdatedReplyMessageSubject(nil) }
                                    })
                                }
                            }, usedCorrelationId ? correlationId : nil)
                            
                            var attributes: [MessageAttribute] = []
                            if viewOnce {
                                attributes.append(AutoremoveTimeoutMessageAttribute(timeout: viewOnceTimeout, countdownBeginTime: nil))
                            }
                            
                            strongSelf.sendMessages([.message(text: "", attributes: attributes, inlineStickers: [:], mediaReference: .standalone(media: TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.LocalFile, id: randomId), partialReference: nil, resource: resource, previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil, mimeType: "audio/ogg", size: Int64(data.compressedData.count), attributes: [.Audio(isVoice: true, duration: Int(data.duration), title: nil, performer: nil, waveform: waveformBuffer)])), threadId: strongSelf.chatLocation.threadId, replyToMessageId: strongSelf.presentationInterfaceState.interfaceState.replyMessageSubject?.subjectModel, replyToStoryId: nil, localGroupingKey: nil, correlationId: correlationId, bubbleUpEmojiOrStickersets: [])])
                            
                            strongSelf.recorderFeedback?.tap()
                            strongSelf.recorderFeedback = nil
                            strongSelf.recorderDataDisposable.set(nil)
                        }
                    }
                }))
            }
        } else if let videoRecorderValue = self.videoRecorderValue {
            if case .send = updatedAction {
                self.chatDisplayNode.updateRecordedMediaDeleted(false)
                videoRecorderValue.sendVideoRecording()
                self.recorderDataDisposable.set(nil)
            } else {
                if case .dismiss = updatedAction {
                    self.chatDisplayNode.updateRecordedMediaDeleted(true)
                    self.recorderDataDisposable.set(nil)
                }
                
                switch updatedAction {
                case .preview, .pause:
                    if videoRecorderValue.stopVideoRecording() {
                        self.recorderDataDisposable.set((videoRecorderValue.takenRecordedData()
                        |> deliverOnMainQueue).startStrict(next: { [weak self] data in
                            if let strongSelf = self, let data = data {
                                if data.duration < 1.0 {
                                    strongSelf.recorderFeedback?.error()
                                    strongSelf.recorderFeedback = nil
                                    strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, {
                                        $0.updatedInputTextPanelState { panelState in
                                            return panelState.withUpdatedMediaRecordingState(nil)
                                        }
                                    })
                                    strongSelf.recorderDataDisposable.set(nil)
                                    strongSelf.videoRecorder.set(.single(nil))
                                } else {
                                    strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, {
                                        $0.updatedInterfaceState {
                                            $0.withUpdatedMediaDraftState(.video(
                                                ChatInterfaceMediaDraftState.Video(
                                                    duration: Int32(data.duration),
                                                    frames: data.frames,
                                                    framesUpdateTimestamp: data.framesUpdateTimestamp,
                                                    trimRange: data.trimRange
//                                                    control: ChatRecordedMediaPreview.Video.Control(
//                                                        updateTrimRange: { [weak self] start, end, updatedEnd, apply in
//                                                            if let self, let videoRecorderValue = self.videoRecorderValue {
//                                                                videoRecorderValue.updateTrimRange(start: start, end: end, updatedEnd: updatedEnd, apply: apply)
//                                                            }
//                                                        }
//                                                    )
                                                )
                                            ))
                                        }.updatedInputTextPanelState { panelState in
                                            return panelState.withUpdatedMediaRecordingState(nil)
                                        }
                                    })
                                    strongSelf.recorderFeedback = nil
                                    strongSelf.updateDownButtonVisibility()
                                }
                            }
                        }))
                    }
                default:
                    self.recorderDataDisposable.set(nil)
                    self.videoRecorder.set(.single(nil))
                }
            }
        }
    }
    
    func stopMediaRecorder(pause: Bool = false) {
        if let audioRecorderValue = self.audioRecorderValue {
            if let _ = self.presentationInterfaceState.inputTextPanelState.mediaRecordingState {
                self.dismissMediaRecorder(pause ? .pause : .preview)
            } else {
                audioRecorderValue.stop()
                self.audioRecorder.set(.single(nil))
            }
        } else if let _ = self.videoRecorderValue {
            if let _ = self.presentationInterfaceState.inputTextPanelState.mediaRecordingState {
                self.dismissMediaRecorder(pause ? .pause : .preview)
            } else {
                self.videoRecorder.set(.single(nil))
            }
        }
    }
    
    func resumeMediaRecorder() {
        self.context.sharedContext.mediaManager.playlistControl(.playback(.pause), type: nil)
        
        if let audioRecorderValue = self.audioRecorderValue {
            audioRecorderValue.resume()
            
            self.updateChatPresentationInterfaceState(animated: true, interactive: true, {
                $0.updatedInputTextPanelState { panelState in
                    return panelState.withUpdatedMediaRecordingState(.audio(recorder: audioRecorderValue, isLocked: true))
                }.updatedInterfaceState { $0.withUpdatedMediaDraftState(nil) }
            })
        } else if let videoRecorderValue = self.videoRecorderValue {
            self.updateChatPresentationInterfaceState(animated: true, interactive: true, {
                $0.updatedInputTextPanelState { panelState in
                    let recordingStatus = videoRecorderValue.recordingStatus
                    return panelState.withUpdatedMediaRecordingState(.video(status: .recording(InstantVideoControllerRecordingStatus(micLevel: recordingStatus.micLevel, duration: recordingStatus.duration)), isLocked: true))
                }.updatedInterfaceState { $0.withUpdatedMediaDraftState(nil) }
            })
        }
    }
    
    func lockMediaRecorder() {
        if self.presentationInterfaceState.inputTextPanelState.mediaRecordingState != nil {
            self.updateChatPresentationInterfaceState(animated: true, interactive: true, {
                return $0.updatedInputTextPanelState { panelState in
                    return panelState.withUpdatedMediaRecordingState(panelState.mediaRecordingState?.withLocked(true))
                }
            })
        }
        
        self.videoRecorderValue?.lockVideoRecording()
    }
    
    func deleteMediaRecording() {
        if let _ = self.audioRecorderValue {
            self.audioRecorder.set(.single(nil))
        } else if let _ = self.videoRecorderValue {
            self.videoRecorder.set(.single(nil))
        }
        
        self.recorderDataDisposable.set(nil)
        self.chatDisplayNode.updateRecordedMediaDeleted(true)
        self.updateChatPresentationInterfaceState(animated: true, interactive: true, {
            $0.updatedInterfaceState { $0.withUpdatedMediaDraftState(nil) }
        })
        self.updateDownButtonVisibility()
    }
    
    func sendMediaRecording(silentPosting: Bool? = nil, scheduleTime: Int32? = nil, viewOnce: Bool = false) {
        self.chatDisplayNode.updateRecordedMediaDeleted(false)
        
        guard let recordedMediaPreview = self.presentationInterfaceState.interfaceState.mediaDraftState else {
            return
        }
        
        switch recordedMediaPreview {
        case let .audio(audio):
            self.audioRecorder.set(.single(nil))
            
            var isScheduledMessages = false
            if case .scheduledMessages = self.presentationInterfaceState.subject {
                isScheduledMessages = true
            }
            
            if let _ = self.presentationInterfaceState.slowmodeState, !isScheduledMessages {
                if let rect = self.chatDisplayNode.frameForInputActionButton() {
                    self.interfaceInteraction?.displaySlowmodeTooltip(self.chatDisplayNode.view, rect)
                }
                return
            }
            
            let waveformBuffer = audio.waveform.makeBitstream()
            
            self.chatDisplayNode.setupSendActionOnViewUpdate({ [weak self] in
                if let strongSelf = self {
                    strongSelf.chatDisplayNode.collapseInput()
                    
                    strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: false, {
                        $0.updatedInterfaceState { $0.withUpdatedReplyMessageSubject(nil).withUpdatedMediaDraftState(nil) }
                    })

                    strongSelf.updateDownButtonVisibility()
                }
            }, nil)
            
            var attributes: [MessageAttribute] = []
            if viewOnce {
                attributes.append(AutoremoveTimeoutMessageAttribute(timeout: viewOnceTimeout, countdownBeginTime: nil))
            }
            
            let messages: [EnqueueMessage] = [.message(text: "", attributes: attributes, inlineStickers: [:], mediaReference: .standalone(media: TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.LocalFile, id: Int64.random(in: Int64.min ... Int64.max)), partialReference: nil, resource: audio.resource, previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil, mimeType: "audio/ogg", size: Int64(audio.fileSize), attributes: [.Audio(isVoice: true, duration: Int(audio.duration), title: nil, performer: nil, waveform: waveformBuffer)])), threadId: self.chatLocation.threadId, replyToMessageId: self.presentationInterfaceState.interfaceState.replyMessageSubject?.subjectModel, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])]
            
            let transformedMessages: [EnqueueMessage]
            if let silentPosting = silentPosting {
                transformedMessages = self.transformEnqueueMessages(messages, silentPosting: silentPosting)
            } else if let scheduleTime = scheduleTime {
                transformedMessages = self.transformEnqueueMessages(messages, silentPosting: false, scheduleTime: scheduleTime)
            } else {
                transformedMessages = self.transformEnqueueMessages(messages)
            }
            
            guard let peerId = self.chatLocation.peerId else {
                return
            }
            
            let _ = (enqueueMessages(account: self.context.account, peerId: peerId, messages: transformedMessages)
            |> deliverOnMainQueue).startStandalone(next: { [weak self] _ in
                if let strongSelf = self, strongSelf.presentationInterfaceState.subject != .scheduledMessages {
                    strongSelf.chatDisplayNode.historyNode.scrollToEndOfHistory()
                }
            })
            
            donateSendMessageIntent(account: self.context.account, sharedContext: self.context.sharedContext, intentContext: .chat, peerIds: [peerId])
        case .video:
            self.videoRecorderValue?.sendVideoRecording(silentPosting: silentPosting, scheduleTime: scheduleTime)
        }
    }
    
    func updateDownButtonVisibility() {
        if let search = self.presentationInterfaceState.search, let results = search.resultsState {
            let resultCount = results.messageIndices.count
            var resultIndex: Int?
            if let currentId = results.currentId, let index = results.messageIndices.firstIndex(where: { $0.id == currentId }) {
                resultIndex = index
            } else {
                resultIndex = nil
            }
            
            if let resultIndex {
                self.chatDisplayNode.navigateButtons.directionButtonState = ChatHistoryNavigationButtons.DirectionState(
                    up: ChatHistoryNavigationButtons.ButtonState(isEnabled: resultIndex != 0),
                    down: ChatHistoryNavigationButtons.ButtonState(isEnabled: resultIndex != resultCount - 1)
                )
            } else {
                self.chatDisplayNode.navigateButtons.directionButtonState = ChatHistoryNavigationButtons.DirectionState(
                    up: ChatHistoryNavigationButtons.ButtonState(isEnabled: false),
                    down: ChatHistoryNavigationButtons.ButtonState(isEnabled: false)
                )
            }
        } else {
            let recordingMediaMessage = self.audioRecorderValue != nil || self.videoRecorderValue != nil || self.presentationInterfaceState.interfaceState.mediaDraftState != nil
            
            self.chatDisplayNode.navigateButtons.directionButtonState = ChatHistoryNavigationButtons.DirectionState(
                up: nil,
                down: (self.shouldDisplayDownButton && !recordingMediaMessage) ? ChatHistoryNavigationButtons.ButtonState(isEnabled: true) : nil
            )
        }
    }
    
    func updateTextInputState(_ textInputState: ChatTextInputState) {
        self.updateChatPresentationInterfaceState(interactive: false, { state in
            state.updatedInterfaceState({ state in
                state.withUpdatedComposeInputState(textInputState)
            })
        })
    }
    
    public func navigateToMessage(messageLocation: NavigateToMessageLocation, animated: Bool, forceInCurrentChat: Bool = false, dropStack: Bool = false, completion: (() -> Void)? = nil, customPresentProgress: ((ViewController, Any?) -> Void)? = nil) {
        let scrollPosition: ListViewScrollPosition
        if case .upperBound = messageLocation {
            scrollPosition = .top(0.0)
        } else {
            scrollPosition = .center(.bottom)
        }
        self.navigateToMessage(from: nil, to: messageLocation, scrollPosition: scrollPosition, rememberInStack: false, forceInCurrentChat: forceInCurrentChat, dropStack: dropStack, animated: animated, completion: completion, customPresentProgress: customPresentProgress)
    }
    
    func openPeer(peer: EnginePeer?, navigation: ChatControllerInteractionNavigateToPeer, fromMessage: MessageReference?, fromReactionMessageId: MessageId? = nil, expandAvatar: Bool = false, peerTypes: ReplyMarkupButtonAction.PeerTypes? = nil) {
        let _ = self.presentVoiceMessageDiscardAlert(action: {
            if case let .peer(currentPeerId) = self.chatLocation, peer?.id == currentPeerId {
                switch navigation {
                    case let .info(params):
                        var recommendedChannels = false
                        if let params, params.switchToRecommendedChannels {
                            recommendedChannels = true
                        }
                        self.navigationButtonAction(.openChatInfo(expandAvatar: expandAvatar, recommendedChannels: recommendedChannels))
                    case let .chat(textInputState, _, _):
                        if let textInputState = textInputState {
                            self.updateChatPresentationInterfaceState(animated: true, interactive: true, {
                                return ($0.updatedInterfaceState {
                                    return $0.withUpdatedComposeInputState(textInputState)
                                }).updatedInputMode({ _ in
                                    return .text
                                })
                            })
                        } else {
                            self.playShakeAnimation()
                        }
                    case let .withBotStartPayload(botStart):
                        self.updateChatPresentationInterfaceState(animated: true, interactive: true, {
                            $0.updatedBotStartPayload(botStart.payload)
                        })
                    case .withAttachBot:
                        self.presentAttachmentMenu(subject: .default)
                    default:
                        break
                }
            } else {
                if let peer = peer {
                    do {
                        var chatPeerId: PeerId?
                        if let peer = self.presentationInterfaceState.renderedPeer?.chatMainPeer as? TelegramGroup {
                            chatPeerId = peer.id
                        } else if let peer = self.presentationInterfaceState.renderedPeer?.chatMainPeer as? TelegramChannel, case .group = peer.info, case .member = peer.participationStatus {
                            chatPeerId = peer.id
                        }
                        
                        switch navigation {
                            case .info, .default:
                                let peerSignal: Signal<Peer?, NoError>
                                if let messageId = fromMessage?.id {
                                    peerSignal = loadedPeerFromMessage(account: self.context.account, peerId: peer.id, messageId: messageId)
                                } else {
                                    peerSignal = self.context.account.postbox.loadedPeerWithId(peer.id) |> map(Optional.init)
                                }
                                self.navigationActionDisposable.set((peerSignal |> take(1) |> deliverOnMainQueue).startStrict(next: { [weak self] peer in
                                    if let strongSelf = self, let peer = peer {
                                        var mode: PeerInfoControllerMode = .generic
                                        if let _ = fromMessage, let chatPeerId = chatPeerId {
                                            mode = .group(chatPeerId)
                                        }
                                        if let fromReactionMessageId = fromReactionMessageId {
                                            mode = .reaction(fromReactionMessageId)
                                        }
                                        if case let .info(params) = navigation, let params, params.switchToRecommendedChannels {
                                            mode = .recommendedChannels
                                        }
                                        var expandAvatar = expandAvatar
                                        if peer.smallProfileImage == nil {
                                            expandAvatar = false
                                        }
                                        if let validLayout = strongSelf.validLayout, validLayout.deviceMetrics.type == .tablet {
                                            expandAvatar = false
                                        }
                                        if let infoController = strongSelf.context.sharedContext.makePeerInfoController(context: strongSelf.context, updatedPresentationData: strongSelf.updatedPresentationData, peer: peer, mode: mode, avatarInitiallyExpanded: expandAvatar, fromChat: false, requestsContext: nil) {
                                            strongSelf.effectiveNavigationController?.pushViewController(infoController)
                                        }
                                    }
                                }))
                            case let .chat(textInputState, subject, peekData):
                                if let textInputState = textInputState {
                                    let _ = (ChatInterfaceState.update(engine: self.context.engine, peerId: peer.id, threadId: nil, { currentState in
                                        return currentState.withUpdatedComposeInputState(textInputState)
                                    })
                                    |> deliverOnMainQueue).startStandalone(completed: { [weak self] in
                                        if let strongSelf = self, let navigationController = strongSelf.effectiveNavigationController {
                                            strongSelf.context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: strongSelf.context, chatLocation: .peer(peer), subject: subject, updateTextInputState: textInputState, peekData: peekData))
                                        }
                                    })
                                } else {
                                    if case let .channel(channel) = peer, channel.flags.contains(.isForum) {
                                        self.effectiveNavigationController?.pushViewController(ChatListControllerImpl(context: self.context, location: .forum(peerId: channel.id), controlsHistoryPreload: false, enableDebugActions: false))
                                    } else {
                                        self.effectiveNavigationController?.pushViewController(ChatControllerImpl(context: self.context, chatLocation: .peer(id: peer.id), subject: subject))
                                    }
                                }
                            case let .withBotStartPayload(botStart):
                                self.effectiveNavigationController?.pushViewController(ChatControllerImpl(context: self.context, chatLocation: .peer(id: peer.id), botStart: botStart))
                            case let .withAttachBot(attachBotStart):
                                if let navigationController = self.effectiveNavigationController {
                                    self.context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: self.context, chatLocation: .peer(peer), attachBotStart: attachBotStart))
                                }
                            case let .withBotApp(botAppStart):
                                if let navigationController = self.effectiveNavigationController {
                                    self.context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: self.context, chatLocation: .peer(peer), botAppStart: botAppStart))
                                }
                        }
                    }
                } else {
                    switch navigation {
                        case .info:
                            break
                        case let .chat(textInputState, _, _):
                            if let textInputState = textInputState {
                                let controller = self.context.sharedContext.makePeerSelectionController(PeerSelectionControllerParams(context: self.context, updatedPresentationData: self.updatedPresentationData, requestPeerType: peerTypes.flatMap { $0.requestPeerTypes }, selectForumThreads: true))
                                controller.peerSelected = { [weak self, weak controller] peer, threadId in
                                    let peerId = peer.id
                                    
                                    if let strongSelf = self, let strongController = controller {
                                        if case let .peer(currentPeerId) = strongSelf.chatLocation, peerId == currentPeerId {
                                            strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, {
                                                return ($0.updatedInterfaceState {
                                                    return $0.withUpdatedComposeInputState(textInputState)
                                                }).updatedInputMode({ _ in
                                                    return .text
                                                })
                                            })
                                            strongController.dismiss()
                                        } else {
                                            let _ = (ChatInterfaceState.update(engine: strongSelf.context.engine, peerId: peerId, threadId: threadId, { currentState in
                                                return currentState.withUpdatedComposeInputState(textInputState)
                                            })
                                            |> deliverOnMainQueue).startStandalone(completed: {
                                                if let strongSelf = self {
                                                    strongSelf.updateChatPresentationInterfaceState(animated: false, interactive: true, { $0.updatedInterfaceState({ $0.withoutSelectionState() }) })
                                                                                                        
                                                    if let navigationController = strongSelf.effectiveNavigationController {
                                                        let chatController = ChatControllerImpl(context: strongSelf.context, chatLocation: .peer(id: peerId))
                                                        var viewControllers = navigationController.viewControllers
                                                        viewControllers.insert(chatController, at: viewControllers.count - 1)
                                                        navigationController.setViewControllers(viewControllers, animated: false)
                                                        
                                                        strongSelf.controllerNavigationDisposable.set((chatController.ready.get()
                                                        |> filter { $0 }
                                                        |> take(1)
                                                        |> deliverOnMainQueue).startStrict(next: { _ in
                                                            if let strongController = controller {
                                                                strongController.dismiss()
                                                            }
                                                        }))
                                                    }
                                                }
                                            })
                                        }
                                    }
                                }
                                self.chatDisplayNode.dismissInput()
                                self.effectiveNavigationController?.pushViewController(controller)
                            }
                        default:
                            break
                    }
                }
            }
        })
    }
    
    func openStories(peerId: EnginePeer.Id, avatarHeaderNode: ChatMessageAvatarHeaderNodeImpl?, avatarNode: AvatarNode?) {
        if let avatarNode = avatarHeaderNode?.avatarNode ?? avatarNode {
            StoryContainerScreen.openPeerStories(context: self.context, peerId: peerId, parentController: self, avatarNode: avatarNode)
        }
    }
    
    func openPeerMention(_ name: String, navigation: ChatControllerInteractionNavigateToPeer = .default, sourceMessageId: MessageId? = nil, progress: Promise<Bool>? = nil) {
        let _ = self.presentVoiceMessageDiscardAlert(action: {
            let disposable: MetaDisposable
            if let resolvePeerByNameDisposable = self.resolvePeerByNameDisposable {
                disposable = resolvePeerByNameDisposable
            } else {
                disposable = MetaDisposable()
                self.resolvePeerByNameDisposable = disposable
            }
            var resolveSignal = self.context.engine.peers.resolvePeerByName(name: name, ageLimit: 10)
            
            var cancelImpl: (() -> Void)?
            let presentationData = self.presentationData
            let progressSignal = Signal<Never, NoError> { [weak self] subscriber in
                if progress != nil {
                    return ActionDisposable {
                    }
                } else {
                    let controller = OverlayStatusController(theme: presentationData.theme, type: .loading(cancelled: {
                        cancelImpl?()
                    }))
                    self?.present(controller, in: .window(.root))
                    return ActionDisposable { [weak controller] in
                        Queue.mainQueue().async() {
                            controller?.dismiss()
                        }
                    }
                }
            }
            |> runOn(Queue.mainQueue())
            |> delay(0.15, queue: Queue.mainQueue())
            let progressDisposable = progressSignal.start()
            
            resolveSignal = resolveSignal
            |> afterDisposed {
                Queue.mainQueue().async {
                    progressDisposable.dispose()
                }
            }
            cancelImpl = { [weak self] in
                self?.resolvePeerByNameDisposable?.set(nil)
            }
            disposable.set((resolveSignal
            |> deliverOnMainQueue).start(next: { [weak self] result in
                guard let self else {
                    return
                }
                switch result {
                case .progress:
                    progress?.set(.single(true))
                case let .result(peer):
                    progress?.set(.single(false))
                    
                    if let peer {
                        var navigation = navigation
                        if case .default = navigation {
                            if case let .user(user) = peer, user.botInfo != nil {
                                navigation = .chat(textInputState: nil, subject: nil, peekData: nil)
                            }
                        }
                        self.openResolved(result: .peer(peer._asPeer(), navigation), sourceMessageId: sourceMessageId)
                    } else {
                        self.present(textAlertController(context: self.context, updatedPresentationData: self.updatedPresentationData, title: nil, text: self.presentationData.strings.Resolve_ErrorNotFound, actions: [TextAlertAction(type: .defaultAction, title: self.presentationData.strings.Common_OK, action: {})]), in: .window(.root))
                    }
                }
            }))
        })
    }
    
    func openHashtag(_ hashtag: String, peerName: String?) {
        guard let peerId = self.chatLocation.peerId else {
            return
        }
        let _ = self.presentVoiceMessageDiscardAlert(action: {
            if self.resolvePeerByNameDisposable == nil {
                self.resolvePeerByNameDisposable = MetaDisposable()
            }
            var resolveSignal: Signal<Peer?, NoError>
            if let peerName = peerName {
                resolveSignal = self.context.engine.peers.resolvePeerByName(name: peerName)
                |> mapToSignal { result -> Signal<EnginePeer?, NoError> in
                    guard case let .result(result) = result else {
                        return .complete()
                    }
                    return .single(result)
                }
                |> mapToSignal { peer -> Signal<Peer?, NoError> in
                    if let peer = peer {
                        return .single(peer._asPeer())
                    } else {
                        return .single(nil)
                    }
                }
            } else {
                resolveSignal = self.context.account.postbox.loadedPeerWithId(peerId)
                |> map(Optional.init)
            }
            var cancelImpl: (() -> Void)?
            let presentationData = self.presentationData
            let progressSignal = Signal<Never, NoError> { [weak self] subscriber in
                let controller = OverlayStatusController(theme: presentationData.theme,  type: .loading(cancelled: {
                    cancelImpl?()
                }))
                self?.present(controller, in: .window(.root))
                return ActionDisposable { [weak controller] in
                    Queue.mainQueue().async() {
                        controller?.dismiss()
                    }
                }
            }
            |> runOn(Queue.mainQueue())
            |> delay(0.15, queue: Queue.mainQueue())
            let progressDisposable = progressSignal.start()
            
            resolveSignal = resolveSignal
            |> afterDisposed {
                Queue.mainQueue().async {
                    progressDisposable.dispose()
                }
            }
            cancelImpl = { [weak self] in
                self?.resolvePeerByNameDisposable?.set(nil)
            }
            self.resolvePeerByNameDisposable?.set((resolveSignal
            |> deliverOnMainQueue).start(next: { [weak self] peer in
                if let strongSelf = self, !hashtag.isEmpty {
                    let searchController = HashtagSearchController(context: strongSelf.context, peer: peer.flatMap(EnginePeer.init), query: hashtag)
                    strongSelf.effectiveNavigationController?.pushViewController(searchController)
                }
            }))
        })
    }
    
    func unblockPeer() {
        guard case let .peer(peerId) = self.chatLocation else {
            return
        }
        let unblockingPeer = self.unblockingPeer
        unblockingPeer.set(true)
        
        var restartBot = false
        if let user = self.presentationInterfaceState.renderedPeer?.peer as? TelegramUser, user.botInfo != nil {
            restartBot = true
        }
        self.editMessageDisposable.set((self.context.engine.privacy.requestUpdatePeerIsBlocked(peerId: peerId, isBlocked: false)
        |> afterDisposed({ [weak self] in
            Queue.mainQueue().async {
                unblockingPeer.set(false)
                if let strongSelf = self, restartBot {
                    strongSelf.startBot(strongSelf.presentationInterfaceState.botStartPayload)
                }
            }
        })).startStrict())
    }
    
    func reportPeer() {
        guard let renderedPeer = self.presentationInterfaceState.renderedPeer, let peer = renderedPeer.chatMainPeer, let chatPeer = renderedPeer.peer else {
            return
        }
        self.chatDisplayNode.dismissInput()
        
        if let peer = peer as? TelegramChannel, let username = peer.addressName, !username.isEmpty {
            let actionSheet = ActionSheetController(presentationData: self.presentationData)
            
            var items: [ActionSheetItem] = []
            items.append(ActionSheetButtonItem(title: self.presentationData.strings.Conversation_ReportSpamAndLeave, color: .destructive, action: { [weak self, weak actionSheet] in
                actionSheet?.dismissAnimated()
                if let strongSelf = self {
                    strongSelf.deleteChat(reportChatSpam: true)
                }
            }))
            actionSheet.setItemGroups([ActionSheetItemGroup(items: items), ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: self.presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                })
            ])])
            
            self.present(actionSheet, in: .window(.root))
        } else if let _ = peer as? TelegramUser {
            let presentationData = self.presentationData
            let controller = ActionSheetController(presentationData: presentationData)
            let dismissAction: () -> Void = { [weak controller] in
                controller?.dismissAnimated()
            }
            var reportSpam = true
            var deleteChat = true
            var items: [ActionSheetItem] = []
            if !peer.isDeleted {
                items.append(ActionSheetTextItem(title: presentationData.strings.UserInfo_BlockConfirmationTitle(EnginePeer(peer).compactDisplayTitle).string))
            }
            items.append(contentsOf: [
                ActionSheetCheckboxItem(title: presentationData.strings.Conversation_Moderate_Report, label: "", value: reportSpam, action: { [weak controller] checkValue in
                    reportSpam = checkValue
                    controller?.updateItem(groupIndex: 0, itemIndex: 1, { item in
                        if let item = item as? ActionSheetCheckboxItem {
                            return ActionSheetCheckboxItem(title: item.title, label: item.label, value: !item.value, action: item.action)
                        }
                        return item
                    })
                }),
                ActionSheetCheckboxItem(title: presentationData.strings.ReportSpam_DeleteThisChat, label: "", value: deleteChat, action: { [weak controller] checkValue in
                    deleteChat = checkValue
                    controller?.updateItem(groupIndex: 0, itemIndex: 2, { item in
                        if let item = item as? ActionSheetCheckboxItem {
                            return ActionSheetCheckboxItem(title: item.title, label: item.label, value: !item.value, action: item.action)
                        }
                        return item
                    })
                }),
                ActionSheetButtonItem(title: presentationData.strings.UserInfo_BlockActionTitle(EnginePeer(peer).compactDisplayTitle).string, color: .destructive, action: { [weak self] in
                    dismissAction()
                    guard let strongSelf = self else {
                        return
                    }
                    let _ = strongSelf.context.engine.privacy.requestUpdatePeerIsBlocked(peerId: peer.id, isBlocked: true).startStandalone()
                    if let _ = chatPeer as? TelegramSecretChat {
                        let _ = strongSelf.context.engine.peers.terminateSecretChat(peerId: chatPeer.id, requestRemoteHistoryRemoval: true).startStandalone()
                    }
                    if deleteChat {
                        let _ = strongSelf.context.engine.peers.removePeerChat(peerId: chatPeer.id, reportChatSpam: reportSpam).startStandalone()
                        strongSelf.effectiveNavigationController?.filterController(strongSelf, animated: true)
                    } else if reportSpam {
                        let _ = strongSelf.context.engine.peers.reportPeer(peerId: peer.id, reason: .spam, message: "").startStandalone()
                    }
                })
            ] as [ActionSheetItem])
            
            controller.setItemGroups([
                ActionSheetItemGroup(items: items),
            ActionSheetItemGroup(items: [ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, action: { dismissAction() })])
            ])
            self.present(controller, in: .window(.root), with: ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
        } else {
            let title: String
            var infoString: String?
            if let _ = peer as? TelegramGroup {
                title = self.presentationData.strings.Conversation_ReportSpamAndLeave
                infoString = self.presentationData.strings.Conversation_ReportSpamGroupConfirmation
            } else if let channel = peer as? TelegramChannel {
                title = self.presentationData.strings.Conversation_ReportSpamAndLeave
                if case .group = channel.info {
                    infoString = self.presentationData.strings.Conversation_ReportSpamGroupConfirmation
                } else {
                    infoString = self.presentationData.strings.Conversation_ReportSpamChannelConfirmation
                }
            } else {
                title = self.presentationData.strings.Conversation_ReportSpam
                infoString = self.presentationData.strings.Conversation_ReportSpamConfirmation
            }
            let actionSheet = ActionSheetController(presentationData: self.presentationData)
            
            var items: [ActionSheetItem] = []
            if let infoString = infoString {
                items.append(ActionSheetTextItem(title: infoString))
            }
            items.append(ActionSheetButtonItem(title: title, color: .destructive, action: { [weak self, weak actionSheet] in
                actionSheet?.dismissAnimated()
                if let strongSelf = self {
                    strongSelf.deleteChat(reportChatSpam: true)
                }
            }))
            actionSheet.setItemGroups([ActionSheetItemGroup(items: items), ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: self.presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                })
            ])])
            
            self.present(actionSheet, in: .window(.root))
        }
    }
    
    func shareAccountContact() {
        let _ = (self.context.account.postbox.loadedPeerWithId(self.context.account.peerId)
        |> deliverOnMainQueue).startStandalone(next: { [weak self] accountPeer in
            guard let strongSelf = self else {
                return
            }
            guard let user = accountPeer as? TelegramUser, let phoneNumber = user.phone else {
                return
            }
            guard let peer = strongSelf.presentationInterfaceState.renderedPeer?.chatMainPeer as? TelegramUser else {
                return
            }
            
            let actionSheet = ActionSheetController(presentationData: strongSelf.presentationData)
            var items: [ActionSheetItem] = []
            items.append(ActionSheetTextItem(title: strongSelf.presentationData.strings.Conversation_ShareMyPhoneNumberConfirmation(formatPhoneNumber(context: strongSelf.context, number: phoneNumber), EnginePeer(peer).compactDisplayTitle).string))
            items.append(ActionSheetButtonItem(title: strongSelf.presentationData.strings.Conversation_ShareMyPhoneNumber, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                guard let strongSelf = self else {
                    return
                }
                let _ = (strongSelf.context.engine.contacts.acceptAndShareContact(peerId: peer.id)
                |> deliverOnMainQueue).startStandalone(error: { _ in
                    guard let strongSelf = self else {
                        return
                    }
                    strongSelf.present(textAlertController(context: strongSelf.context, updatedPresentationData: strongSelf.updatedPresentationData, title: nil, text: strongSelf.presentationData.strings.Login_UnknownError, actions: [TextAlertAction(type: .defaultAction, title: strongSelf.presentationData.strings.Common_OK, action: {})]), in: .window(.root))
                }, completed: {
                    guard let strongSelf = self else {
                        return
                    }
                    strongSelf.present(OverlayStatusController(theme: strongSelf.presentationData.theme, type: .genericSuccess(strongSelf.presentationData.strings.Conversation_ShareMyPhoneNumber_StatusSuccess(EnginePeer(peer).compactDisplayTitle).string, true)), in: .window(.root))
                })
            }))
            
            actionSheet.setItemGroups([ActionSheetItemGroup(items: items), ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: strongSelf.presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                })
            ])])
            strongSelf.chatDisplayNode.dismissInput()
            strongSelf.present(actionSheet, in: .window(.root))
        })
    }
    
    func addPeerContact() {
        if let peer = self.presentationInterfaceState.renderedPeer?.chatMainPeer as? TelegramUser, let peerStatusSettings = self.presentationInterfaceState.contactStatus?.peerStatusSettings, let contactData = DeviceContactExtendedData(peer: EnginePeer(peer)) {
            self.present(context.sharedContext.makeDeviceContactInfoController(context: context, subject: .create(peer: peer, contactData: contactData, isSharing: true, shareViaException: peerStatusSettings.contains(.addExceptionWhenAddingContact), completion: { [weak self] peer, stableId, contactData in
                guard let strongSelf = self else {
                    return
                }
                if let peer = peer as? TelegramUser {
                    if let phone = peer.phone, !phone.isEmpty {
                    }
                    
                    self?.present(OverlayStatusController(theme: strongSelf.presentationData.theme, type: .genericSuccess(strongSelf.presentationData.strings.AddContact_StatusSuccess(EnginePeer(peer).compactDisplayTitle).string, true)), in: .window(.root))
                }
            }), completed: nil, cancelled: nil), in: .window(.root), with: ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
        }
    }
    
    func dismissPeerContactOptions() {
        guard case let .peer(peerId) = self.chatLocation else {
            return
        }
        let dismissPeerId: PeerId
        if let peer = self.presentationInterfaceState.renderedPeer?.chatMainPeer as? TelegramUser {
            dismissPeerId = peer.id
        } else {
            dismissPeerId = peerId
        }
        self.editMessageDisposable.set((self.context.engine.peers.dismissPeerStatusOptions(peerId: dismissPeerId)
        |> afterDisposed({
            Queue.mainQueue().async {
            }
        })).startStrict())
    }
    
    func deleteChat(reportChatSpam: Bool) {
        guard case let .peer(peerId) = self.chatLocation else {
            return
        }
        self.commitPurposefulAction()
        self.chatDisplayNode.historyNode.disconnect()
        let _ = self.context.engine.peers.removePeerChat(peerId: peerId, reportChatSpam: reportChatSpam).startStandalone()
        self.effectiveNavigationController?.popToRoot(animated: true)
        
        let _ = self.context.engine.privacy.requestUpdatePeerIsBlocked(peerId: peerId, isBlocked: true).startStandalone()
    }
    
    func startBot(_ payload: String?) {
        guard case let .peer(peerId) = self.chatLocation else {
            return
        }
        
        let startingBot = self.startingBot
        startingBot.set(true)
        self.editMessageDisposable.set((self.context.engine.messages.requestStartBot(botPeerId: peerId, payload: payload) |> deliverOnMainQueue |> afterDisposed({
            startingBot.set(false)
        })).startStrict(completed: { [weak self] in
            if let strongSelf = self {
                strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, { $0.updatedBotStartPayload(nil) })
            }
        }))
    }
    
    func openResolved(result: ResolvedUrl, sourceMessageId: MessageId?, progress: Promise<Bool>? = nil, forceExternal: Bool = false, concealed: Bool = false, commit: @escaping () -> Void = {}) {
        guard let peerId = self.chatLocation.peerId else {
            return
        }
        let message = sourceMessageId.flatMap { self.chatDisplayNode.historyNode.messageInCurrentHistoryView($0) }
        self.context.sharedContext.openResolvedUrl(result, context: self.context, urlContext: .chat(peerId: peerId, message: message, updatedPresentationData: self.updatedPresentationData), navigationController: self.effectiveNavigationController, forceExternal: forceExternal, openPeer: { [weak self] peerId, navigation in
            guard let strongSelf = self else {
                return
            }
            
            let dismissWebAppContollers: () -> Void = {
            }
            
            switch navigation {
                case let .chat(_, subject, peekData):
                    dismissWebAppContollers()
                    if case .peer(peerId.id) = strongSelf.chatLocation {
                        if let subject = subject, case let .message(messageSubject, _, timecode) = subject {
                            if case let .id(messageId) = messageSubject {
                                strongSelf.navigateToMessage(from: sourceMessageId, to: .id(messageId, NavigateToMessageParams(timestamp: timecode, quote: nil)))
                            }
                        } else {
                            self?.playShakeAnimation()
                        }
                    } else if let navigationController = strongSelf.effectiveNavigationController {
                        if case let .channel(channel) = peerId, channel.flags.contains(.isForum) {
                            strongSelf.context.sharedContext.navigateToForumChannel(context: strongSelf.context, peerId: peerId.id, navigationController: navigationController)
                        } else {
                            strongSelf.context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: strongSelf.context, chatLocation: .peer(peerId), subject: subject, keepStack: .always, peekData: peekData))
                        }
                    }
                    commit()
                case .info:
                    dismissWebAppContollers()
                    strongSelf.navigationActionDisposable.set((strongSelf.context.account.postbox.loadedPeerWithId(peerId.id)
                    |> take(1)
                    |> deliverOnMainQueue).startStrict(next: { [weak self] peer in
                        if let strongSelf = self, peer.restrictionText(platform: "ios", contentSettings: strongSelf.context.currentContentSettings.with { $0 }) == nil {
                            if let infoController = strongSelf.context.sharedContext.makePeerInfoController(context: strongSelf.context, updatedPresentationData: strongSelf.updatedPresentationData, peer: peer, mode: .generic, avatarInitiallyExpanded: false, fromChat: false, requestsContext: nil) {
                                strongSelf.effectiveNavigationController?.pushViewController(infoController)
                            }
                        }
                    }))
                    commit()
                case let .withBotStartPayload(startPayload):
                    dismissWebAppContollers()
                    if case .peer(peerId.id) = strongSelf.chatLocation {
                        strongSelf.startBot(startPayload.payload)
                    } else if let navigationController = strongSelf.effectiveNavigationController {
                        strongSelf.context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: strongSelf.context, chatLocation: .peer(peerId), botStart: startPayload, keepStack: .always))
                    }
                    commit()
                case let .withAttachBot(attachBotStart):
                    dismissWebAppContollers()
                    if let navigationController = strongSelf.effectiveNavigationController {
                        strongSelf.context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: strongSelf.context, chatLocation: .peer(peerId), attachBotStart: attachBotStart))
                    }
                    commit()
                case let .withBotApp(botAppStart):
                    let _ = (strongSelf.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId.id))
                    |> deliverOnMainQueue).startStandalone(next: { [weak self] peer in
                        if let strongSelf = self, let peer {
                            strongSelf.presentBotApp(botApp: botAppStart.botApp, botPeer: peer, payload: botAppStart.payload, concealed: concealed, commit: {
                                dismissWebAppContollers()
                                commit()
                            })
                        }
                    })
                default:
                    break
                }
        }, sendFile: nil, sendSticker: { [weak self] f, sourceView, sourceRect in
            return self?.interfaceInteraction?.sendSticker(f, true, sourceView, sourceRect, nil, []) ?? false
        }, requestMessageActionUrlAuth: { [weak self] subject in
            if case let .url(url) = subject {
                self?.controllerInteraction?.requestMessageActionUrlAuth(url, subject)
            }
        }, joinVoiceChat: { [weak self] peerId, invite, call in
            self?.joinGroupCall(peerId: peerId, invite: invite, activeCall: EngineGroupCallDescription(call))
        }, present: { [weak self] c, a in
            if c is UndoOverlayController {
                self?.present(c, in: .current)
            } else {
                self?.present(c, in: .window(.root), with: a)
            }
        }, dismissInput: { [weak self] in
            self?.chatDisplayNode.dismissInput()
        }, contentContext: nil, progress: progress, completion: nil)
    }
    
    func openUrl(_ url: String, concealed: Bool, forceExternal: Bool = false, skipUrlAuth: Bool = false, skipConcealedAlert: Bool = false, message: Message? = nil, allowInlineWebpageResolution: Bool = false, progress: Promise<Bool>? = nil, commit: @escaping () -> Void = {}) {
        self.commitPurposefulAction()
        
        if allowInlineWebpageResolution, let message, let webpage = message.media.first(where: { $0 is TelegramMediaWebpage }) as? TelegramMediaWebpage, case let .Loaded(content) = webpage.content, content.url == url {
            if content.instantPage != nil {
                if let navigationController = self.navigationController as? NavigationController {
                    switch instantPageType(of: content) {
                    case .album:
                        break
                    default:
                        progress?.set(.single(false))
                        self.context.sharedContext.openChatInstantPage(context: self.context, message: message, sourcePeerType: nil, navigationController: navigationController)
                        return
                    }
                }
            } else if content.file == nil, (content.image == nil || content.isMediaLargeByDefault == true || content.isMediaLargeByDefault == nil), let embedUrl = content.embedUrl, !embedUrl.isEmpty {
                progress?.set(.single(false))
                if let controllerInteraction = self.controllerInteraction {
                    if controllerInteraction.openMessage(message, OpenMessageParams(mode: .default)) {
                        return
                    }
                }
            }
        }
        
        let _ = self.presentVoiceMessageDiscardAlert(action: { [weak self] in
            guard let self else {
                return
            }
            let disposable = openUserGeneratedUrl(context: self.context, peerId: self.peerView?.peerId, url: url, concealed: concealed, skipUrlAuth: skipUrlAuth, skipConcealedAlert: skipConcealedAlert, present: { [weak self] c in
                self?.present(c, in: .window(.root))
            }, openResolved: { [weak self] resolved in
                self?.openResolved(result: resolved, sourceMessageId: message?.id, forceExternal: forceExternal, concealed: concealed, commit: commit)
            }, progress: progress)
            self.navigationActionDisposable.set(disposable)
        }, performAction: true)
    }
    
    func openUrlIn(_ url: String) {
        let actionSheet = OpenInActionSheetController(context: self.context, updatedPresentationData: self.updatedPresentationData, item: .url(url: url), openUrl: { [weak self] url in
            if let strongSelf = self, let navigationController = strongSelf.effectiveNavigationController {
                strongSelf.context.sharedContext.openExternalUrl(context: strongSelf.context, urlContext: .generic, url: url, forceExternal: true, presentationData: strongSelf.presentationData, navigationController: navigationController, dismissInput: {
                    self?.chatDisplayNode.dismissInput()
                })
            }
        })
        self.chatDisplayNode.dismissInput()
        self.present(actionSheet, in: .window(.root))
    }
        
    func presentBanMessageOptions(accountPeerId: PeerId, author: Peer, messageIds: Set<MessageId>, options: ChatAvailableMessageActionOptions) {
        guard let peerId = self.chatLocation.peerId else {
            return
        }
        do {
            self.navigationActionDisposable.set((self.context.engine.peers.fetchChannelParticipant(peerId: peerId, participantId: author.id)
            |> deliverOnMainQueue).startStrict(next: { [weak self] participant in
                if let strongSelf = self {
                    let canBan = participant?.canBeBannedBy(peerId: accountPeerId) ?? true
                    
                    let actionSheet = ActionSheetController(presentationData: strongSelf.presentationData)
                    var items: [ActionSheetItem] = []
                    
                    var actions = Set<Int>([0])
                    
                    let toggleCheck: (Int, Int) -> Void = { [weak actionSheet] category, itemIndex in
                        if actions.contains(category) {
                            actions.remove(category)
                        } else {
                            actions.insert(category)
                        }
                        actionSheet?.updateItem(groupIndex: 0, itemIndex: itemIndex, { item in
                            if let item = item as? ActionSheetCheckboxItem {
                                return ActionSheetCheckboxItem(title: item.title, label: item.label, value: !item.value, action: item.action)
                            }
                            return item
                        })
                    }
                    
                    var itemIndex = 0
                    var categories: [Int] = [0]
                    if canBan {
                        categories.append(1)
                    }
                    categories.append(contentsOf: [2, 3])
                    
                    for categoryId in categories as [Int] {
                        var title = ""
                        if categoryId == 0 {
                            title = strongSelf.presentationData.strings.Conversation_Moderate_Delete
                        } else if categoryId == 1 {
                            title = strongSelf.presentationData.strings.Conversation_Moderate_Ban
                        } else if categoryId == 2 {
                            title = strongSelf.presentationData.strings.Conversation_Moderate_Report
                        } else if categoryId == 3 {
                            title = strongSelf.presentationData.strings.Conversation_Moderate_DeleteAllMessages(EnginePeer(author).displayTitle(strings: strongSelf.presentationData.strings, displayOrder: strongSelf.presentationData.nameDisplayOrder)).string
                        }
                        let index = itemIndex
                        items.append(ActionSheetCheckboxItem(title: title, label: "", value: actions.contains(categoryId), action: { value in
                            toggleCheck(categoryId, index)
                        }))
                        itemIndex += 1
                    }
                    
                    items.append(ActionSheetButtonItem(title: strongSelf.presentationData.strings.Common_Done, action: { [weak self, weak actionSheet] in
                        actionSheet?.dismissAnimated()
                        if let strongSelf = self {
                            strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, { $0.updatedInterfaceState { $0.withoutSelectionState() } })
                            if actions.contains(3) {
                                let _ = strongSelf.context.engine.messages.deleteAllMessagesWithAuthor(peerId: peerId, authorId: author.id, namespace: Namespaces.Message.Cloud).startStandalone()
                                let _ = strongSelf.context.engine.messages.clearAuthorHistory(peerId: peerId, memberId: author.id).startStandalone()
                            } else if actions.contains(0) {
                                let _ = strongSelf.context.engine.messages.deleteMessagesInteractively(messageIds: Array(messageIds), type: .forEveryone).startStandalone()
                            }
                            if actions.contains(1) {
                                let _ = strongSelf.context.engine.peers.removePeerMember(peerId: peerId, memberId: author.id).startStandalone()
                            }
                        }
                    }))
                    
                    actionSheet.setItemGroups([ActionSheetItemGroup(items: items), ActionSheetItemGroup(items: [
                        ActionSheetButtonItem(title: strongSelf.presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                            actionSheet?.dismissAnimated()
                        })
                    ])])
                    strongSelf.chatDisplayNode.dismissInput()
                    strongSelf.present(actionSheet, in: .window(.root))
                }
            }))
        }
    }
    
    func presentDeleteMessageOptions(messageIds: Set<MessageId>, options: ChatAvailableMessageActionOptions, contextController: ContextControllerProtocol?, completion: @escaping (ContextMenuActionResult) -> Void) {
        let actionSheet = ActionSheetController(presentationData: self.presentationData)
        var items: [ActionSheetItem] = []
        var personalPeerName: String?
        var isChannel = false
        if let user = self.presentationInterfaceState.renderedPeer?.peer as? TelegramUser {
            personalPeerName = EnginePeer(user).compactDisplayTitle
        } else if let peer = self.presentationInterfaceState.renderedPeer?.peer as? TelegramSecretChat, let associatedPeerId = peer.associatedPeerId, let user = self.presentationInterfaceState.renderedPeer?.peers[associatedPeerId] as? TelegramUser {
            personalPeerName = EnginePeer(user).compactDisplayTitle
        } else if let channel = self.presentationInterfaceState.renderedPeer?.peer as? TelegramChannel, case .broadcast = channel.info {
            isChannel = true
        }
        
        if options.contains(.cancelSending) {
            items.append(ActionSheetButtonItem(title: self.presentationData.strings.Conversation_ContextMenuCancelSending, color: .destructive, action: { [weak self, weak actionSheet] in
                actionSheet?.dismissAnimated()
                if let strongSelf = self {
                    strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, { $0.updatedInterfaceState { $0.withoutSelectionState() } })
                    let _ = strongSelf.context.engine.messages.deleteMessagesInteractively(messageIds: Array(messageIds), type: .forEveryone).startStandalone()
                }
            }))
        }
        
        var contextItems: [ContextMenuItem] = []
        var canDisplayContextMenu = true
        
        var unsendPersonalMessages = false
        if options.contains(.unsendPersonal) {
            canDisplayContextMenu = false
            items.append(ActionSheetTextItem(title: self.presentationData.strings.Chat_UnsendMyMessagesAlertTitle(personalPeerName ?? "").string))
            items.append(ActionSheetSwitchItem(title: self.presentationData.strings.Chat_UnsendMyMessages, isOn: false, action: { value in
                unsendPersonalMessages = value
            }))
        } else if options.contains(.deleteGlobally) {
            let globalTitle: String
            if isChannel {
                globalTitle = self.presentationData.strings.Conversation_DeleteMessagesForEveryone
            } else if let personalPeerName = personalPeerName {
                globalTitle = self.presentationData.strings.Conversation_DeleteMessagesFor(personalPeerName).string
            } else {
                globalTitle = self.presentationData.strings.Conversation_DeleteMessagesForEveryone
            }
            contextItems.append(.action(ContextMenuActionItem(text: globalTitle, textColor: .destructive, icon: { _ in nil }, action: { [weak self] c, f in
                if let strongSelf = self {
                    var giveaway: TelegramMediaGiveaway?
                    for messageId in messageIds {
                        if let message = strongSelf.chatDisplayNode.historyNode.messageInCurrentHistoryView(messageId) {
                            if let media = message.media.first(where: { $0 is TelegramMediaGiveaway }) as? TelegramMediaGiveaway {
                                giveaway = media
                                break
                            }
                        }
                    }
                    let commit = {
                        strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, { $0.updatedInterfaceState { $0.withoutSelectionState() } })
                        let _ = strongSelf.context.engine.messages.deleteMessagesInteractively(messageIds: Array(messageIds), type: .forEveryone).startStandalone()
                    }
                    if let giveaway {
                        Queue.mainQueue().after(0.2) {
                            let dateString = stringForDate(timestamp: giveaway.untilDate, timeZone: .current, strings: strongSelf.presentationData.strings)
                            strongSelf.present(textAlertController(context: strongSelf.context, updatedPresentationData: strongSelf.updatedPresentationData, title: strongSelf.presentationData.strings.Chat_Giveaway_DeleteConfirmation_Title, text: strongSelf.presentationData.strings.Chat_Giveaway_DeleteConfirmation_Text(dateString).string, actions: [TextAlertAction(type: .destructiveAction, title: strongSelf.presentationData.strings.Common_Delete, action: {
                                commit()
                            }), TextAlertAction(type: .defaultAction, title: strongSelf.presentationData.strings.Common_Cancel, action: {
                            })], parseMarkdown: true), in: .window(.root))
                        }
                        f(.default)
                    } else {
                        if "".isEmpty {
                            f(.dismissWithoutContent)
                            commit()
                        } else {
                            c.dismiss(completion: {
                                DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.1, execute: {
                                    commit()
                                })
                            })
                        }
                    }
                }
            })))
            items.append(ActionSheetButtonItem(title: globalTitle, color: .destructive, action: { [weak self, weak actionSheet] in
                actionSheet?.dismissAnimated()
                if let strongSelf = self {
                    strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, { $0.updatedInterfaceState { $0.withoutSelectionState() } })
                    let _ = strongSelf.context.engine.messages.deleteMessagesInteractively(messageIds: Array(messageIds), type: .forEveryone).startStandalone()
                }
            }))
        }
        if options.contains(.deleteLocally) {
            var localOptionText = self.presentationData.strings.Conversation_DeleteMessagesForMe
            if self.chatLocation.peerId == self.context.account.peerId {
                localOptionText = self.presentationData.strings.Chat_ConfirmationRemoveFromSavedMessages
            } else if case .scheduledMessages = self.presentationInterfaceState.subject {
                localOptionText = messageIds.count > 1 ? self.presentationData.strings.ScheduledMessages_DeleteMany : self.presentationData.strings.ScheduledMessages_Delete
            } else {
                if options.contains(.unsendPersonal) {
                    localOptionText = self.presentationData.strings.Chat_DeleteMessagesConfirmation(Int32(messageIds.count))
                } else if case .peer(self.context.account.peerId) = self.chatLocation {
                    if messageIds.count == 1 {
                        localOptionText = self.presentationData.strings.Conversation_Moderate_Delete
                    } else {
                        localOptionText = self.presentationData.strings.Conversation_DeleteManyMessages
                    }
                }
            }
            contextItems.append(.action(ContextMenuActionItem(text: localOptionText, textColor: .destructive, icon: { _ in nil }, action: { [weak self] c, f in
                if let strongSelf = self {
                    strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, { $0.updatedInterfaceState { $0.withoutSelectionState() } })
                    
                    let commit: () -> Void = {
                        guard let strongSelf = self else {
                            return
                        }
                        let _ = strongSelf.context.engine.messages.deleteMessagesInteractively(messageIds: Array(messageIds), type: unsendPersonalMessages ? .forEveryone : .forLocalPeer).startStandalone()
                    }
                    
                    if "".isEmpty {
                        f(.dismissWithoutContent)
                        commit()
                    } else {
                        c.dismiss(completion: {
                            DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.1, execute: {
                                commit()
                            })
                        })
                    }
                }
            })))
            items.append(ActionSheetButtonItem(title: localOptionText, color: .destructive, action: { [weak self, weak actionSheet] in
                actionSheet?.dismissAnimated()
                if let strongSelf = self {
                    strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, { $0.updatedInterfaceState { $0.withoutSelectionState() } })
                    let _ = strongSelf.context.engine.messages.deleteMessagesInteractively(messageIds: Array(messageIds), type: unsendPersonalMessages ? .forEveryone : .forLocalPeer).startStandalone()
                    
                }
            }))
        }
        
        if canDisplayContextMenu, let contextController = contextController {
            contextController.setItems(.single(ContextController.Items(content: .list(contextItems))), minHeight: nil, animated: true)
        } else {
            actionSheet.setItemGroups([ActionSheetItemGroup(items: items), ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: self.presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                })
            ])])
            
            if let contextController = contextController {
                contextController.dismiss(completion: { [weak self] in
                    self?.present(actionSheet, in: .window(.root))
                })
            } else {
                self.chatDisplayNode.dismissInput()
                self.present(actionSheet, in: .window(.root))
                completion(.default)
            }
        }
    }
    
    func presentClearCacheSuggestion() {
        guard let peer = self.presentationInterfaceState.renderedPeer?.peer else {
            return
        }
        self.updateChatPresentationInterfaceState(animated: true, interactive: true, { $0.updatedInterfaceState({ $0.withoutSelectionState() }) })
        
        let actionSheet = ActionSheetController(presentationData: self.presentationData)
        var items: [ActionSheetItem] = []
        
        items.append(DeleteChatPeerActionSheetItem(context: self.context, peer: EnginePeer(peer), chatPeer: EnginePeer(peer), action: .clearCacheSuggestion, strings: self.presentationData.strings, nameDisplayOrder: self.presentationData.nameDisplayOrder))
        
        var presented = false
        items.append(ActionSheetButtonItem(title: self.presentationData.strings.ClearCache_FreeSpace, color: .accent, action: { [weak self, weak actionSheet] in
           actionSheet?.dismissAnimated()
            if let strongSelf = self, !presented {
                presented = true
                let context = strongSelf.context
                strongSelf.push(StorageUsageScreen(context: context, makeStorageUsageExceptionsScreen: { category in
                    return storageUsageExceptionsScreen(context: context, category: category)
                }))
           }
        }))
    
        actionSheet.setItemGroups([ActionSheetItemGroup(items: items), ActionSheetItemGroup(items: [
            ActionSheetButtonItem(title: self.presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
            })
        ])])
        self.chatDisplayNode.dismissInput()
        self.presentInGlobalOverlay(actionSheet)
    }
    
    @available(iOSApplicationExtension 11.0, iOS 11.0, *)
    public func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        return session.hasItemsConforming(toTypeIdentifiers: [kUTTypeImage as String])
    }
    
    @available(iOSApplicationExtension 11.0, iOS 11.0, *)
    public func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        if !canSendMessagesToChat(self.presentationInterfaceState) {
            return UIDropProposal(operation: .cancel)
        }
        
        //let dropLocation = session.location(in: self.chatDisplayNode.view)
        self.chatDisplayNode.updateDropInteraction(isActive: true)
        
        let operation: UIDropOperation
        operation = .copy
        return UIDropProposal(operation: operation)
    }
    
    @available(iOSApplicationExtension 11.0, iOS 11.0, *)
    public func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        session.loadObjects(ofClass: UIImage.self) { [weak self] imageItems in
            guard let strongSelf = self, !imageItems.isEmpty else {
                return
            }
            let images = imageItems as! [UIImage]
            
            strongSelf.chatDisplayNode.updateDropInteraction(isActive: false)
            if images.count == 1, let image = images.first, let cgImage = image.cgImage {
                let maxSide = max(image.size.width, image.size.height)
                if maxSide.isZero {
                    return
                }
                let aspectRatio = min(image.size.width, image.size.height) / maxSide
                if (imageHasTransparency(cgImage) && aspectRatio > 0.2) {
                    strongSelf.enqueueStickerImage(image, isMemoji: false)
                    return
                }
            }
            strongSelf.chatDisplayNode.updateDropInteraction(isActive: false)
            strongSelf.displayPasteMenu(images.map { .image($0) })
        }
    }
    
    @available(iOSApplicationExtension 11.0, iOS 11.0, *)
    public func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) {
        self.chatDisplayNode.updateDropInteraction(isActive: false)
    }
    
    @available(iOSApplicationExtension 11.0, iOS 11.0, *)
    public func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) {
        self.chatDisplayNode.updateDropInteraction(isActive: false)
    }
    
    public func beginMessageSearch(_ query: String) {
        self.interfaceInteraction?.beginMessageSearch(.everything, query)
    }
    
    public func beginReportSelection(reason: ReportReason) {
        self.updateChatPresentationInterfaceState(animated: true, interactive: true, { $0.updatedReportReason(reason).updatedInterfaceState { $0.withUpdatedSelectedMessages([]) } })
    }
    
    func displayMediaRecordingTooltip() {
        guard let peer = self.presentationInterfaceState.renderedPeer?.peer else {
            return
        }
        
        let rect: CGRect? = self.chatDisplayNode.frameForInputActionButton()
        
        let updatedMode: ChatTextInputMediaRecordingButtonMode = self.presentationInterfaceState.interfaceState.mediaRecordingMode
        
        let text: String
        
        var canSwitch = true
        if let channel = peer as? TelegramChannel {
            if channel.hasBannedPermission(.banSendVoice) != nil && channel.hasBannedPermission(.banSendInstantVideos) != nil {
                canSwitch = false
            } else if channel.hasBannedPermission(.banSendVoice) != nil {
                if channel.hasBannedPermission(.banSendInstantVideos) == nil {
                    canSwitch = false
                }
            } else if channel.hasBannedPermission(.banSendInstantVideos) != nil {
                if channel.hasBannedPermission(.banSendVoice) == nil {
                    canSwitch = false
                }
            }
        } else if let group = peer as? TelegramGroup {
            if group.hasBannedPermission(.banSendVoice) && group.hasBannedPermission(.banSendInstantVideos) {
                canSwitch = false
            } else if group.hasBannedPermission(.banSendVoice) {
                if !group.hasBannedPermission(.banSendInstantVideos) {
                    canSwitch = false
                }
            } else if group.hasBannedPermission(.banSendInstantVideos) {
                if !group.hasBannedPermission(.banSendVoice) {
                    canSwitch = false
                }
            }
        }
        
        if updatedMode == .audio {
            if canSwitch {
                text = self.presentationData.strings.Conversation_HoldForAudio
            } else {
                text = self.presentationData.strings.Conversation_HoldForAudioOnly
            }
        } else {
            if canSwitch {
                text = self.presentationData.strings.Conversation_HoldForVideo
            } else {
                text = self.presentationData.strings.Conversation_HoldForVideoOnly
            }
        }
        
        self.silentPostTooltipController?.dismiss()
        
        if let tooltipController = self.mediaRecordingModeTooltipController {
            tooltipController.updateContent(.text(text), animated: true, extendTimer: true)
        } else if let rect = rect {
            let tooltipController = TooltipController(content: .text(text), baseFontSize: self.presentationData.listsFontSize.baseDisplaySize, padding: 2.0)
            self.mediaRecordingModeTooltipController = tooltipController
            tooltipController.dismissed = { [weak self, weak tooltipController] _ in
                if let strongSelf = self, let tooltipController = tooltipController, strongSelf.mediaRecordingModeTooltipController === tooltipController {
                    strongSelf.mediaRecordingModeTooltipController = nil
                }
            }
            self.present(tooltipController, in: .window(.root), with: TooltipControllerPresentationArguments(sourceNodeAndRect: { [weak self] in
                if let strongSelf = self {
                    return (strongSelf.chatDisplayNode, rect)
                }
                return nil
            }))
        }
    }
    
    func displaySendWhenOnlineTooltip() {
        guard let rect = self.chatDisplayNode.frameForInputActionButton(), self.effectiveNavigationController?.topViewController === self, let peerId = self.chatLocation.peerId else {
            return
        }
        let inputText = self.presentationInterfaceState.interfaceState.effectiveInputState.inputText.string
        guard !inputText.isEmpty else {
            return
        }
        
        self.sendingOptionsTooltipController?.dismiss()
        
        let _ = (ApplicationSpecificNotice.getSendWhenOnlineTip(accountManager: self.context.sharedContext.accountManager)
        |> deliverOnMainQueue).startStandalone(next: { [weak self] counter in
            if let strongSelf = self, counter < 3 {
                let _ = (strongSelf.context.account.viewTracker.peerView(peerId)
                |> take(1)
                |> deliverOnMainQueue).startStandalone(next: { [weak self] peerView in
                    guard let strongSelf = self, let peer = peerViewMainPeer(peerView) else {
                        return
                    }
                    var sendWhenOnlineAvailable = false
                    if peer.id != strongSelf.context.account.peerId, let presence = peerView.peerPresences[peer.id] as? TelegramUserPresence, case let .present(until) = presence.status, until != .max {
                        let currentTime = Int32(CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970)
                        let (_, _, _, hours, _) = getDateTimeComponents(timestamp: currentTime)
                        if currentTime > until + 60 * 30 && hours >= 0 && hours <= 8 {
                            sendWhenOnlineAvailable = true
                        }
                    }
                    if peer.id.namespace == Namespaces.Peer.CloudUser && peer.id.id._internalGetInt64Value() == 777000 {
                        sendWhenOnlineAvailable = false
                    }
                    
                    if sendWhenOnlineAvailable {
                        let _ = ApplicationSpecificNotice.incrementSendWhenOnlineTip(accountManager: strongSelf.context.sharedContext.accountManager).startStandalone()
                        
                        let tooltipController = TooltipController(content: .text(strongSelf.presentationData.strings.Conversation_SendWhenOnlineTooltip), baseFontSize: strongSelf.presentationData.listsFontSize.baseDisplaySize, timeout: 3.0, dismissByTapOutside: true, dismissImmediatelyOnLayoutUpdate: true, padding: 2.0)
                        strongSelf.sendingOptionsTooltipController = tooltipController
                        tooltipController.dismissed = { [weak self, weak tooltipController] _ in
                            if let strongSelf = self, let tooltipController = tooltipController, strongSelf.sendingOptionsTooltipController === tooltipController {
                                strongSelf.sendingOptionsTooltipController = nil
                            }
                        }
                        strongSelf.present(tooltipController, in: .window(.root), with: TooltipControllerPresentationArguments(sourceNodeAndRect: { [weak self] in
                            if let strongSelf = self {
                                return (strongSelf.chatDisplayNode, rect)
                            }
                            return nil
                        }))
                    }
                })
            }
        })
    }
    
    func displaySendingOptionsTooltip() {
        guard let rect = self.chatDisplayNode.frameForInputActionButton(), self.effectiveNavigationController?.topViewController === self else {
            return
        }
        self.sendingOptionsTooltipController?.dismiss()
        let tooltipController = TooltipController(content: .text(self.presentationData.strings.Conversation_SendingOptionsTooltip), baseFontSize: self.presentationData.listsFontSize.baseDisplaySize, timeout: 3.0, dismissByTapOutside: true, dismissImmediatelyOnLayoutUpdate: true, padding: 2.0)
        self.sendingOptionsTooltipController = tooltipController
        tooltipController.dismissed = { [weak self, weak tooltipController] _ in
            if let strongSelf = self, let tooltipController = tooltipController, strongSelf.sendingOptionsTooltipController === tooltipController {
                strongSelf.sendingOptionsTooltipController = nil
            }
        }
        self.present(tooltipController, in: .window(.root), with: TooltipControllerPresentationArguments(sourceNodeAndRect: { [weak self] in
            if let strongSelf = self {
                return (strongSelf.chatDisplayNode, rect)
            }
            return nil
        }))
    }
    
    func displayEmojiTooltip() {
        guard let rect = self.chatDisplayNode.frameForEmojiButton(), self.effectiveNavigationController?.topViewController === self else {
            return
        }
        self.emojiTooltipController?.dismiss()
        let tooltipController = TooltipController(content: .text(self.presentationData.strings.Conversation_EmojiTooltip), baseFontSize: self.presentationData.listsFontSize.baseDisplaySize, timeout: 3.0, dismissByTapOutside: true, dismissImmediatelyOnLayoutUpdate: true, padding: 2.0)
        self.emojiTooltipController = tooltipController
        tooltipController.dismissed = { [weak self, weak tooltipController] _ in
            if let strongSelf = self, let tooltipController = tooltipController, strongSelf.emojiTooltipController === tooltipController {
                strongSelf.emojiTooltipController = nil
            }
        }
        self.present(tooltipController, in: .window(.root), with: TooltipControllerPresentationArguments(sourceNodeAndRect: { [weak self] in
            if let strongSelf = self {
                return (strongSelf.chatDisplayNode, rect.offsetBy(dx: 0.0, dy: -3.0))
            }
            return nil
        }))
    }
    
    func displayGroupEmojiTooltip() {
        guard let rect = self.chatDisplayNode.frameForEmojiButton(), self.effectiveNavigationController?.topViewController === self else {
            return
        }
        guard let emojiPack = (self.peerView?.cachedData as? CachedChannelData)?.emojiPack, let thumbnailFileId = emojiPack.thumbnailFileId else {
            return
        }
        //TODO:localize
        let _ = (self.context.engine.stickers.resolveInlineStickers(fileIds: [thumbnailFileId])
        |> deliverOnMainQueue).start(next: { files in
            guard let emojiFile = files.values.first else {
                return
            }
            
            let textFont = Font.regular(self.presentationData.listsFontSize.baseDisplaySize * 14.0 / 17.0)
            let boldTextFont = Font.bold(self.presentationData.listsFontSize.baseDisplaySize * 14.0 / 17.0)
            let textColor = UIColor.white
            let markdownAttributes = MarkdownAttributes(body: MarkdownAttributeSet(font: textFont, textColor: textColor), bold: MarkdownAttributeSet(font: boldTextFont, textColor: textColor), link: MarkdownAttributeSet(font: textFont, textColor: textColor), linkAttribute: { _ in
                return nil
            })
            
            let text = NSMutableAttributedString(attributedString: parseMarkdownIntoAttributedString("All members of this group can\nuse the # **\(emojiPack.title)** pack", attributes: markdownAttributes))
            
            let range = (text.string as NSString).range(of: "#")
            if range.location != NSNotFound {
                text.addAttribute(ChatTextInputAttributes.customEmoji, value: ChatTextInputTextCustomEmojiAttribute(interactivelySelectedFromPackId: nil, fileId: emojiFile.fileId.id, file: emojiFile), range: range)
            }
            
            let tooltipScreen = TooltipScreen(
                context: self.context,
                account: self.context.account,
                sharedContext: self.context.sharedContext,
                text: .attributedString(text: text),
//                style: .customBlur(UIColor(rgb: 0x000000, alpha: 0.8), 2.0),
                location: .point(rect.offsetBy(dx: 0.0, dy: -3.0), .bottom),
                displayDuration: .default,
                cornerRadius: 10.0,
                shouldDismissOnTouch: { point, _ in
                    return .ignore
                }
            )
            self.present(tooltipScreen, in: .current)
            
            
//            self.emojiTooltipController?.dismiss()
//            let tooltipController = TooltipController(content: .attributedText(text), baseFontSize: self.presentationData.listsFontSize.baseDisplaySize, timeout: 3.0, dismissByTapOutside: true, dismissImmediatelyOnLayoutUpdate: true, padding: 8.0)
//            self.emojiTooltipController = tooltipController
//            tooltipController.dismissed = { [weak self, weak tooltipController] _ in
//                if let strongSelf = self, let tooltipController = tooltipController, strongSelf.emojiTooltipController === tooltipController {
//                    strongSelf.emojiTooltipController = nil
//                }
//            }
//            self.present(tooltipController, in: .window(.root), with: TooltipControllerPresentationArguments(sourceNodeAndRect: { [weak self] in
//                if let strongSelf = self {
//                    return (strongSelf.chatDisplayNode, rect.offsetBy(dx: 0.0, dy: -3.0))
//                }
//                return nil
//            }))
        })
    }
    
    func displayChecksTooltip() {
        self.checksTooltipController?.dismiss()
        
        var latestNode: (Int32, ASDisplayNode)?
        self.chatDisplayNode.historyNode.forEachVisibleItemNode { itemNode in
            if let itemNode = itemNode as? ChatMessageItemView, let item = itemNode.item, let statusNode = itemNode.getStatusNode() {
                if !item.content.effectivelyIncoming(self.context.account.peerId) {
                    if let (latestTimestamp, _) = latestNode {
                        if item.message.timestamp > latestTimestamp {
                            latestNode = (item.message.timestamp, statusNode)
                        }
                    } else {
                        latestNode = (item.message.timestamp, statusNode)
                    }
                }
            }
        }
        
        if let (_, latestStatusNode) = latestNode {
            let bounds = latestStatusNode.view.convert(latestStatusNode.view.bounds, to: self.chatDisplayNode.view)
            let location = CGPoint(x: bounds.maxX - 7.0, y: bounds.minY - 11.0)
            
            let contentNode = ChatStatusChecksTooltipContentNode(presentationData: self.presentationData)
            let tooltipController = TooltipController(content: .custom(contentNode), baseFontSize: self.presentationData.listsFontSize.baseDisplaySize, timeout: 3.5, dismissByTapOutside: true, dismissImmediatelyOnLayoutUpdate: true)
            self.checksTooltipController = tooltipController
            tooltipController.dismissed = { [weak self, weak tooltipController] _ in
                if let strongSelf = self, let tooltipController = tooltipController, strongSelf.checksTooltipController === tooltipController {
                    strongSelf.checksTooltipController = nil
                }
            }
            self.present(tooltipController, in: .window(.root), with: TooltipControllerPresentationArguments(sourceNodeAndRect: { [weak self] in
                if let strongSelf = self {
                    return (strongSelf.chatDisplayNode, CGRect(origin: location, size: CGSize()))
                }
                return nil
            }))
        }
    }
    
    func dismissAllTooltips() {
        self.emojiTooltipController?.dismiss()
        self.sendingOptionsTooltipController?.dismiss()
        self.searchResultsTooltipController?.dismiss()
        self.messageTooltipController?.dismiss()
        self.videoUnmuteTooltipController?.dismiss()
        self.silentPostTooltipController?.dismiss()
        self.mediaRecordingModeTooltipController?.dismiss()
        self.mediaRestrictedTooltipController?.dismiss()
        self.checksTooltipController?.dismiss()
        self.copyProtectionTooltipController?.dismiss()
        
        self.window?.forEachController({ controller in
            if let controller = controller as? UndoOverlayController {
                controller.dismissWithCommitAction()
            }
        })
        self.forEachController({ controller in
            if let controller = controller as? UndoOverlayController {
                controller.dismissWithCommitAction()
            }
            if let controller = controller as? TooltipScreen, !controller.alwaysVisible {
                controller.dismiss()
            }
            return true
        })
    }
    
    func commitPurposefulAction() {
        if let purposefulAction = self.purposefulAction {
            self.purposefulAction = nil
            purposefulAction()
        }
    }
    
    public override var keyShortcuts: [KeyShortcut] {
        return self.keyShortcutsInternal
    }
    
    public override func joinGroupCall(peerId: PeerId, invite: String?, activeCall: EngineGroupCallDescription) {
        let proceed = {
            super.joinGroupCall(peerId: peerId, invite: invite, activeCall: activeCall)
        }
        
        let _ = self.presentVoiceMessageDiscardAlert(action: {
            proceed()
        })
    }
    
    public func getTransitionInfo(messageId: MessageId, media: Media) -> ((UIView) -> Void, ASDisplayNode, () -> (UIView?, UIView?))? {
        var selectedNode: (ASDisplayNode, CGRect, () -> (UIView?, UIView?))?
        self.chatDisplayNode.historyNode.forEachItemNode { itemNode in
            if let itemNode = itemNode as? ChatMessageItemView {
                if let result = itemNode.transitionNode(id: messageId, media: media, adjustRect: false) {
                    selectedNode = result
                }
            }
        }
        if let (node, _, get) = selectedNode {
            return ({ [weak self] view in
                guard let strongSelf = self else {
                    return
                }
                strongSelf.chatDisplayNode.historyNode.view.superview?.insertSubview(view, aboveSubview: strongSelf.chatDisplayNode.historyNode.view)
            }, node, get)
        } else {
            return nil
        }
    }
    
    func activateInput(type: ChatControllerActivateInput) {
        if self.didAppear {
            switch type {
            case .text:
                self.updateChatPresentationInterfaceState(animated: true, interactive: true, { state in
                    return state.updatedInputMode({ _ in
                        switch type {
                        case .text:
                            return .text
                        case .entityInput:
                            return .media(mode: .other, expanded: nil, focused: false)
                        }
                    })
                })
            case .entityInput:
                self.chatDisplayNode.openStickers(beginWithEmoji: true)
            }
        } else {
            self.scheduledActivateInput = type
        }
    }
    
    func clearInputText() {
        self.updateChatPresentationInterfaceState(animated: true, interactive: true, { state in
            if !state.interfaceState.effectiveInputState.inputText.string.isEmpty {
                return state.updatedInterfaceState { interfaceState in
                    let effectiveInputState = ChatTextInputState(inputText: NSAttributedString(string: ""))
                    return interfaceState.withUpdatedEffectiveInputState(effectiveInputState)
                }
            } else {
                return state
            }
        })
    }
    
    func updateReminderActivity() {
        if self.isReminderActivityEnabled && false {
            if #available(iOS 9.0, *) {
                if self.reminderActivity == nil, case let .peer(peerId) = self.chatLocation, let peer = self.presentationInterfaceState.renderedPeer?.chatMainPeer {
                    let reminderActivity = NSUserActivity(activityType: "RemindAboutChatIntent")
                    self.reminderActivity = reminderActivity
                    if peer is TelegramGroup {
                        reminderActivity.title = self.presentationData.strings.Activity_RemindAboutGroup(EnginePeer(peer).displayTitle(strings: self.presentationData.strings, displayOrder: self.presentationData.nameDisplayOrder)).string
                    } else if let channel = peer as? TelegramChannel {
                        if case .broadcast = channel.info {
                            reminderActivity.title = self.presentationData.strings.Activity_RemindAboutChannel(EnginePeer(peer).displayTitle(strings: self.presentationData.strings, displayOrder: self.presentationData.nameDisplayOrder)).string
                        } else {
                            reminderActivity.title = self.presentationData.strings.Activity_RemindAboutGroup(EnginePeer(peer).displayTitle(strings: self.presentationData.strings, displayOrder: self.presentationData.nameDisplayOrder)).string
                        }
                    } else {
                        reminderActivity.title = self.presentationData.strings.Activity_RemindAboutUser(EnginePeer(peer).displayTitle(strings: self.presentationData.strings, displayOrder: self.presentationData.nameDisplayOrder)).string
                    }
                    reminderActivity.userInfo = ["peerId": peerId.toInt64(), "peerTitle": EnginePeer(peer).displayTitle(strings: self.presentationData.strings, displayOrder: self.presentationData.nameDisplayOrder)]
                    reminderActivity.isEligibleForHandoff = true
                    reminderActivity.becomeCurrent()
                }
            }
        } else if let reminderActivity = self.reminderActivity {
            self.reminderActivity = nil
            reminderActivity.invalidate()
        }
    }
    
    func updateSlowmodeStatus() {
        if let slowmodeState = self.presentationInterfaceState.slowmodeState, case let .timestamp(slowmodeActiveUntilTimestamp) = slowmodeState.variant {
            let timestamp = Int32(Date().timeIntervalSince1970)
            let remainingTime = max(0, slowmodeActiveUntilTimestamp - timestamp)
            if remainingTime == 0 {
                self.updateSlowmodeStatusTimerValue = nil
                self.updateSlowmodeStatusDisposable.set(nil)
                self.updateChatPresentationInterfaceState(interactive: false, {
                    $0.updatedSlowmodeState(nil)
                })
            } else {
                if self.updateSlowmodeStatusTimerValue != slowmodeActiveUntilTimestamp {
                    self.updateSlowmodeStatusTimerValue = slowmodeActiveUntilTimestamp
                    self.updateSlowmodeStatusDisposable.set((Signal<Never, NoError>.complete()
                    |> suspendAwareDelay(Double(remainingTime), granularity: 1.0, queue: .mainQueue())
                    |> deliverOnMainQueue).startStrict(completed: { [weak self] in
                        guard let strongSelf = self else {
                            return
                        }
                        strongSelf.updateSlowmodeStatusTimerValue = nil
                        strongSelf.updateSlowmodeStatus()
                    }))
                }
            }
        } else if let _ = self.updateSlowmodeStatusTimerValue {
            self.updateSlowmodeStatusTimerValue = nil
            self.updateSlowmodeStatusDisposable.set(nil)
        }
    }
    
    func openScheduledMessages() {
        guard let navigationController = self.effectiveNavigationController, navigationController.topViewController == self else {
            return
        }
        let controller = ChatControllerImpl(context: self.context, chatLocation: self.chatLocation, subject: .scheduledMessages)
        controller.navigationPresentation = .modal
        navigationController.pushViewController(controller)
    }
    
    func openPinnedMessages(at messageId: MessageId?) {
        let _ = self.presentVoiceMessageDiscardAlert(action: { [weak self] in
            guard let self, let navigationController = self.effectiveNavigationController, navigationController.topViewController == self else {
                return
            }
            let controller = ChatControllerImpl(context: self.context, chatLocation: self.chatLocation, subject: .pinnedMessages(id: messageId))
            controller.navigationPresentation = .modal
            controller.updatedClosedPinnedMessageId = { [weak self] pinnedMessageId in
                guard let strongSelf = self else {
                    return
                }
                strongSelf.performUpdatedClosedPinnedMessageId(pinnedMessageId: pinnedMessageId)
            }
            controller.requestedUnpinAllMessages = { [weak self] count, pinnedMessageId in
                guard let strongSelf = self else {
                    return
                }
                strongSelf.performRequestedUnpinAllMessages(count: count, pinnedMessageId: pinnedMessageId)
            }
            navigationController.pushViewController(controller)
        })
    }
    
    func performUpdatedClosedPinnedMessageId(pinnedMessageId: MessageId) {
        let previousClosedPinnedMessageId = self.presentationInterfaceState.interfaceState.messageActionsState.closedPinnedMessageId
        
        self.updateChatPresentationInterfaceState(animated: true, interactive: true, {
            return $0.updatedInterfaceState({ $0.withUpdatedMessageActionsState({ value in
                var value = value
                value.closedPinnedMessageId = pinnedMessageId
                return value
            }) })
        })
        
        self.present(
            UndoOverlayController(
                presentationData: self.presentationData,
                content: .messagesUnpinned(
                    title: self.presentationData.strings.Chat_PinnedMessagesHiddenTitle,
                    text: self.presentationData.strings.Chat_PinnedMessagesHiddenText,
                    undo: true,
                    isHidden: true
                ),
                elevatedLayout: false,
                action: { [weak self] action in
                    guard let strongSelf = self else {
                        return true
                    }
                    
                    switch action {
                    case .commit:
                        break
                    case .undo:
                        strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, {
                            return $0.updatedInterfaceState({ $0.withUpdatedMessageActionsState({ value in
                                var value = value
                                value.closedPinnedMessageId = previousClosedPinnedMessageId
                                return value
                            }) })
                        })
                    default:
                        break
                    }
                    return true
                }
            ),
            in: .current
        )
    }
    
    func performRequestedUnpinAllMessages(count: Int, pinnedMessageId: MessageId) {
        guard let peerId = self.chatLocation.peerId else {
            return
        }
        self.chatDisplayNode.historyNode.pendingUnpinnedAllMessages = true
        self.updateChatPresentationInterfaceState(animated: true, interactive: true, {
            return $0.updatedPendingUnpinnedAllMessages(true)
        })
        
        self.present(
            UndoOverlayController(
                presentationData: self.presentationData,
                content: .messagesUnpinned(
                    title: self.presentationData.strings.Chat_MessagesUnpinned(Int32(count)),
                    text: "",
                    undo: true,
                    isHidden: false
                ),
                elevatedLayout: false,
                action: { [weak self] action in
                    guard let strongSelf = self else {
                        return true
                    }
                    
                    switch action {
                    case .commit:
                        let _ = (strongSelf.context.engine.messages.requestUnpinAllMessages(peerId: peerId, threadId: strongSelf.chatLocation.threadId)
                        |> deliverOnMainQueue).startStandalone(error: { _ in
                        }, completed: {
                            guard let strongSelf = self else {
                                return
                            }
                            
                            strongSelf.chatDisplayNode.historyNode.pendingUnpinnedAllMessages = false
                            strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, {
                                return $0.updatedPendingUnpinnedAllMessages(false)
                            })
                        })
                    case .undo:
                        strongSelf.chatDisplayNode.historyNode.pendingUnpinnedAllMessages = false
                        strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, {
                            return $0.updatedPendingUnpinnedAllMessages(false)
                        })
                    default:
                        break
                    }
                    return true
                }
            ),
            in: .current
        )
    }
    
    func presentScheduleTimePicker(style: ChatScheduleTimeControllerStyle = .default, selectedTime: Int32? = nil, dismissByTapOutside: Bool = true, completion: @escaping (Int32) -> Void) {
        guard let peerId = self.chatLocation.peerId else {
            return
        }
        let _ = (self.context.account.viewTracker.peerView(peerId)
        |> take(1)
        |> deliverOnMainQueue).startStandalone(next: { [weak self] peerView in
            guard let strongSelf = self, let peer = peerViewMainPeer(peerView) else {
                return
            }
            var sendWhenOnlineAvailable = false
            if let presence = peerView.peerPresences[peer.id] as? TelegramUserPresence, case .present = presence.status {
                sendWhenOnlineAvailable = true
            }
            if peer.id.namespace == Namespaces.Peer.CloudUser && peer.id.id._internalGetInt64Value() == 777000 {
                sendWhenOnlineAvailable = false
            }
            
            let mode: ChatScheduleTimeControllerMode
            if peerId == strongSelf.context.account.peerId {
                mode = .reminders
            } else {
                mode = .scheduledMessages(sendWhenOnlineAvailable: sendWhenOnlineAvailable)
            }
            let controller = ChatScheduleTimeController(context: strongSelf.context, updatedPresentationData: strongSelf.updatedPresentationData, peerId: peerId, mode: mode, style: style, currentTime: selectedTime, minimalTime: strongSelf.presentationInterfaceState.slowmodeState?.timeout, dismissByTapOutside: dismissByTapOutside, completion: { time in
                completion(time)
            })
            strongSelf.chatDisplayNode.dismissInput()
            strongSelf.present(controller, in: .window(.root))
        })
    }
    
    func presentTimerPicker(style: ChatTimerScreenStyle = .default, selectedTime: Int32? = nil, dismissByTapOutside: Bool = true, completion: @escaping (Int32) -> Void) {
        guard case .peer = self.chatLocation else {
            return
        }
        let controller = ChatTimerScreen(context: self.context, updatedPresentationData: self.updatedPresentationData, style: style, currentTime: selectedTime, dismissByTapOutside: dismissByTapOutside, completion: { time in
            completion(time)
        })
        self.chatDisplayNode.dismissInput()
        self.present(controller, in: .window(.root))
    }
    
    func presentVoiceMessageDiscardAlert(action: @escaping () -> Void = {}, alertAction: (() -> Void)? = nil, delay: Bool = false, performAction: Bool = true) -> Bool {
        if let _ = self.presentationInterfaceState.inputTextPanelState.mediaRecordingState {
            alertAction?()
            Queue.mainQueue().after(delay ? 0.2 : 0.0) {
                self.present(textAlertController(context: self.context, updatedPresentationData: self.updatedPresentationData, title: nil, text: self.presentationData.strings.Conversation_DiscardVoiceMessageDescription, actions: [TextAlertAction(type: .genericAction, title: self.presentationData.strings.Common_Cancel, action: {}), TextAlertAction(type: .defaultAction, title: self.presentationData.strings.Conversation_DiscardVoiceMessageAction, action: { [weak self] in
                    self?.stopMediaRecorder()
                    Queue.mainQueue().after(0.1) {
                        action()
                    }
                })]), in: .window(.root))
            }
            
            return true
        } else if performAction {
            action()
        }
        return false
    }
    
    func presentRecordedVoiceMessageDiscardAlert(action: @escaping () -> Void = {}, alertAction: (() -> Void)? = nil, delay: Bool = false, performAction: Bool = true) -> Bool {
        if let _ = self.presentationInterfaceState.interfaceState.mediaDraftState {
            alertAction?()
            Queue.mainQueue().after(delay ? 0.2 : 0.0) {
                self.present(textAlertController(context: self.context, updatedPresentationData: self.updatedPresentationData, title: nil, text: self.presentationData.strings.Conversation_DiscardRecordedVoiceMessageDescription, actions: [TextAlertAction(type: .genericAction, title: self.presentationData.strings.Common_Cancel, action: {}), TextAlertAction(type: .defaultAction, title: self.presentationData.strings.Conversation_DiscardRecordedVoiceMessageAction, action: { [weak self] in
                    self?.stopMediaRecorder()
                    Queue.mainQueue().after(0.1) {
                        action()
                    }
                })]), in: .window(.root))
            }
            
            return true
        } else if performAction {
            action()
        }
        return false
    }
    
    func presentAutoremoveSetup() {
        guard let peer = self.presentationInterfaceState.renderedPeer?.peer else {
            return
        }
        
        let controller = ChatTimerScreen(context: self.context, updatedPresentationData: self.updatedPresentationData, style: .default, mode: .autoremove, currentTime: self.presentationInterfaceState.autoremoveTimeout, dismissByTapOutside: true, completion: { [weak self] value in
            guard let strongSelf = self else {
                return
            }
            
            let _ = (strongSelf.context.engine.peers.setChatMessageAutoremoveTimeoutInteractively(peerId: peer.id, timeout: value == 0 ? nil : value)
            |> deliverOnMainQueue).startStandalone(completed: {
                guard let strongSelf = self else {
                    return
                }
                
                var isOn: Bool = true
                var text: String?
                if value != 0 {
                    text = strongSelf.presentationData.strings.Conversation_AutoremoveChanged("\(timeIntervalString(strings: strongSelf.presentationData.strings, value: value))").string
                } else {
                    isOn = false
                    text = strongSelf.presentationData.strings.Conversation_AutoremoveOff
                }
                if let text = text {
                    strongSelf.present(UndoOverlayController(presentationData: strongSelf.presentationData, content: .autoDelete(isOn: isOn, title: nil, text: text, customUndoText: nil), elevatedLayout: false, action: { _ in return false }), in: .current)
                }
            })
        })
        self.chatDisplayNode.dismissInput()
        self.present(controller, in: .window(.root))
    }
    
    func presentChatRequestAdminInfo() {
        if let requestChatTitle = self.presentationInterfaceState.contactStatus?.peerStatusSettings?.requestChatTitle, let requestDate = self.presentationInterfaceState.contactStatus?.peerStatusSettings?.requestChatDate {
            let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
            
            let controller = ActionSheetController(presentationData: presentationData)
            var items: [ActionSheetItem] = []
            
            let text = presentationData.strings.Conversation_InviteRequestInfo(requestChatTitle, stringForDate(timestamp: requestDate, strings: presentationData.strings))
            
            items.append(ActionSheetTextItem(title: text.string))
            items.append(ActionSheetButtonItem(title: self.presentationData.strings.Conversation_InviteRequestInfoConfirm, color: .accent, action: { [weak self, weak controller] in
                controller?.dismissAnimated()
                self?.interfaceInteraction?.dismissReportPeer()
            }))
            controller.setItemGroups([ActionSheetItemGroup(items: items), ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: self.presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak controller] in
                    controller?.dismissAnimated()
                })
            ])])
            self.chatDisplayNode.dismissInput()
            self.present(controller, in: .window(.root))
        }
    }
    
    var crossfading = false
    func presentCrossfadeSnapshot() {
        guard !self.crossfading, let snapshotView = self.view.snapshotView(afterScreenUpdates: false) else {
            return
        }
        self.crossfading = true
        self.view.addSubview(snapshotView)

        snapshotView.layer.animateAlpha(from: 1.0, to: 0.0, duration: ChatThemeScreen.themeCrossfadeDuration, delay: ChatThemeScreen.themeCrossfadeDelay, timingFunction: CAMediaTimingFunctionName.linear.rawValue, removeOnCompletion: false, completion: { [weak self, weak snapshotView] _ in
            self?.crossfading = false
            snapshotView?.removeFromSuperview()
        })
    }
    
    public func presentThemeSelection() {
        guard self.themeScreen == nil else {
            return
        }
        let context = self.context
        let peerId = self.chatLocation.peerId
        
        self.updateChatPresentationInterfaceState(animated: true, interactive: true, { state in
            var updated = state
            updated = updated.updatedInputMode({ _ in
                return .none
            })
            updated = updated.updatedShowCommands(false)
            return updated
        })
        
        let animatedEmojiStickers = context.engine.stickers.loadedStickerPack(reference: .animatedEmoji, forceActualized: false)
        |> map { animatedEmoji -> [String: [StickerPackItem]] in
            var animatedEmojiStickers: [String: [StickerPackItem]] = [:]
            switch animatedEmoji {
                case let .result(_, items, _):
                    for item in items {
                        if let emoji = item.getStringRepresentationsOfIndexKeys().first {
                            animatedEmojiStickers[emoji.basicEmoji.0] = [item]
                            let strippedEmoji = emoji.basicEmoji.0.strippedEmoji
                            if animatedEmojiStickers[strippedEmoji] == nil {
                                animatedEmojiStickers[strippedEmoji] = [item]
                            }
                        }
                    }
                default:
                    break
            }
            return animatedEmojiStickers
        }
        
        let _ = (combineLatest(queue: Queue.mainQueue(), self.chatThemeEmoticonPromise.get(), animatedEmojiStickers)
        |> take(1)).startStandalone(next: { [weak self] themeEmoticon, animatedEmojiStickers in
            guard let strongSelf = self, let peer = strongSelf.presentationInterfaceState.renderedPeer?.peer else {
                return
            }
            
            var canResetWallpaper = false
            if let cachedUserData = strongSelf.peerView?.cachedData as? CachedUserData {
                canResetWallpaper = cachedUserData.wallpaper != nil
            }
            
            let controller = ChatThemeScreen(
                context: context,
                updatedPresentationData: strongSelf.updatedPresentationData,
                animatedEmojiStickers: animatedEmojiStickers,
                initiallySelectedEmoticon: themeEmoticon,
                peerName: strongSelf.presentationInterfaceState.renderedPeer?.chatMainPeer.flatMap(EnginePeer.init)?.compactDisplayTitle ?? "",
                canResetWallpaper: canResetWallpaper,
                previewTheme: { [weak self] emoticon, dark in
                    if let strongSelf = self {
                        strongSelf.presentCrossfadeSnapshot()
                        strongSelf.themeEmoticonAndDarkAppearancePreviewPromise.set(.single((emoticon, dark)))
                    }
                },
                changeWallpaper: { [weak self] in
                    guard let strongSelf = self, let peerId else {
                        return
                    }
                    if let themeController = strongSelf.themeScreen {
                        strongSelf.themeScreen = nil
                        themeController.dimTapped()
                    }                    
                    let dismissControllers = { [weak self] in
                        if let self, let navigationController = self.navigationController as? NavigationController {
                            let controllers = navigationController.viewControllers.filter({ controller in
                                if controller is WallpaperGalleryController || controller is AttachmentController {
                                    return false
                                }
                                return true
                            })
                            navigationController.setViewControllers(controllers, animated: true)
                        }
                    }
                    var openWallpaperPickerImpl: ((Bool) -> Void)?
                    let openWallpaperPicker = { [weak self] animateAppearance in
                        guard let strongSelf = self else {
                            return
                        }
                        let controller = wallpaperMediaPickerController(
                            context: strongSelf.context,
                            updatedPresentationData: strongSelf.updatedPresentationData,
                            peer: EnginePeer(peer),
                            animateAppearance: animateAppearance,
                            completion: { [weak self] _, result in
                                guard let strongSelf = self, let asset = result as? PHAsset else {
                                    return
                                }
                                let controller = WallpaperGalleryController(context: strongSelf.context, source: .asset(asset), mode: .peer(EnginePeer(peer), false))
                                controller.navigationPresentation = .modal
                                controller.apply = { [weak self] wallpaper, options, editedImage, cropRect, brightness, forBoth in
                                    if let strongSelf = self {
                                        uploadCustomPeerWallpaper(context: strongSelf.context, wallpaper: wallpaper, mode: options, editedImage: editedImage, cropRect: cropRect, brightness: brightness, peerId: peerId, forBoth: forBoth, completion: {
                                            Queue.mainQueue().after(0.3, {
                                                dismissControllers()
                                            })
                                        })
                                    }
                                }
                                strongSelf.push(controller)
                            },
                            openColors: { [weak self] in
                                guard let strongSelf = self else {
                                    return
                                }
                                let controller = standaloneColorPickerController(context: strongSelf.context, peer: EnginePeer(peer), push: { [weak self] controller in
                                    if let strongSelf = self {
                                        strongSelf.push(controller)
                                    }
                                }, openGallery: {
                                    openWallpaperPickerImpl?(false)
                                })
                                controller.navigationPresentation = .flatModal
                                strongSelf.push(controller)
                            }
                        )
                        controller.navigationPresentation = .flatModal
                        strongSelf.push(controller)
                    }
                    openWallpaperPickerImpl = openWallpaperPicker
                    openWallpaperPicker(true)
                },
                resetWallpaper: { [weak self] in
                    guard let strongSelf = self, let peerId else {
                        return
                    }
                    let _ = strongSelf.context.engine.themes.setChatWallpaper(peerId: peerId, wallpaper: nil, forBoth: false).startStandalone()
                },
                completion: { [weak self] emoticon in
                    guard let strongSelf = self, let peerId else {
                        return
                    }
                    if canResetWallpaper && emoticon != nil {
                        let _ = context.engine.themes.setChatWallpaper(peerId: peerId, wallpaper: nil, forBoth: false).startStandalone()
                    }
                    strongSelf.themeEmoticonAndDarkAppearancePreviewPromise.set(.single((emoticon ?? "", nil)))
                    let _ = context.engine.themes.setChatTheme(peerId: peerId, emoticon: emoticon).startStandalone(completed: { [weak self] in
                        if let strongSelf = self {
                            strongSelf.themeEmoticonAndDarkAppearancePreviewPromise.set(.single((nil, nil)))
                        }
                    })
                }
            )
            controller.navigationPresentation = .flatModal
            controller.passthroughHitTestImpl = { [weak self] _ in
                if let strongSelf = self {
                    return strongSelf.chatDisplayNode.historyNode.view
                } else {
                    return nil
                }
            }
            controller.dismissed = { [weak self] in
                if let strongSelf = self {
                    strongSelf.chatDisplayNode.historyNode.tapped = nil
                }
            }
            strongSelf.chatDisplayNode.historyNode.tapped = { [weak controller] in
                controller?.dimTapped()
            }
            strongSelf.push(controller)
            strongSelf.themeScreen = controller
        })
    }
    
    func presentEmojiList(references: [StickerPackReference]) {
        guard let packReference = references.first else {
            return
        }
        self.chatDisplayNode.dismissTextInput()
        
        let presentationData = self.presentationData
        let controller = StickerPackScreen(context: self.context, updatedPresentationData: self.updatedPresentationData, mainStickerPack: packReference, stickerPacks: Array(references), parentNavigationController: self.effectiveNavigationController, sendEmoji: canSendMessagesToChat(self.presentationInterfaceState) ? { [weak self] text, attribute in
            if let strongSelf = self {
                strongSelf.controllerInteraction?.sendEmoji(text, attribute, false)
            }
        } : nil, actionPerformed: { [weak self] actions in
            guard let strongSelf = self else {
                return
            }
            let context = strongSelf.context
            if actions.count > 1, let first = actions.first {
                if case .add = first.2 {
                    strongSelf.presentInGlobalOverlay(UndoOverlayController(presentationData: presentationData, content: .stickersModified(title: presentationData.strings.EmojiPackActionInfo_AddedTitle, text: presentationData.strings.EmojiPackActionInfo_MultipleAddedText(Int32(actions.count)), undo: false, info: first.0, topItem: first.1.first, context: context), elevatedLayout: true, animateInAsReplacement: false, action: { _ in
                        return true
                    }))
                } else if actions.allSatisfy({
                    if case .remove = $0.2 {
                        return true
                    } else {
                        return false
                    }
                }) {
                    let isEmoji = actions[0].0.id.namespace == Namespaces.ItemCollection.CloudEmojiPacks
                    strongSelf.presentInGlobalOverlay(UndoOverlayController(presentationData: presentationData, content: .stickersModified(title: isEmoji ? presentationData.strings.EmojiPackActionInfo_RemovedTitle : presentationData.strings.StickerPackActionInfo_RemovedTitle, text: isEmoji ? presentationData.strings.EmojiPackActionInfo_MultipleRemovedText(Int32(actions.count)) : presentationData.strings.StickerPackActionInfo_MultipleRemovedText(Int32(actions.count)), undo: true, info: actions[0].0, topItem: actions[0].1.first, context: context), elevatedLayout: true, animateInAsReplacement: false, action: { action in
                        if case .undo = action {
                            var itemsAndIndices: [(StickerPackCollectionInfo, [StickerPackItem], Int)] = actions.compactMap { action -> (StickerPackCollectionInfo, [StickerPackItem], Int)? in
                                if case let .remove(index) = action.2 {
                                    return (action.0, action.1, index)
                                } else {
                                    return nil
                                }
                            }
                            itemsAndIndices.sort(by: { $0.2 < $1.2 })
                            for (info, items, index) in itemsAndIndices.reversed() {
                                let _ = context.engine.stickers.addStickerPackInteractively(info: info, items: items, positionInList: index).startStandalone()
                            }
                        }
                        return true
                    }))
                }
            } else if let (info, items, action) = actions.first {
                let isEmoji = info.id.namespace == Namespaces.ItemCollection.CloudEmojiPacks
                switch action {
                case .add:
                    strongSelf.presentInGlobalOverlay(UndoOverlayController(presentationData: presentationData, content: .stickersModified(title: isEmoji ? presentationData.strings.EmojiPackActionInfo_AddedTitle : presentationData.strings.StickerPackActionInfo_AddedTitle, text: isEmoji ? presentationData.strings.EmojiPackActionInfo_AddedText(info.title).string : presentationData.strings.StickerPackActionInfo_AddedText(info.title).string, undo: false, info: info, topItem: items.first, context: context), elevatedLayout: true, animateInAsReplacement: false, action: { _ in
                        return true
                    }))
                case let .remove(positionInList):
                    strongSelf.presentInGlobalOverlay(UndoOverlayController(presentationData: presentationData, content: .stickersModified(title: isEmoji ? presentationData.strings.EmojiPackActionInfo_RemovedTitle : presentationData.strings.StickerPackActionInfo_RemovedTitle, text: isEmoji ? presentationData.strings.EmojiPackActionInfo_RemovedText(info.title).string : presentationData.strings.StickerPackActionInfo_RemovedText(info.title).string, undo: true, info: info, topItem: items.first, context: context), elevatedLayout: true, animateInAsReplacement: false, action: { action in
                        if case .undo = action {
                            let _ = context.engine.stickers.addStickerPackInteractively(info: info, items: items, positionInList: positionInList).startStandalone()
                        }
                        return true
                    }))
                }
            }
        })
        self.present(controller, in: .window(.root))
    }
    
    public func hintPlayNextOutgoingGift() {
        self.controllerInteraction?.playNextOutgoingGift = true
    }
    
    var effectiveNavigationController: NavigationController? {
        if let navigationController = self.navigationController as? NavigationController {
            return navigationController
        } else if case let .inline(navigationController) = self.presentationInterfaceState.mode {
            return navigationController
        } else if case let .overlay(navigationController) = self.presentationInterfaceState.mode {
            return navigationController
        } else {
            return nil
        }
    }
    
    public func activateSearch(domain: ChatSearchDomain = .everything, query: String = "") {
        self.focusOnSearchAfterAppearance = (domain, query)
        self.interfaceInteraction?.beginMessageSearch(domain, query)
    }
    
    override public func updatePossibleControllerDropContent(content: NavigationControllerDropContent?) {
        //self.chatDisplayNode.updateEmbeddedTitlePeekContent(content: content)
    }
    
    override public func acceptPossibleControllerDropContent(content: NavigationControllerDropContent) -> Bool {
        //return self.chatDisplayNode.acceptEmbeddedTitlePeekContent(content: content)
        return false
    }
    
    public var isSendButtonVisible: Bool {
        if self.presentationInterfaceState.interfaceState.editMessage != nil || self.presentationInterfaceState.interfaceState.forwardMessageIds != nil || self.presentationInterfaceState.interfaceState.composeInputState.inputText.string.count > 0 {
            return true
        } else {
            return false
        }
    }
    
    public func playShakeAnimation() {
        if self.shakeFeedback == nil {
            self.shakeFeedback = HapticFeedback()
        }
        self.shakeFeedback?.error()
        
        self.chatDisplayNode.historyNodeContainer.layer.addShakeAnimation(amplitude: -6.0, decay: true)
    }
    
    public func updatePushedTransition(_ fraction: CGFloat, transition: ContainedViewLayoutTransition) {
        if !transition.isAnimated {
            self.chatDisplayNode.historyNodeContainer.layer.removeAllAnimations()
        }
        let scale: CGFloat = 1.0 - 0.06 * fraction
        transition.updateTransformScale(node: self.chatDisplayNode.historyNodeContainer, scale: scale)
    }
    
    func restrictedSendingContentsText() -> String {
        guard let peer = self.presentationInterfaceState.renderedPeer?.peer else {
            return self.presentationData.strings.Chat_SendNotAllowedText
        }
        
        var itemList: [String] = []
        
        let order: [TelegramChatBannedRightsFlags] = [
            .banSendText,
            .banSendPhotos,
            .banSendVideos,
            .banSendVoice,
            .banSendInstantVideos,
            .banSendFiles,
            .banSendMusic,
            .banSendStickers
        ]
        
        for right in order {
            if let channel = peer as? TelegramChannel {
                if channel.hasBannedPermission(right) != nil {
                    continue
                }
            } else if let group = peer as? TelegramGroup {
                if group.hasBannedPermission(right) {
                    continue
                }
            }
            
            var title: String?
            switch right {
            case .banSendText:
                title = self.presentationData.strings.Chat_SendAllowedContentTypeText
            case .banSendPhotos:
                title = self.presentationData.strings.Chat_SendAllowedContentTypePhoto
            case .banSendVideos:
                title = self.presentationData.strings.Chat_SendAllowedContentTypeVideo
            case .banSendVoice:
                title = self.presentationData.strings.Chat_SendAllowedContentTypeVoiceMessage
            case .banSendInstantVideos:
                title = self.presentationData.strings.Chat_SendAllowedContentTypeVideoMessage
            case .banSendFiles:
                title = self.presentationData.strings.Chat_SendAllowedContentTypeFile
            case .banSendMusic:
                title = self.presentationData.strings.Chat_SendAllowedContentTypeMusic
            case .banSendStickers:
                title = self.presentationData.strings.Chat_SendAllowedContentTypeSticker
            default:
                break
            }
            if let title {
                itemList.append(title)
            }
        }
        
        if itemList.isEmpty {
            return self.presentationData.strings.Chat_SendNotAllowedText
        }
        
        var itemListString = ""
        if #available(iOS 13.0, *) {
            let listFormatter = ListFormatter()
            listFormatter.locale = localeWithStrings(presentationData.strings)
            if let value = listFormatter.string(from: itemList) {
                itemListString = value
            }
        }
        
        if itemListString.isEmpty {
            for i in 0 ..< itemList.count {
                if i != 0 {
                    itemListString.append(", ")
                }
                itemListString.append(itemList[i])
            }
        }
        
        return self.presentationData.strings.Chat_SendAllowedContentText(itemListString).string
    }
    
    func updateNextChannelToReadVisibility() {
        self.chatDisplayNode.historyNode.offerNextChannelToRead = self.offerNextChannelToRead && self.presentationInterfaceState.interfaceState.selectionState == nil
    }
    
    func displayGiveawayStatusInfo(messageId: EngineMessage.Id, giveawayInfo: PremiumGiveawayInfo) {
        presentGiveawayInfoController(context: self.context, updatedPresentationData: self.updatedPresentationData, messageId: messageId, giveawayInfo: giveawayInfo, present: { [weak self] c in
            guard let self else {
                return
            }
            self.present(c, in: .window(.root))
        }, openLink: { [weak self] slug in
            guard let self else {
                return
            }
            self.openResolved(result: .premiumGiftCode(slug: slug), sourceMessageId: messageId)
        })
    }
    
    func openViewOnceMediaMessage(_ message: Message) {
        if self.screenCaptureManager?.isRecordingActive == true {
            let controller = textAlertController(context: self.context, updatedPresentationData: self.updatedPresentationData, title: nil, text: self.presentationData.strings.Chat_PlayOnceMesasge_DisableScreenCapture, actions: [TextAlertAction(type: .defaultAction, title: self.presentationData.strings.Common_OK, action: {
            })])
            self.present(controller, in: .window(.root))
            return
        }
        
        let isIncoming = message.effectivelyIncoming(self.context.account.peerId)
        
        var presentImpl: ((ViewController) -> Void)?
        let configuration = ContextController.Configuration(
            sources: [
                ContextController.Source(
                    id: 0,
                    title: "",
                    source: .extracted(ChatViewOnceMessageContextExtractedContentSource(
                        context: self.context,
                        presentationData: self.presentationData,
                        chatNode: self.chatDisplayNode,
                        backgroundNode: self.chatBackgroundNode,
                        engine: self.context.engine,
                        message: message,
                        present: { c in
                            presentImpl?(c)
                        }
                    )),
                    items: .single(ContextController.Items(content: .list([]))),
                    closeActionTitle: isIncoming ? self.presentationData.strings.Chat_PlayOnceMesasgeCloseAndDelete : self.presentationData.strings.Chat_PlayOnceMesasgeClose,
                    closeAction: { [weak self] in
                        if let self {
                            self.context.sharedContext.mediaManager.setPlaylist(nil, type: .voice, control: .playback(.pause))
                        }
                    }
                )
            ], initialId: 0
        )
        
        let contextController = ContextController(presentationData: self.presentationData, configuration: configuration)
        contextController.getOverlayViews = { [weak self] in
            guard let self else {
                return []
            }
            return [self.chatDisplayNode.navigateButtons.view]
        }
        self.currentContextController = contextController
        self.presentInGlobalOverlay(contextController)
        
        presentImpl = { [weak contextController] c in
            contextController?.present(c, in: .current)
        }
        
        let _ = self.context.sharedContext.openChatMessage(OpenChatMessageParams(context: self.context, chatLocation: nil, chatLocationContextHolder: nil, message: message, standalone: false, reverseMessageGalleryOrder: false, navigationController: nil, dismissInput: { }, present: { _, _ in }, transitionNode: { _, _, _ in return nil }, addToTransitionSurface: { _ in }, openUrl: { _ in }, openPeer: { _, _ in }, callPeer: { _, _ in }, enqueueMessage: { _ in }, sendSticker: nil, sendEmoji: nil, setupTemporaryHiddenMedia: { _, _, _ in }, chatAvatarHiddenMedia: { _, _ in }, playlistLocation: .singleMessage(message.id)))
    }
    
    func openStorySharing(messages: [Message]) {
        let context = self.context
        let subject: Signal<MediaEditorScreen.Subject?, NoError> = .single(.message(messages.map { $0.id }))
        
        let externalState = MediaEditorTransitionOutExternalState(
            storyTarget: nil,
            isPeerArchived: false,
            transitionOut: nil
        )
        
        let controller = MediaEditorScreen(
            context: context,
            subject: subject,
            transitionIn: nil,
            transitionOut: { _, _ in
                return nil
            },
            completion: { [weak self] result, commit in
                guard let self else {
                    return
                }
                let targetPeerId: EnginePeer.Id
                let target: Stories.PendingTarget
                if let sendAsPeerId = result.options.sendAsPeerId {
                    target = .peer(sendAsPeerId)
                    targetPeerId = sendAsPeerId
                } else {
                    target = .myStories
                    targetPeerId = self.context.account.peerId
                }
                externalState.storyTarget = target
                
                if let rootController = context.sharedContext.mainWindow?.viewController as? TelegramRootControllerInterface {
                    rootController.proceedWithStoryUpload(target: target, result: result, existingMedia: nil, forwardInfo: nil, externalState: externalState, commit: commit)
                }
                
                let _ = (self.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: targetPeerId))
                |> deliverOnMainQueue).start(next: { [weak self] peer in
                    guard let self, let peer else {
                        return
                    }
                    let text: String
                    if case .channel = peer {
                        text = self.presentationData.strings.Story_MessageReposted_Channel(peer.compactDisplayTitle).string
                    } else {
                        text = self.presentationData.strings.Story_MessageReposted_Personal
                    }
                    Queue.mainQueue().after(0.25) {
                        self.present(UndoOverlayController(
                            presentationData: self.presentationData,
                            content: .forward(savedMessages: false, text: text),
                            elevatedLayout: false,
                            action: { _ in return false }
                        ), in: .current)
                        
                        Queue.mainQueue().after(0.1) {
                            self.chatDisplayNode.hapticFeedback.success()
                        }
                    }
                })

            }
        )
        self.push(controller)
    }
    
    public func transferScrollingVelocity(_ velocity: CGFloat) {
        self.chatDisplayNode.historyNode.transferVelocity(velocity)
    }
    
    public func performScrollToTop() -> Bool {
        let offset = self.chatDisplayNode.historyNode.visibleContentOffset()
        switch offset {
        case let .known(value) where value <= CGFloat.ulpOfOne:
            return false
        default:
            self.chatDisplayNode.historyNode.scrollToEndOfHistory()
            return true
        }
    }
}

final class ChatContextControllerContentSourceImpl: ContextControllerContentSource {
    let controller: ViewController
    weak var sourceNode: ASDisplayNode?
    weak var sourceView: UIView?
    let sourceRect: CGRect?
    
    let navigationController: NavigationController? = nil

    let passthroughTouches: Bool
    
    init(controller: ViewController, sourceNode: ASDisplayNode?, sourceRect: CGRect? = nil, passthroughTouches: Bool) {
        self.controller = controller
        self.sourceNode = sourceNode
        self.sourceRect = sourceRect
        self.passthroughTouches = passthroughTouches
    }
    
    init(controller: ViewController, sourceView: UIView?, sourceRect: CGRect? = nil, passthroughTouches: Bool) {
        self.controller = controller
        self.sourceView = sourceView
        self.sourceRect = sourceRect
        self.passthroughTouches = passthroughTouches
    }
    
    func transitionInfo() -> ContextControllerTakeControllerInfo? {
        let sourceView = self.sourceView
        let sourceNode = self.sourceNode
        let sourceRect = self.sourceRect
        return ContextControllerTakeControllerInfo(contentAreaInScreenSpace: CGRect(origin: CGPoint(), size: CGSize(width: 10.0, height: 10.0)), sourceNode: { [weak sourceNode] in
            if let sourceView = sourceView {
                return (sourceView, sourceRect ?? sourceView.bounds)
            } else if let sourceNode = sourceNode {
                return (sourceNode.view, sourceRect ?? sourceNode.bounds)
            } else {
                return nil
            }
        })
    }
    
    func animatedIn() {
    }
}

final class ChatControllerContextReferenceContentSource: ContextReferenceContentSource {
    let controller: ViewController
    let sourceView: UIView
    let insets: UIEdgeInsets
    let contentInsets: UIEdgeInsets
    
    init(controller: ViewController, sourceView: UIView, insets: UIEdgeInsets, contentInsets: UIEdgeInsets = UIEdgeInsets()) {
        self.controller = controller
        self.sourceView = sourceView
        self.insets = insets
        self.contentInsets = contentInsets
    }
    
    func transitionInfo() -> ContextControllerReferenceViewInfo? {
        return ContextControllerReferenceViewInfo(referenceView: self.sourceView, contentAreaInScreenSpace: UIScreen.main.bounds.inset(by: self.insets), insets: self.contentInsets)
    }
}

enum AllowedReactions {
    case set(Set<MessageReaction.Reaction>)
    case all
}

func peerMessageAllowedReactions(context: AccountContext, message: Message) -> Signal<AllowedReactions?, NoError> {
    if message.id.peerId == context.account.peerId {
        return .single(.all)
    }
    
    if message.containsSecretMedia {
        return .single(AllowedReactions.set(Set()))
    }
    
    return combineLatest(
        context.engine.data.get(
            TelegramEngine.EngineData.Item.Peer.Peer(id: message.id.peerId),
            TelegramEngine.EngineData.Item.Peer.AllowedReactions(id: message.id.peerId)
        ),
        context.engine.stickers.availableReactions() |> take(1)
    )
    |> map { data, availableReactions -> AllowedReactions? in
        let (peer, allowedReactions) = data
        
        if let effectiveReactions = message.effectiveReactions(isTags: message.areReactionsTags(accountPeerId: context.account.peerId)), effectiveReactions.count >= 11 {
            return .set(Set(effectiveReactions.map(\.value)))
        }
        
        switch allowedReactions {
        case .unknown:
            if case let .channel(channel) = peer, case .broadcast = channel.info {
                if let availableReactions = availableReactions {
                    return .set(Set(availableReactions.reactions.map(\.value)))
                } else {
                    return .set(Set())
                }
            }
            return .all
        case let .known(value):
            switch value {
            case .all:
                if case let .channel(channel) = peer, case .broadcast = channel.info {
                    if let availableReactions = availableReactions {
                        return .set(Set(availableReactions.reactions.map(\.value)))
                    } else {
                        return .set(Set())
                    }
                }
                return .all
            case let .limited(reactions):
                return .set(Set(reactions))
            case .empty:
                return .set(Set())
            }
        }
    }
}

func peerMessageSelectedReactions(context: AccountContext, message: Message) -> Signal<(reactions: Set<MessageReaction.Reaction>, files: Set<MediaId>), NoError> {
    return context.engine.stickers.availableReactions()
    |> take(1)
    |> map { availableReactions -> (reactions: Set<MessageReaction.Reaction>, files: Set<MediaId>) in
        var result = Set<MediaId>()
        var reactions = Set<MessageReaction.Reaction>()
        
        if let effectiveReactions = message.effectiveReactions(isTags: message.areReactionsTags(accountPeerId: context.account.peerId)) {
            for reaction in effectiveReactions {
                if !reaction.isSelected {
                    continue
                }
                reactions.insert(reaction.value)
                switch reaction.value {
                case .builtin:
                    if let availableReaction = availableReactions?.reactions.first(where: { $0.value == reaction.value }) {
                        result.insert(availableReaction.selectAnimation.fileId)
                    }
                case let .custom(fileId):
                    result.insert(MediaId(namespace: Namespaces.Media.CloudFile, id: fileId))
                }
            }
        }
        
        return (reactions, result)
    }
}
