//
//  Object+CKRecord.swift
//  IceCream
//
//  Created by 蔡越 on 11/11/2017.
//

import Foundation
import CloudKit
import RealmSwift

public protocol CKRecordConvertible {
    static var recordType: String { get }
    static var zoneID: CKRecordZone.ID { get }
    static var databaseScope: CKDatabase.Scope { get }
    
    var recordID: CKRecord.ID { get }
    var record: CKRecord { get }

    var isDeleted: Bool { get }
}

public protocol CKRecordZoneProvidable {
    /// Custom zone name the record should live in. `nil` falls back to the default zone.
    var icecreamZoneName: String? { get }
    
    /// Owner name for the custom zone. Required when `icecreamZoneName` is provided.
    var icecreamZoneOwnerName: String? { get }
    
    /// Optional override for the database scope. When `nil`, the default scope defined
    /// on the conforming type is used.
    var icecreamDatabaseScope: CKDatabase.Scope? { get }
}

extension CKRecordZoneProvidable {
    public var icecreamZoneName: String? { nil }
    public var icecreamZoneOwnerName: String? { nil }
    public var icecreamDatabaseScope: CKDatabase.Scope? { nil }
}

extension CKRecordConvertible where Self: Object {
    
    public static var databaseScope: CKDatabase.Scope {
        return .private
    }
    
    public static var recordType: String {
        return className()
    }
    
    public static var zoneID: CKRecordZone.ID {
        switch Self.databaseScope {
        case .private:
            return CKRecordZone.ID(zoneName: "\(recordType)sZone", ownerName: CKCurrentUserDefaultName)
        case .public:
            return CKRecordZone.default().zoneID
        case .shared:
            return CKRecordZone.ID(zoneName: "\(recordType)sZone", ownerName: CKCurrentUserDefaultName)
        @unknown default:
            return CKRecordZone.ID(zoneName: "\(recordType)sZone", ownerName: CKCurrentUserDefaultName)
        }
    }
    
    /// recordName : this is the unique identifier for the record, used to locate records on the database. We can create our own ID or leave it to CloudKit to generate a random UUID.
    /// For more: https://medium.com/@guilhermerambo/synchronizing-data-with-cloudkit-94c6246a3fda
    public var recordID: CKRecord.ID {
        guard let sharedSchema = Self.sharedSchema() else {
            fatalError("No schema settled. Go to Realm Community to seek more help.")
        }
        
        guard let primaryKeyProperty = sharedSchema.primaryKeyProperty else {
            fatalError("You should set a primary key on your Realm object")
        }
        
        switch primaryKeyProperty.type {
        case .string:
            if let primaryValueString = self[primaryKeyProperty.name] as? String {
                // For more: https://developer.apple.com/documentation/cloudkit/ckrecord/id/1500975-init
                assert(primaryValueString.allSatisfy({ $0.isASCII }), "Primary value for CKRecord name must contain only ASCII characters")
                assert(primaryValueString.count <= 255, "Primary value for CKRecord name must not exceed 255 characters")
                assert(!primaryValueString.starts(with: "_"), "Primary value for CKRecord name must not start with an underscore")
                return CKRecord.ID(recordName: primaryValueString, zoneID: resolvedZoneID())
            } else {
                assertionFailure("\(primaryKeyProperty.name)'s value should be String type")
            }
        case .int:
            if let primaryValueInt = self[primaryKeyProperty.name] as? Int {
                return CKRecord.ID(recordName: "\(primaryValueInt)", zoneID: resolvedZoneID())
            } else {
                assertionFailure("\(primaryKeyProperty.name)'s value should be Int type")
            }
        default:
            assertionFailure("Primary key should be String or Int")
        }
        fatalError("Should have a reasonable recordID")
    }
    
    // Simultaneously init CKRecord with zoneID and recordID, thanks to this guy: https://stackoverflow.com/questions/45429133/how-to-initialize-ckrecord-with-both-zoneid-and-recordid
    public var record: CKRecord {
        let r = CKRecord(recordType: Self.recordType, recordID: recordID)
        let properties = objectSchema.properties
        for prop in properties {
            
            let item = self[prop.name]
            
            if prop.isArray {
                switch prop.type {
                case .int:
                    guard let list = item as? List<Int>, !list.isEmpty else { break }
                    let array = Array(list)
                    r[prop.name] = array as CKRecordValue
                case .string:
                    guard let list = item as? List<String>, !list.isEmpty else { break }
                    let array = Array(list)
                    r[prop.name] = array as CKRecordValue
                case .bool:
                    guard let list = item as? List<Bool>, !list.isEmpty else { break }
                    let array = Array(list)
                    r[prop.name] = array as CKRecordValue
                case .float:
                    guard let list = item as? List<Float>, !list.isEmpty else { break }
                    let array = Array(list)
                    r[prop.name] = array as CKRecordValue
                case .double:
                    guard let list = item as? List<Double>, !list.isEmpty else { break }
                    let array = Array(list)
                    r[prop.name] = array as CKRecordValue
                case .data:
                    guard let list = item as? List<Data>, !list.isEmpty else { break }
                    let array = Array(list)
                    r[prop.name] = array as CKRecordValue
                case .date:
                    guard let list = item as? List<Date>, !list.isEmpty else { break }
                    let array = Array(list)
                    r[prop.name] = array as CKRecordValue
                case .object:
                    guard let collection = item as? any Collection else { break }
                    var referenceArray = [CKRecord.Reference]()
                    for element in collection {
                        guard let object = element as? Object,
                              let convertible = object as? CKRecordConvertible,
                              !convertible.isDeleted else { continue }
                        referenceArray.append(CKRecord.Reference(recordID: convertible.recordID, action: .none))
                    }
                    guard !referenceArray.isEmpty else { break }
                    r[prop.name] = referenceArray as CKRecordValue
                default:
                    break
                    /// Other inner types of List is not supported yet
                }
                continue
            }
            
            switch prop.type {
            case .int, .string, .bool, .date, .float, .double, .data:
                r[prop.name] = item as? CKRecordValue
            case .object:
                guard let objectName = prop.objectClassName else { break }
                if objectName == CreamLocation.className(), let creamLocation = item as? CreamLocation {
                    r[prop.name] = creamLocation.location
                } else if objectName == CreamAsset.className(), let creamAsset = item as? CreamAsset {
                    // If object is CreamAsset, set record with its wrapped CKAsset value
                    r[prop.name] = creamAsset.asset
                } else if let owner = item as? CKRecordConvertible {
                    // Handle to-one relationship: https://realm.io/docs/swift/latest/#many-to-one
                    // So the owner Object has to conform to CKRecordConvertible protocol
                    r[prop.name] = CKRecord.Reference(recordID: owner.recordID, action: .none)
                } else {
                    /// Just a warm hint:
                    /// When we set nil to the property of a CKRecord, that record's property will be hidden in the CloudKit Dashboard
                    r[prop.name] = nil
                }
            default:
                break
            }
            
        }
        return r
    }
    
    public func resolvedZoneID() -> CKRecordZone.ID {
        guard let provider = self as? CKRecordZoneProvidable,
              let zoneName = provider.icecreamZoneName,
              let ownerName = provider.icecreamZoneOwnerName else {
            return Self.zoneID
        }
        return CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName)
    }
    
    public func resolvedDatabaseScope() -> CKDatabase.Scope {
        if let provider = self as? CKRecordZoneProvidable,
           let scope = provider.icecreamDatabaseScope {
            return scope
        }
        return Self.databaseScope
    }
}
