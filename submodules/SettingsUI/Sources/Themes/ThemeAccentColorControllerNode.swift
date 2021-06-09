import Foundation
import UIKit
import Display
import Postbox
import SwiftSignalKit
import AsyncDisplayKit
import TelegramCore
import SyncCore
import TelegramPresentationData
import TelegramUIPreferences
import ChatListUI
import AccountContext
import WallpaperResources
import PresentationDataUtils
import WallpaperBackgroundNode

private func generateMaskImage(color: UIColor) -> UIImage? {
    return generateImage(CGSize(width: 1.0, height: 80.0), opaque: false, rotatedContext: { size, context in
        let bounds = CGRect(origin: CGPoint(), size: size)
        context.clear(bounds)
        
        let gradientColors = [color.withAlphaComponent(0.0).cgColor, color.cgColor, color.cgColor] as CFArray
        
        var locations: [CGFloat] = [0.0, 0.75, 1.0]
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: &locations)!
        
        context.drawLinearGradient(gradient, start: CGPoint(x: 0.0, y: 0.0), end: CGPoint(x: 0.0, y: 80.0), options: CGGradientDrawingOptions())
    })
}
 
enum ThemeColorSection: Int {
    case background
    case accent
    case messages
}

struct ThemeColorState {
    fileprivate var section: ThemeColorSection?
    fileprivate var colorPanelCollapsed: Bool
    fileprivate var displayPatternPanel: Bool
    
    var accentColor: UIColor
    var initialWallpaper: TelegramWallpaper?
    var backgroundColors: [UInt32]
    
    fileprivate var preview: Bool
    fileprivate var previousPatternWallpaper: TelegramWallpaper?
    var patternWallpaper: TelegramWallpaper?
    var patternIntensity: Int32
    
    var defaultMessagesColor: UIColor?
    var messagesColors: (UIColor, UIColor?)?
    
    var rotation: Int32
    
    init() {
        self.section = nil
        self.colorPanelCollapsed = false
        self.displayPatternPanel = false
        self.accentColor = .clear
        self.initialWallpaper = nil
        self.backgroundColors = []
        self.preview = false
        self.previousPatternWallpaper = nil
        self.patternWallpaper = nil
        self.patternIntensity = 50
        self.defaultMessagesColor = nil
        self.messagesColors = nil
        self.rotation = 0
    }
    
    init(section: ThemeColorSection, accentColor: UIColor, initialWallpaper: TelegramWallpaper?, backgroundColors: [UInt32], patternWallpaper: TelegramWallpaper?, patternIntensity: Int32, defaultMessagesColor: UIColor?, messagesColors: (UIColor, UIColor?)?, rotation: Int32 = 0) {
        self.section = section
        self.colorPanelCollapsed = false
        self.displayPatternPanel = false
        self.accentColor = accentColor
        self.initialWallpaper = initialWallpaper
        self.backgroundColors = backgroundColors
        self.preview = false
        self.previousPatternWallpaper = nil
        self.patternWallpaper = patternWallpaper
        self.patternIntensity = patternIntensity
        self.defaultMessagesColor = defaultMessagesColor
        self.messagesColors = messagesColors
        self.rotation = rotation
    }
    
    func isEqual(to otherState: ThemeColorState) -> Bool {
        if self.accentColor != otherState.accentColor {
            return false
        }
        if self.preview != otherState.preview {
            return false
        }
        if self.patternWallpaper != otherState.patternWallpaper {
            return false
        }
        if self.patternIntensity != otherState.patternIntensity {
            return false
        }
        if self.rotation != otherState.rotation {
            return false
        }
        if self.backgroundColors != otherState.backgroundColors {
            return false
        }

        if let lhsMessagesColors = self.messagesColors, let rhsMessagesColors = otherState.messagesColors {
            if lhsMessagesColors.0 != rhsMessagesColors.0 {
                return false
            }
            if let lhsSecondColor = lhsMessagesColors.1, let rhsSecondColor = rhsMessagesColors.1 {
                if lhsSecondColor != rhsSecondColor {
                    return false
                }
            } else if (lhsMessagesColors.1 == nil) != (rhsMessagesColors.1 == nil) {
                return false
            }
        } else if (self.messagesColors == nil) != (otherState.messagesColors == nil) {
            return false
        }
        return true
    }
}

private func calcPatternColors(for state: ThemeColorState) -> [UIColor] {
    if state.backgroundColors.count >= 1 {
        let patternIntensity = CGFloat(state.patternIntensity) / 100.0
        let topPatternColor = UIColor(rgb: state.backgroundColors[0]).withAlphaComponent(patternIntensity)
        if state.backgroundColors.count >= 2 {
            let bottomPatternColor = UIColor(rgb: state.backgroundColors[1]).withAlphaComponent(patternIntensity)
            return [topPatternColor, bottomPatternColor]
        } else {
            return [topPatternColor, topPatternColor]
        }
    } else {
        let patternColor = UIColor(rgb: 0xd6e2ee, alpha: 0.5)
        return [patternColor, patternColor]
    }
}

final class ThemeAccentColorControllerNode: ASDisplayNode, UIScrollViewDelegate {
    private let context: AccountContext
    private var theme: PresentationTheme
    private let mode: ThemeAccentColorControllerMode
    private var presentationData: PresentationData
    
    private let ready: Promise<Bool>
    
    private let queue = Queue()
    
    private var state: ThemeColorState
    private let referenceTimestamp: Int32
    
    private let scrollNode: ASScrollNode
    private let pageControlBackgroundNode: ASDisplayNode
    private let pageControlNode: PageControlNode

    private var patternButtonNode: WallpaperOptionButtonNode
    private var colorsButtonNode: WallpaperOptionButtonNode

    private var playButtonNode: HighlightableButtonNode
    private let playButtonBackgroundNode: NavigationBackgroundNode
    private let playButtonPlayImage: UIImage?
    private let playButtonRotateImage: UIImage?

    private let chatListBackgroundNode: ASDisplayNode
    private var chatNodes: [ListViewItemNode]?
    private let maskNode: ASImageNode
    private let backgroundContainerNode: ASDisplayNode
    private let backgroundWrapperNode: ASDisplayNode
    private let backgroundNode: WallpaperBackgroundNode
    private let messagesContainerNode: ASDisplayNode
    private var dateHeaderNode: ListViewItemHeaderNode?
    private var messageNodes: [ListViewItemNode]?
    private let colorPanelNode: WallpaperColorPanelNode
    private let patternPanelNode: WallpaperPatternPanelNode
    private let toolbarNode: WallpaperGalleryToolbarNode
    
    private var serviceColorDisposable: Disposable?
    private var stateDisposable: Disposable?
    private let statePromise = Promise<ThemeColorState>()
    private let themePromise = Promise<PresentationTheme>()
    private var wallpaper: TelegramWallpaper
    private var serviceBackgroundColor: UIColor?
    private let serviceBackgroundColorPromise = Promise<UIColor>()
    private var wallpaperDisposable = MetaDisposable()
    
    private var currentBackgroundColors: ([UInt32], Int32?, Int32?)?
    private var currentBackgroundPromise = Promise<(UIColor, UIColor?)?>()
    
    private var patternWallpaper: TelegramWallpaper?
    private var patternArguments: PatternWallpaperArguments?
    private var patternArgumentsPromise = Promise<TransformImageArguments>()
    private var patternArgumentsDisposable: Disposable?
    
    var themeUpdated: ((PresentationTheme) -> Void)?
    var requestSectionUpdate: ((ThemeColorSection) -> Void)?
    
    var dismissed = false
    
    private var validLayout: (ContainerViewLayout, CGFloat, CGFloat)?
    
    var requiresWallpaperChange: Bool {
        switch self.wallpaper {
            case .image, .builtin:
                return true
            case let .file(file):
                return !self.wallpaper.isPattern
            default:
                return false
        }
    }
    
    init(context: AccountContext, mode: ThemeAccentColorControllerMode, theme: PresentationTheme, wallpaper: TelegramWallpaper, dismiss: @escaping () -> Void, apply: @escaping (ThemeColorState, UIColor?) -> Void, ready: Promise<Bool>) {
        self.context = context
        self.mode = mode
        self.state = ThemeColorState()
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        self.theme = theme
        self.wallpaper = self.presentationData.chatWallpaper
        let bubbleCorners = self.presentationData.chatBubbleCorners
        
        self.ready = ready
        
        let calendar = Calendar(identifier: .gregorian)
        var components = calendar.dateComponents(Set([.era, .year, .month, .day, .hour, .minute, .second]), from: Date())
        components.hour = 13
        components.minute = 0
        components.second = 0
        self.referenceTimestamp = Int32(calendar.date(from: components)?.timeIntervalSince1970 ?? 0.0)
        
        self.scrollNode = ASScrollNode()
        self.pageControlBackgroundNode = ASDisplayNode()
        self.pageControlBackgroundNode.backgroundColor = UIColor(rgb: 0x000000, alpha: 0.3)
        self.pageControlBackgroundNode.cornerRadius = 10.5
        
        self.pageControlNode = PageControlNode(dotSpacing: 7.0, dotColor: .white, inactiveDotColor: UIColor.white.withAlphaComponent(0.4))

        self.patternButtonNode = WallpaperOptionButtonNode(title: self.presentationData.strings.WallpaperPreview_Pattern, value: .check(false))
        self.colorsButtonNode = WallpaperOptionButtonNode(title: self.presentationData.strings.WallpaperPreview_WallpaperColors, value: .colors(false, []))

        self.playButtonBackgroundNode = NavigationBackgroundNode(color: UIColor(white: 0.0, alpha: 0.3))
        self.playButtonNode = HighlightableButtonNode()
        self.playButtonNode.insertSubnode(self.playButtonBackgroundNode, at: 0)

        self.playButtonPlayImage = generateImage(CGSize(width: 48.0, height: 48.0), rotatedContext: { size, context in
            context.clear(CGRect(origin: CGPoint(), size: size))
            context.setFillColor(UIColor.white.cgColor)

            let diameter = size.width

            let factor = diameter / 50.0

            let size = CGSize(width: 15.0, height: 18.0)
            context.translateBy(x: (diameter - size.width) / 2.0 + 1.5, y: (diameter - size.height) / 2.0)
            if (diameter < 40.0) {
                context.translateBy(x: size.width / 2.0, y: size.height / 2.0)
                context.scaleBy(x: factor, y: factor)
                context.translateBy(x: -size.width / 2.0, y: -size.height / 2.0)
            }
            let _ = try? drawSvgPath(context, path: "M1.71891969,0.209353049 C0.769586558,-0.350676705 0,0.0908839327 0,1.18800046 L0,16.8564753 C0,17.9569971 0.750549162,18.357187 1.67393713,17.7519379 L14.1073836,9.60224049 C15.0318735,8.99626906 15.0094718,8.04970371 14.062401,7.49100858 L1.71891969,0.209353049 ")
            context.fillPath()
            if (diameter < 40.0) {
                context.translateBy(x: size.width / 2.0, y: size.height / 2.0)
                context.scaleBy(x: 1.0 / 0.8, y: 1.0 / 0.8)
                context.translateBy(x: -size.width / 2.0, y: -size.height / 2.0)
            }
            context.translateBy(x: -(diameter - size.width) / 2.0 - 1.5, y: -(diameter - size.height) / 2.0)
        })

        self.playButtonRotateImage = generateTintedImage(image: UIImage(bundleImageName: "Settings/ThemeColorRotateIcon"), color: .white)

        self.playButtonNode.setImage(self.playButtonPlayImage, for: [])
        
        self.chatListBackgroundNode = ASDisplayNode()
        
        self.backgroundContainerNode = ASDisplayNode()
        self.backgroundContainerNode.clipsToBounds = true
        self.backgroundWrapperNode = ASDisplayNode()
        self.backgroundNode = WallpaperBackgroundNode(context: context)
        
        self.messagesContainerNode = ASDisplayNode()
        self.messagesContainerNode.clipsToBounds = true
        self.messagesContainerNode.transform = CATransform3DMakeScale(-1.0, -1.0, 1.0)
        
        self.colorPanelNode = WallpaperColorPanelNode(theme: self.theme, strings: self.presentationData.strings)
        self.patternPanelNode = WallpaperPatternPanelNode(context: self.context, theme: self.theme, strings: self.presentationData.strings)
        
        let doneButtonType: WallpaperGalleryToolbarDoneButtonType
        if case .edit(_, _, _, _, true, _) = self.mode {
            doneButtonType = .proceed
        } else {
            doneButtonType = .set
        }
        self.toolbarNode = WallpaperGalleryToolbarNode(theme: self.theme, strings: self.presentationData.strings, doneButtonType: doneButtonType)
        
        self.maskNode = ASImageNode()
        self.maskNode.displaysAsynchronously = false
        self.maskNode.displayWithoutProcessing = true
        self.maskNode.contentMode = .scaleToFill
        
        super.init()
        
        self.setViewBlock({
            return UITracingLayerView()
        })
        
        self.backgroundColor = self.presentationData.theme.list.plainBackgroundColor
        self.chatListBackgroundNode.backgroundColor = self.presentationData.theme.chatList.backgroundColor
        
        self.pageControlNode.isUserInteractionEnabled = false
        self.pageControlNode.pagesCount = 2
        
        self.addSubnode(self.scrollNode)
        self.chatListBackgroundNode.addSubnode(self.maskNode)
        self.addSubnode(self.pageControlBackgroundNode)
        self.addSubnode(self.pageControlNode)
        self.addSubnode(self.patternButtonNode)
        self.addSubnode(self.colorsButtonNode)
        self.addSubnode(self.playButtonNode)
        self.addSubnode(self.colorPanelNode)
        self.addSubnode(self.patternPanelNode)
        self.addSubnode(self.toolbarNode)
        
        self.scrollNode.addSubnode(self.chatListBackgroundNode)
        self.scrollNode.addSubnode(self.backgroundContainerNode)
        self.scrollNode.addSubnode(self.messagesContainerNode)
        
        self.backgroundContainerNode.addSubnode(self.backgroundWrapperNode)
        self.backgroundWrapperNode.addSubnode(self.backgroundNode)

        self.patternButtonNode.addTarget(self, action: #selector(self.togglePattern), forControlEvents: .touchUpInside)
        self.colorsButtonNode.addTarget(self, action: #selector(self.toggleColors), forControlEvents: .touchUpInside)
        self.playButtonNode.addTarget(self, action: #selector(self.playPressed), forControlEvents: .touchUpInside)
        
        self.colorPanelNode.colorsChanged = { [weak self] colors, ended in
            if let strongSelf = self, let section = strongSelf.state.section {
                strongSelf.updateState({ current in
                    var updated = current
                    updated.preview = !ended
                    switch section {
                        case .accent:
                            if let firstColor = colors.first {
                                updated.accentColor = UIColor(rgb: firstColor)
                            }
                        case .background:
                            updated.backgroundColors = colors
                        case .messages:
                            if colors.count >= 1 {
                                updated.messagesColors = (UIColor(rgb: colors[0]), colors.count >= 2 ? UIColor(rgb: colors[1]) : nil)
                            } else {
                                updated.messagesColors = nil
                            }
                    }
                    return updated
                })
            }
        }
        
        self.colorPanelNode.colorSelected = { [weak self] in
            if let strongSelf = self, strongSelf.state.colorPanelCollapsed {
                strongSelf.updateState({ current in
                    var updated = current
                    updated.colorPanelCollapsed = false
                    return updated
                }, animated: true)
            }
        }
        
        self.colorPanelNode.rotate = { [weak self] in
            if let strongSelf = self {
                strongSelf.updateState({ current in
                    var updated = current
                    var newRotation = updated.rotation + 45
                    if newRotation >= 360 {
                        newRotation = 0
                    }
                    updated.rotation = newRotation
                    return updated
                }, animated: true)
            }
        }
        
        self.patternPanelNode.patternChanged = { [weak self] wallpaper, intensity, preview in
            if let strongSelf = self {
                strongSelf.updateState({ current in
                    var updated = current
                    updated.patternWallpaper = wallpaper
                    updated.patternIntensity = intensity ?? 50
                    updated.preview = preview
                    return updated
                }, animated: true)
            }
        }
        
        self.toolbarNode.cancel = { [weak self] in
            if let strongSelf =  self {
                if strongSelf.state.displayPatternPanel {
                    strongSelf.updateState({ current in
                        var updated = current
                        updated.displayPatternPanel = false
                        updated.patternWallpaper = nil
                        return updated
                    }, animated: true)
                } else {
                    dismiss()
                }
            }
        }
        
        self.toolbarNode.done = { [weak self] in
            if let strongSelf = self {
                if strongSelf.state.displayPatternPanel {
                    strongSelf.updateState({ current in
                        var updated = current
                        updated.displayPatternPanel = false
                        return updated
                    }, animated: true)
                } else {
                    if !strongSelf.dismissed {
                        strongSelf.dismissed = true
                        apply(strongSelf.state, strongSelf.serviceBackgroundColor)
                    }
                }
            }
        }

        self.backgroundNode.update(wallpaper: self.wallpaper)
        self.backgroundNode.updateBubbleTheme(bubbleTheme: self.theme, bubbleCorners: self.presentationData.chatBubbleCorners)

        self.stateDisposable = (self.statePromise.get()
        |> deliverOn(self.queue)
        |> mapToThrottled { next -> Signal<ThemeColorState, NoError> in
            return .single(next) |> then(.complete() |> delay(0.0166667, queue: self.queue))
        }
        |> map { state -> (PresentationTheme?, TelegramWallpaper, UIColor, [UInt32], Int32, PatternWallpaperArguments, Bool) in
            let accentColor = state.accentColor
            var backgroundColors = state.backgroundColors
            let messagesColors = state.messagesColors

            var wallpaper: TelegramWallpaper

            var updateOnlyWallpaper = false
            if state.section == .background && state.preview {
                updateOnlyWallpaper = true
            }

            if !backgroundColors.isEmpty {
                if let patternWallpaper = state.patternWallpaper, case let .file(file) = patternWallpaper {
                    wallpaper = patternWallpaper.withUpdatedSettings(WallpaperSettings(colors: backgroundColors, intensity: state.patternIntensity, rotation: state.rotation))

                    let dimensions = file.file.dimensions ?? PixelDimensions(width: 100, height: 100)
                    var convertedRepresentations: [ImageRepresentationWithReference] = []
                    for representation in file.file.previewRepresentations {
                        convertedRepresentations.append(ImageRepresentationWithReference(representation: representation, reference: .wallpaper(wallpaper: .slug(file.slug), resource: representation.resource)))
                    }
                    convertedRepresentations.append(ImageRepresentationWithReference(representation: .init(dimensions: dimensions, resource: file.file.resource, progressiveSizes: [], immediateThumbnailData: nil), reference: .wallpaper(wallpaper: .slug(file.slug), resource: file.file.resource)))
                } else if backgroundColors.count >= 2 {
                    wallpaper = .gradient(backgroundColors, WallpaperSettings(rotation: state.rotation))
                } else {
                    wallpaper = .color(backgroundColors.first ?? 0xffffff)
                }
            } else if let themeReference = mode.themeReference, case let .builtin(theme) = themeReference, state.initialWallpaper == nil {
                var suggestedWallpaper: TelegramWallpaper
                switch theme {
                    case .dayClassic:
                        let topColor = accentColor.withMultiplied(hue: 1.010, saturation: 0.414, brightness: 0.957)
                        let bottomColor = accentColor.withMultiplied(hue: 1.019, saturation: 0.867, brightness: 0.965)
                        suggestedWallpaper = .gradient([topColor.rgb, bottomColor.rgb], WallpaperSettings())
                        backgroundColors = [topColor.rgb, bottomColor.rgb]
                    case .nightAccent:
                        let color = accentColor.withMultiplied(hue: 1.024, saturation: 0.573, brightness: 0.18)
                        suggestedWallpaper = .color(color.rgb)
                        backgroundColors = [color.rgb]
                    default:
                        suggestedWallpaper = .builtin(WallpaperSettings())
                }
                wallpaper = suggestedWallpaper
            } else {
                wallpaper = state.initialWallpaper ?? .builtin(WallpaperSettings())
            }

            let serviceBackgroundColor = serviceColor(for: (wallpaper, nil))
            let updatedTheme: PresentationTheme?

            if !updateOnlyWallpaper {
                if let themeReference = mode.themeReference {
                    updatedTheme = makePresentationTheme(mediaBox: context.sharedContext.accountManager.mediaBox, themeReference: themeReference, accentColor: accentColor, backgroundColors: backgroundColors, bubbleColors: messagesColors, serviceBackgroundColor: serviceBackgroundColor, preview: true) ?? defaultPresentationTheme
                } else if case let .edit(theme, _, _, _, _, _) = mode {
                    updatedTheme = customizePresentationTheme(theme, editing: false, accentColor: accentColor, backgroundColors: backgroundColors, bubbleColors: messagesColors)
                } else {
                    updatedTheme = theme
                }

                let _ = PresentationResourcesChat.principalGraphics(theme: updatedTheme!, wallpaper: wallpaper, bubbleCorners: bubbleCorners)
            } else {
                updatedTheme = nil
            }

            let patternArguments = PatternWallpaperArguments(colors: calcPatternColors(for: state), rotation: wallpaper.settings?.rotation ?? 0, preview: state.preview)

            return (updatedTheme, wallpaper, serviceBackgroundColor, backgroundColors, state.rotation, patternArguments, state.preview)
        }
        |> deliverOnMainQueue).start(next: { [weak self] theme, wallpaper, serviceBackgroundColor, backgroundColors, rotation, patternArguments, preview in
            guard let strongSelf = self else {
                return
            }

            if let theme = theme {
                strongSelf.theme = theme
                strongSelf.themeUpdated?(theme)
                strongSelf.themePromise.set(.single(theme))
                strongSelf.colorPanelNode.updateTheme(theme)
                strongSelf.toolbarNode.updateThemeAndStrings(theme: theme, strings: strongSelf.presentationData.strings)
                strongSelf.chatListBackgroundNode.backgroundColor = theme.chatList.backgroundColor
                strongSelf.maskNode.image = generateMaskImage(color: theme.chatList.backgroundColor)

                strongSelf.backgroundNode.updateBubbleTheme(bubbleTheme: theme, bubbleCorners: strongSelf.presentationData.chatBubbleCorners)
            }

            strongSelf.serviceBackgroundColor = serviceBackgroundColor
            strongSelf.serviceBackgroundColorPromise.set(.single(serviceBackgroundColor))

            strongSelf.backgroundNode.update(wallpaper: wallpaper)
            strongSelf.backgroundNode.updateBubbleTheme(bubbleTheme: strongSelf.theme, bubbleCorners: strongSelf.presentationData.chatBubbleCorners)

            strongSelf.ready.set(.single(true))

            strongSelf.wallpaper = wallpaper
            strongSelf.patternArguments = patternArguments

            strongSelf.colorsButtonNode.colors = backgroundColors.map(UIColor.init(rgb:))

            if !preview {
                if !backgroundColors.isEmpty {
                    strongSelf.currentBackgroundColors = (backgroundColors, strongSelf.state.rotation, strongSelf.state.patternIntensity)
                } else {
                    strongSelf.currentBackgroundColors = nil
                }
                strongSelf.patternPanelNode.backgroundColors = strongSelf.currentBackgroundColors
            } else {
                let previousIntensity = strongSelf.patternPanelNode.backgroundColors?.2
                let updatedIntensity = strongSelf.state.patternIntensity
                if let previousIntensity = previousIntensity {
                    if (previousIntensity < 0) != (updatedIntensity < 0) {
                        if !backgroundColors.isEmpty {
                            strongSelf.currentBackgroundColors = (backgroundColors, strongSelf.state.rotation, strongSelf.state.patternIntensity)
                        } else {
                            strongSelf.currentBackgroundColors = nil
                        }
                        strongSelf.patternPanelNode.backgroundColors = strongSelf.currentBackgroundColors
                    }
                }
            }

            if let _ = theme, let (layout, navigationBarHeight, messagesBottomInset) = strongSelf.validLayout {
                strongSelf.updateChatsLayout(layout: layout, topInset: navigationBarHeight, transition: .immediate)
                strongSelf.updateMessagesLayout(layout: layout, bottomInset: messagesBottomInset, transition: .immediate)
            }
        })
                
        self.serviceColorDisposable = (((self.themePromise.get()
        |> mapToSignal { theme -> Signal<UIColor, NoError> in
            return chatServiceBackgroundColor(wallpaper: wallpaper, mediaBox: context.account.postbox.mediaBox)
        })
        |> take(1)
        |> then(self.serviceBackgroundColorPromise.get()))
        |> deliverOnMainQueue).start(next: { [weak self] color in
            if let strongSelf = self {
                strongSelf.patternPanelNode.serviceBackgroundColor = color
                strongSelf.pageControlBackgroundNode.backgroundColor = color
                strongSelf.patternButtonNode.buttonColor = color
                strongSelf.colorsButtonNode.buttonColor = color
                strongSelf.playButtonBackgroundNode.color = color
            }
        })
    }
    
    deinit {
        self.stateDisposable?.dispose()
        self.serviceColorDisposable?.dispose()
        self.wallpaperDisposable.dispose()
        self.patternArgumentsDisposable?.dispose()
    }
    
    override func didLoad() {
        super.didLoad()
        
        self.scrollNode.view.bounces = false
        self.scrollNode.view.disablesInteractiveTransitionGestureRecognizer = true
        self.scrollNode.view.showsHorizontalScrollIndicator = false
        self.scrollNode.view.isPagingEnabled = true
        self.scrollNode.view.delegate = self
        self.pageControlNode.setPage(0.0)
        self.colorPanelNode.view.disablesInteractiveTransitionGestureRecognizer = true
        self.patternPanelNode.view.disablesInteractiveTransitionGestureRecognizer = true
    }
    
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let bounds = scrollView.bounds
        if !bounds.width.isZero {
            self.pageControlNode.setPage(scrollView.contentOffset.x / bounds.width)
        }
    }
    
    func updateState(_ f: (ThemeColorState) -> ThemeColorState, animated: Bool = false) {
        let previousState = self.state
        self.state = f(self.state)
        
        var needsLayout = false
        var animationCurve = ContainedViewLayoutTransitionCurve.easeInOut
        var animationDuration: Double = 0.3
        
        let visibleStateChange = !previousState.isEqual(to: self.state)
        if visibleStateChange {
            self.statePromise.set(.single(self.state))
        }
             
        let colorPanelCollapsed = self.state.colorPanelCollapsed
        
        if (previousState.patternWallpaper != nil) != (self.state.patternWallpaper != nil) {
            self.patternButtonNode.setSelected(self.state.patternWallpaper != nil, animated: animated)
        }
        
        let sectionChanged = previousState.section != self.state.section
        if sectionChanged, let section = self.state.section {
            self.view.endEditing(true)
            
            var colors: [UInt32]
            var defaultColor: UIColor?
            switch section {
                case .accent:
                    colors = [self.state.accentColor.rgb]
                case .background:
                    if let themeReference = self.mode.themeReference, case let .builtin(theme) = themeReference {
                        switch theme {
                            case .dayClassic:
                                defaultColor = self.state.accentColor.withMultiplied(hue: 1.019, saturation: 0.867, brightness: 0.965)
                            case .nightAccent:
                                defaultColor = self.state.accentColor.withMultiplied(hue: 1.024, saturation: 0.573, brightness: 0.18)
                            default:
                                break
                        }
                    }
                    if !self.state.backgroundColors.isEmpty {
                        colors = self.state.backgroundColors
                    } else {
                        colors = []
                    }
                case .messages:
                    if let defaultMessagesColor = self.state.defaultMessagesColor {
                        defaultColor = defaultMessagesColor
                    } else if let themeReference = self.mode.themeReference, case let .builtin(theme) = themeReference, theme == .nightAccent {
                        defaultColor = self.state.accentColor.withMultiplied(hue: 1.019, saturation: 0.731, brightness: 0.59)
                    } else {
                        defaultColor = self.state.accentColor
                    }
                    if let messagesColors = self.state.messagesColors {
                        if let second = messagesColors.1 {
                            colors = [messagesColors.0.rgb, second.rgb]
                        } else {
                            colors = [messagesColors.0.rgb]
                        }
                    } else {
                        colors = []
                    }
            }

            if colors.isEmpty, let defaultColor = defaultColor {
                colors = [defaultColor.rgb]
            }

            let maximumNumberOfColors: Int
            switch self.state.section {
            case .accent:
                maximumNumberOfColors = 1
            case .background:
                maximumNumberOfColors = 4
            case .messages:
                maximumNumberOfColors = 2
            default:
                maximumNumberOfColors = 1
            }

            self.colorPanelNode.updateState({ _ in
                return WallpaperColorPanelNodeState(
                    selection: colorPanelCollapsed ? nil : 0,
                    colors: colors,
                    maximumNumberOfColors: maximumNumberOfColors,
                    rotateAvailable: self.state.section == .background,
                    rotation: self.state.rotation,
                    preview: false,
                    simpleGradientGeneration: self.state.section == .messages
                )
            }, animated: animated)
            
            needsLayout = true
        }
        
        if previousState.colorPanelCollapsed != self.state.colorPanelCollapsed {
            animationCurve = .spring
            animationDuration = 0.45
            needsLayout = true
            
            self.colorPanelNode.updateState({ current in
                var updated = current
                updated.selection = colorPanelCollapsed ? nil : 0
                return updated
            }, animated: animated)
        }
        
        if previousState.displayPatternPanel != self.state.displayPatternPanel {
            let cancelButtonType: WallpaperGalleryToolbarCancelButtonType
            let doneButtonType: WallpaperGalleryToolbarDoneButtonType
            if self.state.displayPatternPanel {
                doneButtonType = .apply
                cancelButtonType = .discard
            } else {
                if case .edit(_, _, _, _, true, _) = self.mode {
                    doneButtonType = .proceed
                } else {
                    doneButtonType = .set
                }
                cancelButtonType = .cancel
            }
            
            self.toolbarNode.cancelButtonType = cancelButtonType
            self.toolbarNode.doneButtonType = doneButtonType
            
            animationCurve = .easeInOut
            animationDuration = 0.3
            needsLayout = true
        }
        
        if (previousState.patternWallpaper == nil) != (self.state.patternWallpaper == nil) {
            needsLayout = true
        }

        if (previousState.backgroundColors.count >= 2) != (self.state.backgroundColors.count >= 2) {
            needsLayout = true
        }

        if previousState.backgroundColors.count != self.state.backgroundColors.count {
            if self.state.backgroundColors.count <= 2 {
                self.playButtonNode.setImage(self.playButtonRotateImage, for: [])
            } else {
                self.playButtonNode.setImage(self.playButtonPlayImage, for: [])
            }
        }

        self.colorsButtonNode.isSelected = !self.state.colorPanelCollapsed
        
        if needsLayout, let (layout, navigationBarHeight, _) = self.validLayout {
            self.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: animated ? .animated(duration: animationDuration, curve: animationCurve) : .immediate)
        }
    }
    
    func updateSection(_ section: ThemeColorSection) {
        self.updateState({ current in
            var updated = current
            if section == .background {
                updated.initialWallpaper = nil
            }
            updated.section = section
            updated.displayPatternPanel = false
            updated.colorPanelCollapsed = false
            return updated
        }, animated: true)
    }
    
    private func updateChatsLayout(layout: ContainerViewLayout, topInset: CGFloat, transition: ContainedViewLayoutTransition) {
        var items: [ChatListItem] = []
        
        let interaction = ChatListNodeInteraction(activateSearch: {}, peerSelected: { _, _ in }, disabledPeerSelected: { _ in }, togglePeerSelected: { _ in }, additionalCategorySelected: { _ in
        }, messageSelected: { _, _, _ in}, groupSelected: { _ in }, addContact: { _ in }, setPeerIdWithRevealedOptions: { _, _ in }, setItemPinned: { _, _ in }, setPeerMuted: { _, _ in }, deletePeer: { _, _ in }, updatePeerGrouping: { _, _ in }, togglePeerMarkedUnread: { _, _ in}, toggleArchivedFolderHiddenByDefault: {}, hidePsa: { _ in
        }, activateChatPreview: { _, _, gesture in
            gesture?.cancel()
        }, present: { _ in
        })
        let chatListPresentationData = ChatListPresentationData(theme: self.theme, fontSize: self.presentationData.listsFontSize, strings: self.presentationData.strings, dateTimeFormat: self.presentationData.dateTimeFormat, nameSortOrder: self.presentationData.nameSortOrder, nameDisplayOrder: self.presentationData.nameDisplayOrder, disableAnimations: true)
        
        let peers = SimpleDictionary<PeerId, Peer>()
        let messages = SimpleDictionary<MessageId, Message>()
        let selfPeer = TelegramUser(id: self.context.account.peerId, accessHash: nil, firstName: nil, lastName: nil, username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [])
        let peer1 = TelegramUser(id: PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt32Value(1)), accessHash: nil, firstName: self.presentationData.strings.Appearance_ThemePreview_ChatList_1_Name, lastName: nil, username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [])
        let peer2 = TelegramUser(id: PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt32Value(2)), accessHash: nil, firstName: self.presentationData.strings.Appearance_ThemePreview_ChatList_2_Name, lastName: nil, username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [])
        let peer3 = TelegramChannel(id: PeerId(namespace: Namespaces.Peer.CloudChannel, id: PeerId.Id._internalFromInt32Value(3)), accessHash: nil, title: self.presentationData.strings.Appearance_ThemePreview_ChatList_3_Name, username: nil, photo: [], creationDate: 0, version: 0, participationStatus: .member, info: .group(.init(flags: [])), flags: [], restrictionInfo: nil, adminRights: nil, bannedRights: nil, defaultBannedRights: nil)
        let peer3Author = TelegramUser(id: PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt32Value(4)), accessHash: nil, firstName: self.presentationData.strings.Appearance_ThemePreview_ChatList_3_AuthorName, lastName: nil, username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [])
        let peer4 = TelegramUser(id: PeerId(namespace: Namespaces.Peer.SecretChat, id: PeerId.Id._internalFromInt32Value(4)), accessHash: nil, firstName: self.presentationData.strings.Appearance_ThemePreview_ChatList_4_Name, lastName: nil, username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [])
        
        let timestamp = self.referenceTimestamp
        
        let timestamp1 = timestamp + 120
        items.append(ChatListItem(presentationData: chatListPresentationData, context: self.context, peerGroupId: .root, filterData: nil, index: ChatListIndex(pinningIndex: 0, messageIndex: MessageIndex(id: MessageId(peerId: peer1.id, namespace: 0, id: 0), timestamp: timestamp1)), content: .peer(messages: [Message(stableId: 0, stableVersion: 0, id: MessageId(peerId: peer1.id, namespace: 0, id: 0), globallyUniqueId: nil, groupingKey: nil, groupInfo: nil, threadId: nil, timestamp: timestamp1, flags: [], tags: [], globalTags: [], localTags: [], forwardInfo: nil, author: selfPeer, text: self.presentationData.strings.Appearance_ThemePreview_ChatList_1_Text, attributes: [], media: [], peers: peers, associatedMessages: messages, associatedMessageIds: [])], peer: RenderedPeer(peer: peer1), combinedReadState: CombinedPeerReadState(states: [(Namespaces.Message.Cloud, PeerReadState.idBased(maxIncomingReadId: 0, maxOutgoingReadId: 0, maxKnownId: 0, count: 0, markedUnread: false))]), isRemovedFromTotalUnreadCount: false, presence: nil, summaryInfo: ChatListMessageTagSummaryInfo(tagSummaryCount: nil, actionsSummaryCount: nil), embeddedState: nil, inputActivities: nil, promoInfo: nil, ignoreUnreadBadge: false, displayAsMessage: false, hasFailedMessages: false), editing: false, hasActiveRevealControls: false, selected: false, header: nil, enableContextActions: false, hiddenOffset: false, interaction: interaction))
        
        let presenceTimestamp = Int32(CFAbsoluteTimeGetCurrent() + NSTimeIntervalSince1970 + 60 * 60)
        let timestamp2 = timestamp + 3660
        items.append(ChatListItem(presentationData: chatListPresentationData, context: self.context, peerGroupId: .root, filterData: nil, index: ChatListIndex(pinningIndex: nil, messageIndex: MessageIndex(id: MessageId(peerId: peer2.id, namespace: 0, id: 0), timestamp: timestamp2)), content: .peer(messages: [Message(stableId: 0, stableVersion: 0, id: MessageId(peerId: peer2.id, namespace: 0, id: 1), globallyUniqueId: nil, groupingKey: nil, groupInfo: nil, threadId: nil, timestamp: timestamp2, flags: [.Incoming], tags: [], globalTags: [], localTags: [], forwardInfo: nil, author: peer2, text: self.presentationData.strings.Appearance_ThemePreview_ChatList_2_Text, attributes: [], media: [], peers: peers, associatedMessages: messages, associatedMessageIds: [])], peer: RenderedPeer(peer: peer2), combinedReadState: CombinedPeerReadState(states: [(Namespaces.Message.Cloud, PeerReadState.idBased(maxIncomingReadId: 0, maxOutgoingReadId: 0, maxKnownId: 0, count: 1, markedUnread: false))]), isRemovedFromTotalUnreadCount: false, presence: TelegramUserPresence(status: .present(until: presenceTimestamp), lastActivity: presenceTimestamp), summaryInfo: ChatListMessageTagSummaryInfo(tagSummaryCount: nil, actionsSummaryCount: nil), embeddedState: nil, inputActivities: nil, promoInfo: nil, ignoreUnreadBadge: false, displayAsMessage: false, hasFailedMessages: false), editing: false, hasActiveRevealControls: false, selected: false, header: nil, enableContextActions: false, hiddenOffset: false, interaction: interaction))
        
        let timestamp3 = timestamp + 3200
        items.append(ChatListItem(presentationData: chatListPresentationData, context: self.context, peerGroupId: .root, filterData: nil, index: ChatListIndex(pinningIndex: nil, messageIndex: MessageIndex(id: MessageId(peerId: peer3.id, namespace: 0, id: 0), timestamp: timestamp3)), content: .peer(messages: [Message(stableId: 0, stableVersion: 0, id: MessageId(peerId: peer3.id, namespace: 0, id: 1), globallyUniqueId: nil, groupingKey: nil, groupInfo: nil, threadId: nil, timestamp: timestamp3, flags: [], tags: [], globalTags: [], localTags: [], forwardInfo: nil, author: peer3Author, text: self.presentationData.strings.Appearance_ThemePreview_ChatList_3_Text, attributes: [], media: [], peers: peers, associatedMessages: messages, associatedMessageIds: [])], peer: RenderedPeer(peer: peer3), combinedReadState: nil, isRemovedFromTotalUnreadCount: false, presence: nil, summaryInfo: ChatListMessageTagSummaryInfo(tagSummaryCount: nil, actionsSummaryCount: nil), embeddedState: nil, inputActivities: nil, promoInfo: nil, ignoreUnreadBadge: false, displayAsMessage: false, hasFailedMessages: false), editing: false, hasActiveRevealControls: false, selected: false, header: nil, enableContextActions: false, hiddenOffset: false, interaction: interaction))
        
        let timestamp4 = timestamp + 3000
        items.append(ChatListItem(presentationData: chatListPresentationData, context: self.context, peerGroupId: .root, filterData: nil, index: ChatListIndex(pinningIndex: nil, messageIndex: MessageIndex(id: MessageId(peerId: peer4.id, namespace: 0, id: 0), timestamp: timestamp4)), content: .peer(messages: [Message(stableId: 0, stableVersion: 0, id: MessageId(peerId: peer4.id, namespace: 0, id: 1), globallyUniqueId: nil, groupingKey: nil, groupInfo: nil, threadId: nil, timestamp: timestamp4, flags: [.Incoming], tags: [], globalTags: [], localTags: [], forwardInfo: nil, author: peer4, text: self.presentationData.strings.Appearance_ThemePreview_ChatList_4_Text, attributes: [], media: [], peers: peers, associatedMessages: messages, associatedMessageIds: [])], peer: RenderedPeer(peer: peer4), combinedReadState: nil, isRemovedFromTotalUnreadCount: false, presence: nil, summaryInfo: ChatListMessageTagSummaryInfo(tagSummaryCount: nil, actionsSummaryCount: nil), embeddedState: nil, inputActivities: nil, promoInfo: nil, ignoreUnreadBadge: false, displayAsMessage: false, hasFailedMessages: false), editing: false, hasActiveRevealControls: false, selected: false, header: nil, enableContextActions: false, hiddenOffset: false, interaction: interaction))
        
        let params = ListViewItemLayoutParams(width: layout.size.width, leftInset: layout.safeInsets.left, rightInset: layout.safeInsets.right, availableHeight: layout.size.height)
        if let chatNodes = self.chatNodes {
            for i in 0 ..< items.count {
                let itemNode = chatNodes[i]
                items[i].updateNode(async: { $0() }, node: {
                    return itemNode
                }, params: params, previousItem: i == 0 ? nil : items[i - 1], nextItem: i == (items.count - 1) ? nil : items[i + 1], animation: .None, completion: { (layout, apply) in
                    let nodeFrame = CGRect(origin: itemNode.frame.origin, size: CGSize(width: layout.size.width, height: layout.size.height))
                    
                    itemNode.contentSize = layout.contentSize
                    itemNode.insets = layout.insets
                    itemNode.frame = nodeFrame
                    itemNode.isUserInteractionEnabled = false
                    
                    apply(ListViewItemApply(isOnScreen: true))
                })
            }
        } else {
            var chatNodes: [ListViewItemNode] = []
            for i in 0 ..< items.count {
                var itemNode: ListViewItemNode?
                items[i].nodeConfiguredForParams(async: { $0() }, params: params, synchronousLoads: false, previousItem: i == 0 ? nil : items[i - 1], nextItem: i == (items.count - 1) ? nil : items[i + 1], completion: { node, apply in
                    itemNode = node
                    apply().1(ListViewItemApply(isOnScreen: true))
                })
                itemNode!.isUserInteractionEnabled = false
                chatNodes.append(itemNode!)
                self.chatListBackgroundNode.insertSubnode(itemNode!, belowSubnode: self.maskNode)
            }
            self.chatNodes = chatNodes
        }
        
        if let chatNodes = self.chatNodes {
            var topOffset: CGFloat = topInset
            for itemNode in chatNodes {
                transition.updateFrame(node: itemNode, frame: CGRect(origin: CGPoint(x: 0.0, y: topOffset), size: itemNode.frame.size))
                topOffset += itemNode.frame.height
            }
        }
    }
    
    private func updateMessagesLayout(layout: ContainerViewLayout, bottomInset: CGFloat, transition: ContainedViewLayoutTransition) {
        let headerItem = self.context.sharedContext.makeChatMessageDateHeaderItem(context: self.context, timestamp:  self.referenceTimestamp, theme: self.theme, strings: self.presentationData.strings, wallpaper: self.wallpaper, fontSize: self.presentationData.chatFontSize, chatBubbleCorners: self.presentationData.chatBubbleCorners, dateTimeFormat: self.presentationData.dateTimeFormat, nameOrder: self.presentationData.nameDisplayOrder)
        
        var items: [ListViewItem] = []
        let peerId = PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt32Value(1))
        let otherPeerId = self.context.account.peerId
        var peers = SimpleDictionary<PeerId, Peer>()
        var messages = SimpleDictionary<MessageId, Message>()
        peers[peerId] = TelegramUser(id: peerId, accessHash: nil, firstName: self.presentationData.strings.Appearance_ThemePreview_Chat_2_ReplyName, lastName: "", username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [])
        peers[otherPeerId] = TelegramUser(id: otherPeerId, accessHash: nil, firstName: self.presentationData.strings.Appearance_ThemePreview_Chat_2_ReplyName, lastName: "", username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [])
        
        var sampleMessages: [Message] = []
        
        let message1 = Message(stableId: 1, stableVersion: 0, id: MessageId(peerId: otherPeerId, namespace: 0, id: 1), globallyUniqueId: nil, groupingKey: nil, groupInfo: nil, threadId: nil, timestamp: 66000, flags: [], tags: [], globalTags: [], localTags: [], forwardInfo: nil, author: peers[otherPeerId], text: self.presentationData.strings.Appearance_ThemePreview_Chat_4_Text, attributes: [], media: [], peers: peers, associatedMessages: messages, associatedMessageIds: [])
        sampleMessages.append(message1)
        
        let message2 = Message(stableId: 2, stableVersion: 0, id: MessageId(peerId: peerId, namespace: 0, id: 2), globallyUniqueId: nil, groupingKey: nil, groupInfo: nil, threadId: nil, timestamp: 66001, flags: [.Incoming], tags: [], globalTags: [], localTags: [], forwardInfo: nil, author: peers[peerId], text: self.presentationData.strings.Appearance_ThemePreview_Chat_5_Text, attributes: [], media: [], peers: peers, associatedMessages: messages, associatedMessageIds: [])
        sampleMessages.append(message2)
        
        let message3 = Message(stableId: 3, stableVersion: 0, id: MessageId(peerId: otherPeerId, namespace: 0, id: 3), globallyUniqueId: nil, groupingKey: nil, groupInfo: nil, threadId: nil, timestamp: 66002, flags: [], tags: [], globalTags: [], localTags: [], forwardInfo: nil, author: peers[otherPeerId], text: self.presentationData.strings.Appearance_ThemePreview_Chat_6_Text, attributes: [], media: [], peers: peers, associatedMessages: messages, associatedMessageIds: [])
        sampleMessages.append(message3)
        
        let message4 = Message(stableId: 4, stableVersion: 0, id: MessageId(peerId: peerId, namespace: 0, id: 4), globallyUniqueId: nil, groupingKey: nil, groupInfo: nil, threadId: nil, timestamp: 66003, flags: [.Incoming], tags: [], globalTags: [], localTags: [], forwardInfo: nil, author: peers[peerId], text: self.presentationData.strings.Appearance_ThemePreview_Chat_7_Text, attributes: [], media: [], peers: peers, associatedMessages: messages, associatedMessageIds: [])
        sampleMessages.append(message4)
        
        let message5 = Message(stableId: 5, stableVersion: 0, id: MessageId(peerId: otherPeerId, namespace: 0, id: 5), globallyUniqueId: nil, groupingKey: nil, groupInfo: nil, threadId: nil, timestamp: 66004, flags: [], tags: [], globalTags: [], localTags: [], forwardInfo: nil, author: peers[otherPeerId], text: self.presentationData.strings.Appearance_ThemePreview_Chat_1_Text, attributes: [], media: [], peers: peers, associatedMessages: messages, associatedMessageIds: [])
        messages[message5.id] = message5
        sampleMessages.append(message5)
        
        let waveformBase64 = "DAAOAAkACQAGAAwADwAMABAADQAPABsAGAALAA0AGAAfABoAHgATABgAGQAYABQADAAVABEAHwANAA0ACQAWABkACQAOAAwACQAfAAAAGQAVAAAAEwATAAAACAAfAAAAHAAAABwAHwAAABcAGQAAABQADgAAABQAHwAAAB8AHwAAAAwADwAAAB8AEwAAABoAFwAAAB8AFAAAAAAAHwAAAAAAHgAAAAAAHwAAAAAAHwAAAAAAHwAAAAAAHwAAAAAAHwAAAAAAAAA="
        let voiceAttributes: [TelegramMediaFileAttribute] = [.Audio(isVoice: true, duration: 23, title: nil, performer: nil, waveform: MemoryBuffer(data: Data(base64Encoded: waveformBase64)!))]
        let voiceMedia = TelegramMediaFile(fileId: MediaId(namespace: 0, id: 0), partialReference: nil, resource: LocalFileMediaResource(fileId: 0), previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil, mimeType: "audio/ogg", size: 0, attributes: voiceAttributes)
        
        let message6 = Message(stableId: 6, stableVersion: 0, id: MessageId(peerId: peerId, namespace: 0, id: 6), globallyUniqueId: nil, groupingKey: nil, groupInfo: nil, threadId: nil, timestamp: 66005, flags: [.Incoming], tags: [], globalTags: [], localTags: [], forwardInfo: nil, author: peers[peerId], text: "", attributes: [], media: [voiceMedia], peers: peers, associatedMessages: messages, associatedMessageIds: [])
        sampleMessages.append(message6)
        
        let message7 = Message(stableId: 7, stableVersion: 0, id: MessageId(peerId: peerId, namespace: 0, id: 7), globallyUniqueId: nil, groupingKey: nil, groupInfo: nil, threadId: nil, timestamp: 66006, flags: [.Incoming], tags: [], globalTags: [], localTags: [], forwardInfo: nil, author: peers[peerId], text: self.presentationData.strings.Appearance_ThemePreview_Chat_2_Text, attributes: [ReplyMessageAttribute(messageId: message5.id, threadMessageId: nil)], media: [], peers: peers, associatedMessages: messages, associatedMessageIds: [])
        sampleMessages.append(message7)
        
        let message8 = Message(stableId: 8, stableVersion: 0, id: MessageId(peerId: otherPeerId, namespace: 0, id: 8), globallyUniqueId: nil, groupingKey: nil, groupInfo: nil, threadId: nil, timestamp: 66007, flags: [], tags: [], globalTags: [], localTags: [], forwardInfo: nil, author: peers[otherPeerId], text: self.presentationData.strings.Appearance_ThemePreview_Chat_3_Text, attributes: [], media: [], peers: peers, associatedMessages: messages, associatedMessageIds: [])
        sampleMessages.append(message8)
        
        items = sampleMessages.reversed().map { message in
            let item = self.context.sharedContext.makeChatMessagePreviewItem(context: self.context, messages: [message], theme: self.theme, strings: self.presentationData.strings, wallpaper: self.wallpaper, fontSize: self.presentationData.chatFontSize, chatBubbleCorners: self.presentationData.chatBubbleCorners, dateTimeFormat: self.presentationData.dateTimeFormat, nameOrder: self.presentationData.nameDisplayOrder, forcedResourceStatus: !message.media.isEmpty ? FileMediaResourceStatus(mediaStatus: .playbackStatus(.paused), fetchStatus: .Local) : nil, tapMessage: { [weak self] message in
                guard let strongSelf = self else {
                    return
                }
                strongSelf.updateState({ state in
                    var state = state
                    if state.section == .background {
                        state.colorPanelCollapsed = true
                        state.displayPatternPanel = false
                    }
                    return state
                }, animated: true)
                /*if message.flags.contains(.Incoming) {
                    self?.updateSection(.accent)
                    self?.requestSectionUpdate?(.accent)
                } else {
                    self?.updateSection(.messages)
                    self?.requestSectionUpdate?(.messages)
                }*/
            }, clickThroughMessage: { [weak self] in
                self?.updateSection(.background)
                self?.requestSectionUpdate?(.background)
            }, backgroundNode: self.backgroundNode)
            return item
        }
        
        let params = ListViewItemLayoutParams(width: layout.size.width, leftInset: layout.safeInsets.left, rightInset: layout.safeInsets.right, availableHeight: layout.size.height)
        if let messageNodes = self.messageNodes {
            for i in 0 ..< items.count {
                let itemNode = messageNodes[i]
                items[i].updateNode(async: { $0() }, node: {
                    return itemNode
                }, params: params, previousItem: i == 0 ? nil : items[i - 1], nextItem: i == (items.count - 1) ? nil : items[i + 1], animation: .None, completion: { (layout, apply) in
                    let nodeFrame = CGRect(origin: itemNode.frame.origin, size: CGSize(width: layout.size.width, height: layout.size.height))
                    
                    itemNode.contentSize = layout.contentSize
                    itemNode.insets = layout.insets
                    itemNode.frame = nodeFrame
                    
                    apply(ListViewItemApply(isOnScreen: true))
                })
            }
        } else {
            var messageNodes: [ListViewItemNode] = []
            for i in 0 ..< items.count {
                var itemNode: ListViewItemNode?
                items[i].nodeConfiguredForParams(async: { $0() }, params: params, synchronousLoads: false, previousItem: i == 0 ? nil : items[i - 1], nextItem: i == (items.count - 1) ? nil : items[i + 1], completion: { node, apply in
                    itemNode = node
                    apply().1(ListViewItemApply(isOnScreen: true))
                })
                //itemNode!.subnodeTransform = CATransform3DMakeScale(-1.0, 1.0, 1.0)
                messageNodes.append(itemNode!)
                self.messagesContainerNode.addSubnode(itemNode!)
            }
            self.messageNodes = messageNodes
        }
                
        var bottomOffset: CGFloat = 9.0 + bottomInset
        if let messageNodes = self.messageNodes {
            for itemNode in messageNodes {
                let previousFrame = itemNode.frame
                transition.updateFrame(node: itemNode, frame: CGRect(origin: CGPoint(x: 0.0, y: bottomOffset), size: itemNode.frame.size))
                bottomOffset += itemNode.frame.height
                itemNode.updateFrame(itemNode.frame, within: layout.size)
                if case let .animated(duration, curve) = transition {
                    itemNode.applyAbsoluteOffset(value: CGPoint(x: 0.0, y: -itemNode.frame.minY + previousFrame.minY), animationCurve: curve, duration: duration)
                }
            }
        }
        
        let dateHeaderNode: ListViewItemHeaderNode
        if let currentDateHeaderNode = self.dateHeaderNode {
            dateHeaderNode = currentDateHeaderNode
            headerItem.updateNode(dateHeaderNode, previous: nil, next: headerItem)
        } else {
            dateHeaderNode = headerItem.node()
            //dateHeaderNode.subnodeTransform = CATransform3DMakeScale(-1.0, 1.0, 1.0)
            self.messagesContainerNode.addSubnode(dateHeaderNode)
            self.dateHeaderNode = dateHeaderNode
        }
        
        transition.updateFrame(node: dateHeaderNode, frame: CGRect(origin: CGPoint(x: 0.0, y: bottomOffset), size: CGSize(width: layout.size.width, height: headerItem.height)))
        dateHeaderNode.updateLayout(size: self.messagesContainerNode.frame.size, leftInset: layout.safeInsets.left, rightInset: layout.safeInsets.right)
    }
    
    func containerLayoutUpdated(_ layout: ContainerViewLayout, navigationBarHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        let isFirstLayout = self.validLayout == nil
        
        let bounds = CGRect(origin: CGPoint(), size: layout.size)
  
        let chatListPreviewAvailable = self.state.section == .accent
        
        self.scrollNode.frame = bounds
        self.scrollNode.view.contentSize = CGSize(width: bounds.width * 2.0, height: bounds.height)
        self.scrollNode.view.isScrollEnabled = chatListPreviewAvailable
        
        var messagesTransition = transition
        if !chatListPreviewAvailable && self.scrollNode.view.contentOffset.x > 0.0 {
            var bounds = self.scrollNode.bounds
            bounds.origin.x = 0.0
            transition.updateBounds(node: scrollNode, bounds: bounds)
            messagesTransition = .immediate
            self.pageControlNode.setPage(0.0)
        }
        
        let toolbarHeight = 49.0 + layout.intrinsicInsets.bottom
        transition.updateFrame(node: self.toolbarNode, frame: CGRect(origin: CGPoint(x: 0.0, y: layout.size.height - toolbarHeight), size: CGSize(width: layout.size.width, height: 49.0 + layout.intrinsicInsets.bottom)))
        self.toolbarNode.updateLayout(size: CGSize(width: layout.size.width, height: 49.0), layout: layout, transition: transition)
        
        var bottomInset = toolbarHeight
        let standardInputHeight = layout.deviceMetrics.keyboardHeight(inLandscape: false)
        let inputFieldPanelHeight: CGFloat = 47.0
        let colorPanelHeight = max(standardInputHeight, layout.inputHeight ?? 0.0) - bottomInset + inputFieldPanelHeight
        
        var colorPanelOffset: CGFloat = 0.0
        if self.state.colorPanelCollapsed {
            colorPanelOffset = colorPanelHeight
        }
        let colorPanelFrame = CGRect(origin: CGPoint(x: 0.0, y: layout.size.height - bottomInset - colorPanelHeight + colorPanelOffset), size: CGSize(width: layout.size.width, height: colorPanelHeight))
        bottomInset += (colorPanelHeight - colorPanelOffset)
        
        if bottomInset + navigationBarHeight > bounds.height {
            return
        }
        
        transition.updateFrame(node: self.colorPanelNode, frame: colorPanelFrame)
        self.colorPanelNode.updateLayout(size: colorPanelFrame.size, transition: transition)
        
        var patternPanelAlpha: CGFloat = self.state.displayPatternPanel ? 1.0 : 0.0
        var patternPanelFrame = colorPanelFrame
        transition.updateFrame(node: self.patternPanelNode, frame: patternPanelFrame)
        self.patternPanelNode.updateLayout(size: patternPanelFrame.size, transition: transition)
        self.patternPanelNode.isUserInteractionEnabled = self.state.displayPatternPanel
        transition.updateAlpha(node: self.patternPanelNode, alpha: patternPanelAlpha)
        
        self.chatListBackgroundNode.frame = CGRect(x: bounds.width, y: 0.0, width: bounds.width, height: bounds.height)
        
        transition.updateBounds(node: self.messagesContainerNode, bounds: CGRect(x: 0.0, y: 0.0, width: bounds.width, height: bounds.height))
        transition.updatePosition(node: self.messagesContainerNode, position: CGRect(x: 0.0, y: 0.0, width: bounds.width, height: bounds.height).center)
        
        let backgroundSize = CGSize(width: bounds.width, height: bounds.height - (colorPanelHeight - colorPanelOffset))
        transition.updateFrame(node: self.backgroundContainerNode, frame: CGRect(origin: CGPoint(), size: backgroundSize))

        transition.updateFrame(node: self.backgroundNode, frame: CGRect(origin: CGPoint(), size: layout.size))
        self.backgroundNode.updateLayout(size: self.backgroundNode.bounds.size, transition: transition)
        
        transition.updatePosition(node: self.backgroundWrapperNode, position: CGPoint(x: backgroundSize.width / 2.0, y: backgroundSize.height / 2.0))
        
        transition.updateBounds(node: self.backgroundWrapperNode, bounds: CGRect(origin: CGPoint(), size: layout.size))
    
        let displayOptionButtons = self.state.section == .background
        var messagesBottomInset: CGFloat = bottomInset
        
        if displayOptionButtons {
            messagesBottomInset += 56.0
        } else if chatListPreviewAvailable {
            messagesBottomInset += 37.0
        }
        self.updateChatsLayout(layout: layout, topInset: navigationBarHeight, transition: transition)
        self.updateMessagesLayout(layout: layout, bottomInset: messagesBottomInset, transition: messagesTransition)
        
        self.validLayout = (layout, navigationBarHeight, messagesBottomInset)
        
        let pageControlAlpha: CGFloat = chatListPreviewAvailable ? 1.0 : 0.0
        let pageControlSize = self.pageControlNode.measure(CGSize(width: bounds.width, height: 100.0))
        let pageControlFrame = CGRect(origin: CGPoint(x: floor((bounds.width - pageControlSize.width) / 2.0), y: layout.size.height - bottomInset - 28.0), size: pageControlSize)
        transition.updateFrame(node: self.pageControlNode, frame: pageControlFrame)
        transition.updateFrame(node: self.pageControlBackgroundNode, frame: CGRect(x: pageControlFrame.minX - 7.0, y: pageControlFrame.minY - 7.0, width: pageControlFrame.width + 14.0, height: 21.0))
        
        transition.updateAlpha(node: self.pageControlNode, alpha: pageControlAlpha)
        transition.updateAlpha(node: self.pageControlBackgroundNode, alpha: pageControlAlpha)
        transition.updateFrame(node: self.maskNode, frame: CGRect(x: 0.0, y: layout.size.height - bottomInset - 80.0, width: bounds.width, height: 80.0))
        
        let patternButtonSize = self.patternButtonNode.measure(layout.size)
        let colorsButtonSize = self.colorsButtonNode.measure(layout.size)
        let maxButtonWidth = max(patternButtonSize.width, colorsButtonSize.width)
        let buttonSize = CGSize(width: maxButtonWidth, height: 30.0)

        let patternAlpha: CGFloat = displayOptionButtons ? 1.0 : 0.0
        let colorsAlpha: CGFloat = displayOptionButtons ? 1.0 : 0.0
        
        let patternFrame: CGRect
        let colorsFrame: CGRect

        let playButtonSize = CGSize(width: 48.0, height: 48.0)
        var centerDistance: CGFloat = 40.0
        let buttonsVerticalOffset: CGFloat = 5.0

        let playFrame = CGRect(origin: CGPoint(x: floor((layout.size.width - playButtonSize.width) / 2.0), y: layout.size.height - bottomInset - 44.0 - buttonsVerticalOffset + floor((buttonSize.height - playButtonSize.height) / 2.0)), size: playButtonSize)

        let playAlpha: CGFloat
        if self.state.backgroundColors.count >= 2 {
            playAlpha = displayOptionButtons ? 1.0 : 0.0
            centerDistance += playButtonSize.width
        } else {
            playAlpha = 0.0
        }

        patternFrame = CGRect(origin: CGPoint(x: floor((layout.size.width - buttonSize.width * 2.0 - centerDistance) / 2.0), y: layout.size.height - bottomInset - 44.0 - buttonsVerticalOffset), size: buttonSize)
        colorsFrame = CGRect(origin: CGPoint(x: patternFrame.maxX + centerDistance, y: layout.size.height - bottomInset - 44.0 - buttonsVerticalOffset), size: buttonSize)
        
        transition.updateFrame(node: self.patternButtonNode, frame: patternFrame)
        transition.updateAlpha(node: self.patternButtonNode, alpha: patternAlpha)
        transition.updateFrame(node: self.colorsButtonNode, frame: colorsFrame)
        transition.updateAlpha(node: self.colorsButtonNode, alpha: colorsAlpha)

        transition.updateFrame(node: self.playButtonNode, frame: playFrame)
        transition.updateFrame(node: self.playButtonBackgroundNode, frame: CGRect(origin: CGPoint(), size: playFrame.size))
        self.playButtonBackgroundNode.update(size: playFrame.size, cornerRadius: playFrame.size.height / 2.0, transition: transition)
        transition.updateAlpha(node: self.playButtonNode, alpha: playAlpha)
    }
    
    @objc private func togglePattern() {
        self.view.endEditing(true)
        
        let wallpaper = self.state.previousPatternWallpaper ?? self.patternPanelNode.wallpapers.first
        let backgroundColors = self.currentBackgroundColors
        
        var appeared = false
        self.updateState({ current in
            var updated = current
            if !updated.displayPatternPanel {
                updated.colorPanelCollapsed = false
                updated.displayPatternPanel = true
                if current.patternWallpaper == nil, let wallpaper = wallpaper {
                    updated.patternWallpaper = wallpaper
                    if updated.backgroundColors.isEmpty {
                        if let backgroundColors = backgroundColors {
                            updated.backgroundColors = backgroundColors.0
                        } else {
                            updated.backgroundColors = []
                        }
                    }
                    appeared = true
                }
            } else {
                updated.colorPanelCollapsed = true
                if updated.patternWallpaper != nil {
                    updated.previousPatternWallpaper = updated.patternWallpaper
                    updated.patternWallpaper = nil
                    updated.displayPatternPanel = false
                } else {
                    updated.colorPanelCollapsed = false
                    updated.displayPatternPanel = true
                    if current.patternWallpaper == nil, let wallpaper = wallpaper {
                        updated.patternWallpaper = wallpaper
                        if updated.backgroundColors.isEmpty {
                            if let backgroundColors = backgroundColors {
                                updated.backgroundColors = backgroundColors.0
                            } else {
                                updated.backgroundColors = []
                            }
                        }
                        appeared = true
                    }
                }
            }
            return updated
        }, animated: true)
        
        if appeared {
            self.patternPanelNode.didAppear(initialWallpaper: wallpaper, intensity: self.state.patternIntensity)
        }
    }

    @objc private func toggleColors() {
        self.updateState({ current in
            var updated = current
            if updated.displayPatternPanel {
                updated.displayPatternPanel = false
                updated.colorPanelCollapsed = false
            } else {
                if updated.colorPanelCollapsed {
                    updated.colorPanelCollapsed = false
                } else {
                    updated.colorPanelCollapsed = true
                }
            }
            updated.displayPatternPanel = false
            return updated
        }, animated: true)
    }

    @objc private func playPressed() {
        if self.state.backgroundColors.count >= 3 {
            self.backgroundNode.animateEvent(transition: .animated(duration: 0.5, curve: .spring))
        } else {
            self.updateState({ state in
                var state = state
                state.rotation = (state.rotation + 90) % 360
                return state
            }, animated: true)
        }
    }

    func animateWallpaperAppeared() {
        self.backgroundNode.animateEvent(transition: .animated(duration: 2.0, curve: .spring), extendAnimation: true)
    }
}
