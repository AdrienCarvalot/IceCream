//
//  SyncSource.swift
//  IceCream
//
//  Created by David Collado on 1/5/18.
//

import Foundation
import RealmSwift
import CloudKit

/// SyncObject is for each model you want to sync.
/// Logically,
/// 1. it takes care of the operations of CKRecordZone.
/// 2. it detects the changeSets of Realm Database and directly talks to it.
/// 3. it hands over to SyncEngine so that it can talk to CloudKit.

public final class SyncObject<T, U, V, W> where T: Object & CKRecordConvertible & CKRecordRecoverable, U: Object, V: Object, W: Object {
    
    /// Notifications are delivered as long as a reference is held to the returned notification token. We should keep a strong reference to this token on the class registering for updates, as notifications are automatically unregistered when the notification token is deallocated.
    /// For more, reference is here: https://realm.io/docs/swift/latest/#notifications
    private var notificationToken: NotificationToken?
    private let zoneIDResolver: () -> [CKRecordZone.ID]
    
    public var pipeToEngine: ((_ recordsToStore: [CKRecord], _ recordIDsToDelete: [CKRecord.ID]) -> ())?
    
    public let realmConfiguration: Realm.Configuration
    
    private let pendingUTypeRelationshipsWorker = PendingRelationshipsWorker<U>()
    private let pendingVTypeRelationshipsWorker = PendingRelationshipsWorker<V>()
    private let pendingWTypeRelationshipsWorker = PendingRelationshipsWorker<W>()
    
    public init(
        realmConfiguration: Realm.Configuration = .defaultConfiguration,
        type: T.Type,
        uListElementType: U.Type? = nil,
        vListElementType: V.Type? = nil,
        wListElementType: W.Type? = nil,
        zoneIDResolver: (() -> [CKRecordZone.ID])? = nil
    ) {
        self.realmConfiguration = realmConfiguration
        self.zoneIDResolver = zoneIDResolver ?? { [recordType = T.recordType, ownerName = CKCurrentUserDefaultName] in
            let zoneID = CKRecordZone.ID(zoneName: "\(recordType)sZone", ownerName: ownerName)
            return [zoneID]
        }
    }
    
}

// MARK: - Zone information

extension SyncObject: Syncable {
    
    public var recordType: String {
        return T.recordType
    }
    
    public var zoneIDs: [CKRecordZone.ID] {
        let ids = zoneIDResolver().filter { !$0.zoneName.isEmpty }
        return Array(Set(ids))
    }
    
    public func zoneChangesToken(for zoneID: CKRecordZone.ID) -> CKServerChangeToken? {
        guard let tokenData = UserDefaults.standard.object(forKey: changeTokenKey(for: zoneID)) as? Data else { return nil }
        return NSKeyedUnarchiver.unarchiveObject(with: tokenData) as? CKServerChangeToken
    }
    
    public func setZoneChangesToken(_ token: CKServerChangeToken?, for zoneID: CKRecordZone.ID) {
        let key = changeTokenKey(for: zoneID)
        guard let token else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        let data = NSKeyedArchiver.archivedData(withRootObject: token)
        UserDefaults.standard.set(data, forKey: key)
    }

    public func isCustomZoneCreated(for zoneID: CKRecordZone.ID) -> Bool {
        guard let flag = UserDefaults.standard.object(forKey: customZoneCreatedKey(for: zoneID)) as? Bool else { return false }
        return flag
    }
    
    public func setCustomZoneCreated(_ newValue: Bool, for zoneID: CKRecordZone.ID) {
        UserDefaults.standard.set(newValue, forKey: customZoneCreatedKey(for: zoneID))
    }
    
    public func add(record: CKRecord) {
        BackgroundWorker.shared.start {
            let realm = try! Realm(configuration: self.realmConfiguration)
            guard let object = T.parseFromRecord(
                record: record,
                realm: realm,
                notificationToken: self.notificationToken,
                pendingUTypeRelationshipsWorker: self.pendingUTypeRelationshipsWorker,
                pendingVTypeRelationshipsWorker: self.pendingVTypeRelationshipsWorker,
                pendingWTypeRelationshipsWorker: self.pendingWTypeRelationshipsWorker
            ) else {
                print("There is something wrong with the converson from cloud record to local object")
                return
            }
            self.pendingUTypeRelationshipsWorker.realm = realm
            self.pendingVTypeRelationshipsWorker.realm = realm
            self.pendingWTypeRelationshipsWorker.realm = realm
            
            /// If your model class includes a primary key, you can have Realm intelligently update or add objects based off of their primary key values using Realm().add(_:update:).
            /// https://realm.io/docs/swift/latest/#objects-with-primary-keys
            realm.beginWrite()
            realm.add(object, update: .modified)
            if let token = self.notificationToken {
                try! realm.commitWrite(withoutNotifying: [token])
            } else {
                try! realm.commitWrite()
            }
        }
    }
    
    public func delete(recordID: CKRecord.ID) {
        BackgroundWorker.shared.start {
            let realm = try! Realm(configuration: self.realmConfiguration)
            guard let object = realm.object(ofType: T.self, forPrimaryKey: T.primaryKeyForRecordID(recordID: recordID)) else {
                // Not found in local realm database
                return
            }
            CreamAsset.deleteCreamAssetFile(with: recordID.recordName)
            realm.beginWrite()
            realm.delete(object)
            if let token = self.notificationToken {
                try! realm.commitWrite(withoutNotifying: [token])
            } else {
                try! realm.commitWrite()
            }
        }
    }
    
    /// When you commit a write transaction to a Realm, all other instances of that Realm will be notified, and be updated automatically.
    /// For more: https://realm.io/docs/swift/latest/#writes
    public func registerLocalDatabase() {
        BackgroundWorker.shared.start {
            let realm = try! Realm(configuration: self.realmConfiguration)
            self.notificationToken = realm.objects(T.self).observe({ [weak self](changes) in
                guard let self = self else { return }
                switch changes {
                case .initial(_):
                    break
                case .update(let collection, _, let insertions, let modifications):
                    let recordsToStore = (insertions + modifications).filter { $0 < collection.count }.map { collection[$0] }.filter{ !$0.isDeleted }.map { $0.record }
                    let recordIDsToDelete = modifications.filter { $0 < collection.count }.map { collection[$0] }.filter { $0.isDeleted }.map { $0.recordID }
                    
                    guard recordsToStore.count > 0 || recordIDsToDelete.count > 0 else { return }
                    self.pipeToEngine?(recordsToStore, recordIDsToDelete)
                case .error(_):
                    break
                }
            })
        }
    }
    
    public func resolvePendingRelationships() {
        pendingUTypeRelationshipsWorker.resolvePendingListElements()
        pendingVTypeRelationshipsWorker.resolvePendingListElements()
        pendingWTypeRelationshipsWorker.resolvePendingListElements()
    }
    
    public func cleanUp() {
        BackgroundWorker.shared.start {
            let realm = try! Realm(configuration: self.realmConfiguration)
            let objects = realm.objects(T.self).filter { $0.isDeleted }
            
            var tokens: [NotificationToken] = []
            self.notificationToken.flatMap { tokens = [$0] }
            
            realm.beginWrite()
            objects.forEach({ realm.delete($0) })
            do {
                try realm.commitWrite(withoutNotifying: tokens)
            } catch {
                
            }
        }
    }
    
    public func pushLocalObjectsToCloudKit() {
        let realm = try! Realm(configuration: self.realmConfiguration)
        let recordsToStore: [CKRecord] = realm.objects(T.self).filter { !$0.isDeleted }.map { $0.record }
        pipeToEngine?(recordsToStore, [])
    }
    
    private func changeTokenKey(for zoneID: CKRecordZone.ID) -> String {
        return "\(T.className()).\(zoneID.ownerName).\(zoneID.zoneName).\(IceCreamKey.zoneChangesTokenKey.value)"
    }
    
    private func customZoneCreatedKey(for zoneID: CKRecordZone.ID) -> String {
        return "\(T.className()).\(zoneID.ownerName).\(zoneID.zoneName).\(IceCreamKey.hasCustomZoneCreatedKey.value)"
    }
    
}
