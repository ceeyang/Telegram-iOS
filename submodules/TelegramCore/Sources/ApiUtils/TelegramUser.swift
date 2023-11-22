import Foundation
import Postbox
import TelegramApi


func parsedTelegramProfilePhoto(_ photo: Api.UserProfilePhoto) -> [TelegramMediaImageRepresentation] {
    var representations: [TelegramMediaImageRepresentation] = []
    switch photo {
        case let .userProfilePhoto(flags, id, strippedThumb, dcId):
            let hasVideo = (flags & (1 << 0)) != 0
            let isPersonal = (flags & (1 << 2)) != 0
            
            let smallResource: TelegramMediaResource
            let fullSizeResource: TelegramMediaResource

            smallResource = CloudPeerPhotoSizeMediaResource(datacenterId: dcId, photoId: id, sizeSpec: .small, volumeId: nil, localId: nil)
            fullSizeResource = CloudPeerPhotoSizeMediaResource(datacenterId: dcId, photoId: id, sizeSpec: .fullSize, volumeId: nil, localId: nil)

            representations.append(TelegramMediaImageRepresentation(dimensions: PixelDimensions(width: 80, height: 80), resource: smallResource, progressiveSizes: [], immediateThumbnailData: strippedThumb?.makeData(), hasVideo: hasVideo, isPersonal: isPersonal))
            representations.append(TelegramMediaImageRepresentation(dimensions: PixelDimensions(width: 640, height: 640), resource: fullSizeResource, progressiveSizes: [], immediateThumbnailData: strippedThumb?.makeData(), hasVideo: hasVideo, isPersonal: isPersonal))
        case .userProfilePhotoEmpty:
            break
    }
    return representations
}

extension TelegramPeerUsername {
    init(apiUsername: Api.Username) {
        switch apiUsername {
        case let .username(flags, username):
            self.init(flags: Flags(rawValue: flags), username: username)
        }
    }
}

extension TelegramUser {
    convenience init(user: Api.User) {
        switch user {
        case let .user(flags, flags2, id, accessHash, firstName, lastName, username, phone, photo, _, _, restrictionReason, botInlinePlaceholder, _, emojiStatus, usernames, _, color, profileColor):
            let representations: [TelegramMediaImageRepresentation] = photo.flatMap(parsedTelegramProfilePhoto) ?? []
            
            let isMin = (flags & (1 << 20)) != 0
            let accessHashValue = accessHash.flatMap { value -> TelegramPeerAccessHash in
                if isMin {
                    return .genericPublic(value)
                } else {
                    return .personal(value)
                }
            }
            
            var userFlags: UserInfoFlags = []
            if (flags & (1 << 17)) != 0 {
                userFlags.insert(.isVerified)
            }
            if (flags & (1 << 23)) != 0 {
                userFlags.insert(.isSupport)
            }
            if (flags & (1 << 24)) != 0 {
                userFlags.insert(.isScam)
            }
            if (flags & (1 << 26)) != 0 {
                userFlags.insert(.isFake)
            }
            if (flags & (1 << 28)) != 0 {
                userFlags.insert(.isPremium)
            }
            if (flags2 & (1 << 2)) != 0 {
                userFlags.insert(.isCloseFriend)
            }
            
            var storiesHidden: Bool?
            if !isMin {
                storiesHidden = (flags2 & (1 << 3)) != 0
            }
            
            var botInfo: BotUserInfo?
            if (flags & (1 << 14)) != 0 {
                var botFlags = BotUserInfoFlags()
                if (flags & (1 << 15)) != 0 {
                    botFlags.insert(.hasAccessToChatHistory)
                }
                if (flags & (1 << 16)) == 0 {
                    botFlags.insert(.worksWithGroups)
                }
                if (flags & (1 << 21)) != 0 {
                    botFlags.insert(.requiresGeolocationForInlineRequests)
                }
                if (flags & (1 << 27)) != 0 {
                    botFlags.insert(.canBeAddedToAttachMenu)
                }
                if (flags2 & (1 << 1)) != 0 {
                    botFlags.insert(.canEdit)
                }
                botInfo = BotUserInfo(flags: botFlags, inlinePlaceholder: botInlinePlaceholder)
            }
            
            let restrictionInfo: PeerAccessRestrictionInfo? = restrictionReason.flatMap(PeerAccessRestrictionInfo.init(apiReasons:))
            
            var nameColorIndex: Int32?
            var backgroundEmojiId: Int64?
            if let color = color {
                switch color {
                case let .peerColor(color, backgroundEmojiIdValue):
                    nameColorIndex = color
                    backgroundEmojiId = backgroundEmojiIdValue
                }
            }
            
            var profileColorIndex: Int32?
            var profileBackgroundEmojiId: Int64?
            if let profileColor = profileColor {
                switch profileColor {
                case let .peerColor(color, backgroundEmojiIdValue):
                    profileColorIndex = color
                    profileBackgroundEmojiId = backgroundEmojiIdValue
                }
            }
            
            self.init(id: PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(id)), accessHash: accessHashValue, firstName: firstName, lastName: lastName, username: username, phone: phone, photo: representations, botInfo: botInfo, restrictionInfo: restrictionInfo, flags: userFlags, emojiStatus: emojiStatus.flatMap(PeerEmojiStatus.init(apiStatus:)), usernames: usernames?.map(TelegramPeerUsername.init(apiUsername:)) ?? [], storiesHidden: storiesHidden, nameColor: nameColorIndex.flatMap { PeerNameColor(rawValue: $0) }, backgroundEmojiId: backgroundEmojiId, profileColor: profileColorIndex.flatMap { PeerNameColor(rawValue: $0) }, profileBackgroundEmojiId: profileBackgroundEmojiId)
        case let .userEmpty(id):
            self.init(id: PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(id)), accessHash: nil, firstName: nil, lastName: nil, username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil)
        }
    }
    
    static func merge(_ lhs: TelegramUser?, rhs: Api.User) -> TelegramUser? {
        switch rhs {
            case let .user(flags, _, _, rhsAccessHash, _, _, _, _, photo, _, _, restrictionReason, botInlinePlaceholder, _, emojiStatus, _, _, nameColor, profileColor):
                let isMin = (flags & (1 << 20)) != 0
                if !isMin {
                    return TelegramUser(user: rhs)
                } else {
                    let applyMinPhoto = (flags & (1 << 25)) != 0
                    
                    let telegramPhoto: [TelegramMediaImageRepresentation]
                    if let photo = photo, applyMinPhoto {
                        telegramPhoto = parsedTelegramProfilePhoto(photo)
                    } else if let currentPhoto = lhs?.photo {
                        telegramPhoto = currentPhoto
                    } else {
                        telegramPhoto = []
                    }

                    if let lhs = lhs {
                        var userFlags: UserInfoFlags = []
                        if (flags & (1 << 17)) != 0 {
                            userFlags.insert(.isVerified)
                        }
                        if (flags & (1 << 23)) != 0 {
                            userFlags.insert(.isSupport)
                        }
                        if (flags & (1 << 24)) != 0 {
                            userFlags.insert(.isScam)
                        }
                        if (flags & Int32(1 << 26)) != 0 {
                            userFlags.insert(.isFake)
                        }
                        if (flags & (1 << 28)) != 0 {
                            userFlags.insert(.isPremium)
                        }
                        
                        if lhs.flags.contains(.isCloseFriend) {
                            userFlags.insert(.isCloseFriend)
                        }
                        
                        var botInfo: BotUserInfo?
                        if (flags & (1 << 14)) != 0 {
                            var botFlags = BotUserInfoFlags()
                            if (flags & (1 << 15)) != 0 {
                                botFlags.insert(.hasAccessToChatHistory)
                            }
                            if (flags & (1 << 16)) == 0 {
                                botFlags.insert(.worksWithGroups)
                            }
                            if (flags & (1 << 21)) != 0 {
                                botFlags.insert(.requiresGeolocationForInlineRequests)
                            }
                            if (flags & (1 << 27)) != 0 {
                                botFlags.insert(.canBeAddedToAttachMenu)
                            }
                            if let botInfo = lhs.botInfo, botInfo.flags.contains(.canEdit) {
                                botFlags.insert(.canEdit)
                            }
                            botInfo = BotUserInfo(flags: botFlags, inlinePlaceholder: botInlinePlaceholder)
                        }
                        
                        let restrictionInfo: PeerAccessRestrictionInfo? = restrictionReason.flatMap(PeerAccessRestrictionInfo.init)
                        
                        let rhsAccessHashValue = rhsAccessHash.flatMap { value -> TelegramPeerAccessHash in
                            if isMin {
                                return .genericPublic(value)
                            } else {
                                return .personal(value)
                            }
                        }
                        
                        let accessHash: TelegramPeerAccessHash?
                        if let rhsAccessHashValue = rhsAccessHashValue, case .personal = rhsAccessHashValue {
                            accessHash = rhsAccessHashValue
                        } else {
                            accessHash = lhs.accessHash ?? rhsAccessHashValue
                        }
                        
                        var nameColorIndex: Int32?
                        var backgroundEmojiId: Int64?
                        if let nameColor = nameColor {
                            switch nameColor {
                            case let .peerColor(color, backgroundEmojiIdValue):
                                nameColorIndex = color
                                backgroundEmojiId = backgroundEmojiIdValue
                            }
                        }
                        
                        var profileColorIndex: Int32?
                        var profileBackgroundEmojiId: Int64?
                        if let profileColor = profileColor {
                            switch profileColor {
                            case let .peerColor(color, backgroundEmojiIdValue):
                                profileColorIndex = color
                                profileBackgroundEmojiId = backgroundEmojiIdValue
                            }
                        }
                        
                        return TelegramUser(id: lhs.id, accessHash: accessHash, firstName: lhs.firstName, lastName: lhs.lastName, username: lhs.username, phone: lhs.phone, photo: telegramPhoto, botInfo: botInfo, restrictionInfo: restrictionInfo, flags: userFlags, emojiStatus: emojiStatus.flatMap(PeerEmojiStatus.init(apiStatus:)), usernames: lhs.usernames, storiesHidden: lhs.storiesHidden, nameColor: nameColorIndex.flatMap { PeerNameColor(rawValue: $0) }, backgroundEmojiId: backgroundEmojiId, profileColor: profileColorIndex.flatMap { PeerNameColor(rawValue: $0) }, profileBackgroundEmojiId: profileBackgroundEmojiId)
                    } else {
                        return TelegramUser(user: rhs)
                    }
                }
            case .userEmpty:
                return TelegramUser(user: rhs)
        }
    }
    
    static func merge(lhs: TelegramUser?, rhs: TelegramUser) -> TelegramUser {
        guard let lhs = lhs else {
            return rhs
        }
        if let rhsAccessHash = rhs.accessHash, case .personal = rhsAccessHash {
            return rhs
        } else {
            var userFlags: UserInfoFlags = []
            if rhs.flags.contains(.isVerified) {
                userFlags.insert(.isVerified)
            }
            if rhs.flags.contains(.isSupport) {
                userFlags.insert(.isSupport)
            }
            if rhs.flags.contains(.isScam) {
                userFlags.insert(.isScam)
            }
            if rhs.flags.contains(.isFake) {
                userFlags.insert(.isFake)
            }
            if rhs.flags.contains(.isPremium) {
                userFlags.insert(.isPremium)
            }

            let botInfo: BotUserInfo? = rhs.botInfo
            
            let emojiStatus = rhs.emojiStatus
            
            let restrictionInfo: PeerAccessRestrictionInfo? = rhs.restrictionInfo
            
            let accessHash: TelegramPeerAccessHash?
            if let rhsAccessHashValue = rhs.accessHash, case .personal = rhsAccessHashValue {
                accessHash = rhsAccessHashValue
            } else {
                accessHash = lhs.accessHash ?? rhs.accessHash
            }
            
            let photo: [TelegramMediaImageRepresentation]
            if case .genericPublic = rhs.accessHash {
                photo = lhs.photo
            } else {
                photo = rhs.photo
            }
            
            var storiesHidden: Bool?
            if let value = rhs.storiesHidden {
                storiesHidden = value
            } else {
                storiesHidden = lhs.storiesHidden
            }
            
            return TelegramUser(id: lhs.id, accessHash: accessHash, firstName: lhs.firstName, lastName: lhs.lastName, username: lhs.username, phone: lhs.phone, photo: photo, botInfo: botInfo, restrictionInfo: restrictionInfo, flags: userFlags, emojiStatus: emojiStatus, usernames: lhs.usernames, storiesHidden: storiesHidden, nameColor: rhs.nameColor, backgroundEmojiId: rhs.backgroundEmojiId, profileColor: rhs.profileColor, profileBackgroundEmojiId: rhs.profileBackgroundEmojiId)
        }
    }
}
