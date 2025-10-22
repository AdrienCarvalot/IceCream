//
//  Syncable.swift
//  IceCream
//
//  Created by 蔡越 on 24/05/2018.
//

import Foundation
import CloudKit
import RealmSwift

/// Since `sync` is an informal version of `synchronize`, so we choose the `syncable` word for
/// the ability of synchronization.
public protocol Syncable: AnyObject {
    
    /// CKRecordZone related
    var recordType: String { get }
    
    /// All zones the sync object should observe.
    /// Implementations may return an empty array if no zones are yet known.
    var zoneIDs: [CKRecordZone.ID] { get }
    
    /// Local storage
    func zoneChangesToken(for zoneID: CKRecordZone.ID) -> CKServerChangeToken?
    func setZoneChangesToken(_ token: CKServerChangeToken?, for zoneID: CKRecordZone.ID)
    
    func isCustomZoneCreated(for zoneID: CKRecordZone.ID) -> Bool
    func setCustomZoneCreated(_ newValue: Bool, for zoneID: CKRecordZone.ID)
    
    /// Realm Database related
    func registerLocalDatabase()
    func cleanUp()
    func add(record: CKRecord)
    func delete(recordID: CKRecord.ID)
    
    func resolvePendingRelationships()
    
    /// CloudKit related
    func pushLocalObjectsToCloudKit()
    
    /// Callback
    var pipeToEngine: ((_ recordsToStore: [CKRecord], _ recordIDsToDelete: [CKRecord.ID]) -> ())? { get set }
    
}
