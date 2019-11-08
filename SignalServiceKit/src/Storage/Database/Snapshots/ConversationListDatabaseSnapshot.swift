//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

import Foundation
import GRDB

@objc
public protocol ConversationListDatabaseSnapshotDelegate: AnyObject {
    func conversationListDatabaseSnapshotWillUpdate()
    func conversationListDatabaseSnapshotDidUpdate(updatedThreadIds: Set<String>)
    func conversationListDatabaseSnapshotDidUpdateExternally()
    func conversationListDatabaseSnapshotDidReset()
}

// MARK: -

@objc
public class ConversationListDatabaseObserver: NSObject {

    private var _snapshotDelegates: [Weak<ConversationListDatabaseSnapshotDelegate>] = []
    private var snapshotDelegates: [ConversationListDatabaseSnapshotDelegate] {
        AssertIsOnMainThread()
        return _snapshotDelegates.compactMap { $0.value }
    }

    @objc
    public func appendSnapshotDelegate(_ snapshotDelegate: ConversationListDatabaseSnapshotDelegate) {
        AssertIsOnMainThread()
        _snapshotDelegates = _snapshotDelegates.filter { $0.value != nil} + [Weak(value: snapshotDelegate)]
    }

    private typealias RowId = Int64
    private var threadChangeCollector = ThreadChangeCollector()

    private typealias ThreadUniqueId = String
    private var _committedThreadChanges: Set<ThreadUniqueId>?
    private var committedThreadChanges: Set<ThreadUniqueId>? {
        get {
            AssertIsOnMainThread()
            return _committedThreadChanges
        }

        set {
            AssertIsOnMainThread()
            _committedThreadChanges = newValue
        }
    }

    // internal - should only be called by DatabaseStorage
    func didTouch(thread: TSThread, transaction: GRDBWriteTransaction) {
        // Note: We don't actually use the `transaction` param, but touching must happen within
        // a write transaction in order for the touch machinery to notify it's observers
        // in the expected way.
        AssertIsOnUIDatabaseObserverSerialQueue()

        threadChangeCollector.append(thread: thread)
    }
}

extension ConversationListDatabaseObserver: DatabaseSnapshotDelegate {

    // MARK: - Transaction Lifecycle

    public func snapshotTransactionDidChange(with event: DatabaseEvent) {
        AssertIsOnUIDatabaseObserverSerialQueue()

        if event.tableName == ThreadRecord.databaseTableName {
            threadChangeCollector.append(rowId: event.rowID)
        }
    }

    public func snapshotTransactionDidCommit(db: Database) {
        AssertIsOnUIDatabaseObserverSerialQueue()

        do {
            let threadChangeCollector = self.threadChangeCollector
            self.threadChangeCollector = ThreadChangeCollector()
            let committedThreadChanges = try threadChangeCollector.threadUniqueIds(db: db)

            DispatchQueue.main.async {
                self.committedThreadChanges = committedThreadChanges
            }
        } catch {
            DispatchQueue.main.async {
                self.committedThreadChanges = nil
            }
        }
    }

    public func snapshotTransactionDidRollback(db: Database) {
        owsFailDebug("test this if we ever use it")
        AssertIsOnUIDatabaseObserverSerialQueue()

        threadChangeCollector = ThreadChangeCollector()
    }

    // MARK: - Snapshot LifeCycle (Post Commit)

    public func databaseSnapshotWillUpdate() {
        AssertIsOnMainThread()
        for delegate in snapshotDelegates {
            delegate.conversationListDatabaseSnapshotWillUpdate()
        }
    }

    public func databaseSnapshotDidUpdate() {
        AssertIsOnMainThread()
        do {
            guard let committedThreadChanges = self.committedThreadChanges else {
                throw OWSErrorMakeAssertionError("committedThreadChanges was unexpectedly nil")
            }
            self.committedThreadChanges = nil

            for delegate in snapshotDelegates {
                delegate.conversationListDatabaseSnapshotDidUpdate(updatedThreadIds: committedThreadChanges)
            }
        } catch DatabaseObserverError.changeTooLarge {
            for delegate in snapshotDelegates {
                delegate.conversationListDatabaseSnapshotDidReset()
            }
        } catch {
            owsFailDebug("unknown error: \(error)")
            for delegate in snapshotDelegates {
                delegate.conversationListDatabaseSnapshotDidReset()
            }
        }
    }

    public func databaseSnapshotDidUpdateExternally() {
        AssertIsOnMainThread()
        for delegate in snapshotDelegates {
            delegate.conversationListDatabaseSnapshotDidUpdateExternally()
        }
    }
}

// MARK: -

class ThreadChangeCollector {

    typealias RowId = Int64
    private var rowIds: Set<RowId> = Set()
    private var uniqueIds: Set<String> = Set()
    private var rowIdToUniqueIdMap = [RowId: String]()

    func append(rowId: RowId) {
        AssertIsOnUIDatabaseObserverSerialQueue()

        rowIds.insert(rowId)
    }

    func append(thread: TSThread) {
        AssertIsOnUIDatabaseObserverSerialQueue()

        uniqueIds.insert(thread.uniqueId)

        if let grdbId = thread.grdbId {
            rowIdToUniqueIdMap[grdbId.int64Value] = thread.uniqueId
        }
    }

    func threadUniqueIds(db: Database) throws -> Set<String> {
        AssertIsOnUIDatabaseObserverSerialQueue()

        // We try to avoid the query below by leveraging the
        // fact that we know the uniqueId and rowId for
        // touched threads.
        //
        // If a thread was touched _and_ modified, we don't need
        // can convert its rowId to a uniqueId without a query.
        var uniqueIds: Set<String> = self.uniqueIds
        var unresolvedRowIds = [RowId]()
        for rowId in rowIds {
            if let uniqueId = rowIdToUniqueIdMap[rowId] {
                uniqueIds.insert(uniqueId)
            } else {
                unresolvedRowIds.append(rowId)
            }
        }

        guard uniqueIds.count < UIDatabaseObserver.kMaxIncrementalRowChanges else {
            throw DatabaseObserverError.changeTooLarge
        }
        guard unresolvedRowIds.count < UIDatabaseObserver.kMaxIncrementalRowChanges else {
            throw DatabaseObserverError.changeTooLarge
        }

        guard unresolvedRowIds.count > 0 else {
            return uniqueIds
        }

        let commaSeparatedRowIds = unresolvedRowIds.map { String($0) }.joined(separator: ", ")
        let rowIdsSQL = "(\(commaSeparatedRowIds))"

        let sql = """
            SELECT \(threadColumn: .uniqueId)
            FROM \(ThreadRecord.databaseTableName)
            WHERE rowid IN \(rowIdsSQL)
        """

        let fetchedUniqueIds = try String.fetchAll(db, sql: sql)
        let allUniqueIds = uniqueIds.union(fetchedUniqueIds)

        guard allUniqueIds.count < UIDatabaseObserver.kMaxIncrementalRowChanges else {
            throw DatabaseObserverError.changeTooLarge
        }

        return allUniqueIds
    }
}
