// Copyright (c) 2023 Proton AG
//
// This file is part of Proton Drive.
//
// Proton Drive is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Proton Drive is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Proton Drive. If not, see https://www.gnu.org/licenses/.

import Foundation
import GoLibs

public extension Node {
    enum Errors: Error {
        case noName
        case invalidFileMetadata
        case noAddress
    }

    private static let unknownNamePlaceholder = String.randomPlaceholder
    
    var decryptedName: String {
        do {
            return try decryptName()
        } catch {
            if !self.isFault {
                self.clearName = Self.unknownNamePlaceholder
            }
            return Self.unknownNamePlaceholder
        }
    }

    internal func decryptName() throws -> String {
        do {
            #if os(iOS)
            // Looks like macOS app does not exchange updates across contexts properly
            if let cached = self.clearName {
                return cached
            }
            #endif
            guard !isFault else { return Self.unknownNamePlaceholder }

            guard let name = self.name else {
                throw Errors.noName
            }
            let (parentPassphrase, parentKey) = try self.getDirectParentPack()
            let parentNodeKey = DecryptionKey(privateKey: parentKey, passphrase: parentPassphrase)
            let addressKeys = try getAddressPublicKeys(email: nameSignatureEmail ?? signatureEmail)
            let decrypted = try Decryptor.decryptAndVerifyNodeName(
                name,
                decryptionKeys: parentNodeKey,
                verificationKeys: addressKeys
            )

            switch decrypted {
            case .verified(let filename):
                self.clearName = filename
                return filename

                // Signature remark: The Name signature is missing before December 2020. Handle appropriately when we display errors.
            case .unverified(let filename, let error):
                ConsoleLogger.shared?.log(SignatureError(error, "Node Name"))
                self.clearName = filename
                return filename
            }

        } catch {
            ConsoleLogger.shared?.log(DecryptionError(error, "Node Name"))
            throw error
        }
    }

    @available(*, deprecated, message: "Use NewUploadingFile to create KeyCredentials of new files, this approach is not test friendly")
    internal func generateNodeKeys(signersKit: SignersKit) throws -> Encryptor.KeyCredentials {
        let (_, parentKey) = try self.getDirectParentPack()
        let nodeCredentials = try Encryptor.generateNodeKeys(addressPassphrase: signersKit.addressPassphrase,
                                                             addressPrivateKey: signersKit.addressKey.privateKey,
                                                             parentKey: parentKey)
        return nodeCredentials
    }
    
    internal func updateNodeKeys(_ nodePassphrase: String, signersKit: SignersKit) throws -> Encryptor.NodeUpdatedCredentials {
        let (_, parentKey) = try self.getDirectParentPack()
        let credentials = try Encryptor.updateNodeKeys(passphraseString: nodePassphrase,
                                                       addressPassphrase: signersKit.addressPassphrase,
                                                       addressPrivateKey: signersKit.addressKey.privateKey,
                                                       parentKey: parentKey)
        return credentials
    }
    
    internal func encryptName(cleartext name: String, signersKit: SignersKit) throws -> String {
        let encryptedName: String = try managedObjectContext!.performAndWait {
            let (_, parentKey) = try self.getDirectParentPack()
            return try Encryptor.encryptAndSign(name, key: parentKey, addressPassphrase: signersKit.addressPassphrase, addressPrivateKey: signersKit.addressKey.privateKey)
        }
        return encryptedName
    }

    // swiftlint:disable:next function_parameter_count
    internal func renameNode(
        oldEncryptedName: String,
        oldParentKey: String,
        oldParentPassphrase: String,
        newClearName: String,
        newParentKey: String,
        signersKit: SignersKit
    ) throws -> String {
        let splitMessage = try Encryptor.splitPGPMessage(oldEncryptedName)

        let decKeyRing = try Decryptor.buildPrivateKeyRing(decryptionKeys: [.init(privateKey: oldParentKey, passphrase: oldParentPassphrase)])
        let sessionKey = try execute { try decKeyRing.decryptSessionKey(splitMessage.keyPacket) }

        let encKeyRing = try Decryptor.buildPublicKeyRing(armoredKeys: [newParentKey])

        let signingKeyRing = try Decryptor.buildPrivateKeyRing(decryptionKeys: [signersKit.signingKey])
        let message = try Encryptor.encryptAndSign(newClearName, using: sessionKey, encryptingKeyRing: encKeyRing, signingKeyRing: signingKeyRing)

        return try executeAndUnwrap { message.getArmored(&$0) }
    }

    internal func reencryptNodeNameKeyPacket(
        oldEncryptedName: String,
        oldParentKey: String,
        oldParentPassphrase: String,
        newParentKey: String
    ) throws -> String {
        do {
            return try Encryptor.reencryptKeyPacket(
                of: oldEncryptedName,
                oldParentKey: oldParentKey,
                oldParentPassphrase: oldParentPassphrase,
                newParentKey: newParentKey
            )
        } catch {
            ConsoleLogger.shared?.log(DecryptionError(error, "Node"))
            throw error
        }
    }

    /// BE only needs the new NodePassphrase KeyPacket, the DataPacket and the Signature should not change
    internal func reencryptNodePassphrase(
        oldNodePassphrase: String,
        oldParentKey: String,
        oldParentPassphrase: String,
        newParentKey: String
    ) throws -> Armored {
        do {
            return try Encryptor.reencryptKeyPacket(
                of: oldNodePassphrase,
                oldParentKey: oldParentKey,
                oldParentPassphrase: oldParentPassphrase,
                newParentKey: newParentKey
            )
        } catch {
            ConsoleLogger.shared?.log(DecryptionError(error, "Node"))
            throw error
        }
    }
    
    internal func hashFilename(cleartext name: String) throws -> String {
        guard let parent = self.parentLink else {
            throw Errors.invalidFileMetadata
        }
        let parentNodeHashKey = try parent.decryptNodeHashKey()
        let hash = try Encryptor.hmac(filename: name, parentHashKey: parentNodeHashKey)
        return hash
    }
}

public extension File {
    
    internal func decryptContentKeyPacket() throws -> Data {
        do {
            guard let base64EncodedContentKeyPacket = contentKeyPacket,
                  let contentKeyPacket = Data(base64Encoded: base64EncodedContentKeyPacket) else {
                throw Errors.invalidFileMetadata
            }
            
            let creatorAddresKeys = try getAddressPublicKeys(email: signatureEmail)
            let nodePassphrase = try decryptPassphrase()
            let nodeDecryptionKey = DecryptionKey(privateKey: nodeKey, passphrase: nodePassphrase)
            let verificationKeys = [nodeKey] + creatorAddresKeys

            let decrypted = try Decryptor.decryptAndVerifyContentKeyPacket(
                contentKeyPacket,
                decryptionKey: nodeDecryptionKey,
                signature: contentKeyPacketSignature,
                verificationKeys: verificationKeys
            )

            switch decrypted {
            case .verified(let sessionKey):
                return sessionKey

                /*
                 Signature remarks:
                 1) Web is signing the session key while iOS and android were signing the key packet - for old iOS files verification needs to be done on content key as well if session key check fails.
                 2) Previosly the signature was made with the AddressKey but now it's done with the NodeKey
                 */
            case .unverified(let sessionKey, let error):
                ConsoleLogger.shared?.log(SignatureError(error, "File ContentKeyPacket"))
                return sessionKey
            }
        } catch {
            ConsoleLogger.shared?.log(DecryptionError(error, "File ContentKeyPacket"))
            throw error
        }
    }

    internal func generateContentKeyPacket(credentials: Encryptor.KeyCredentials, signersKit: SignersKit) throws -> RevisionContentKeys {
        try Encryptor.generateContentKeys(nodeKey: credentials.key, nodePassphrase: credentials.passphraseRaw)
    }
}

public extension Folder {
    
    internal func decryptNodeHashKey() throws -> String  {
        do {
            let nodePassphrase = try self.decryptPassphrase()
            let decryptionKey = DecryptionKey(privateKey: nodeKey, passphrase: nodePassphrase)

            guard let nodeHashKey = nodeHashKey else {
                throw Errors.invalidFileMetadata
            }
            
            let addressVerificationKeys = try getAddressPublicKeys(email: signatureEmail)
            let verificationKeys = [nodeKey] + addressVerificationKeys

            let decrypted = try Decryptor.decryptAndVerifyNodeHashKey(
                nodeHashKey,
                decryptionKeys: [decryptionKey],
                verificationKeys: verificationKeys
            )

            switch decrypted {
            case .verified(let nodeHashKey):
                return nodeHashKey

            case .unverified(let nodeHashKey, let error):
                ConsoleLogger.shared?.log(SignatureError(error, "Folder NodeHashKey"))
                return nodeHashKey
            }

        } catch {
            ConsoleLogger.shared?.log(DecryptionError(error, "Folder NodeHashKey"))
            throw error
        }
    }

    internal func generateHashKey(nodeKey: Encryptor.KeyCredentials) throws -> String {
        let hashKey = try Encryptor.generateNodeHashKey(
            nodeKey: nodeKey.key,
            passphrase: nodeKey.passphraseRaw
        )
        return hashKey
    }
}

extension SignersKit {
    typealias SigningKey = DecryptionKey

    var signingKey: SigningKey {
        SigningKey(privateKey: addressKey.privateKey, passphrase: addressPassphrase)
    }
}

public extension String {
    static var randomPlaceholder: String {
        var chars = Array(repeating: "☒", count: Int.random(in: 8..<15))
        for _ in 0 ..< Int.random(in: 0..<4) {
            chars.insert(" ", at: Int.random(in: 0 ..< chars.count))
        }
        return chars.joined()
    }
}
