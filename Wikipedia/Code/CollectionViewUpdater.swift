import Foundation

protocol CollectionViewUpdaterDelegate: NSObjectProtocol {
    func collectionViewUpdater<T>(_ updater: CollectionViewUpdater<T>, didUpdate collectionView: UICollectionView)
}

class CollectionViewUpdater<T: NSFetchRequestResult>: NSObject, NSFetchedResultsControllerDelegate {
    
    let fetchedResultsController: NSFetchedResultsController<T>
    let collectionView: UICollectionView
    var isSlidingNewContentInFromTheTopEnabled: Bool = false
    var sectionChanges: [WMFSectionChange] = []
    var objectChanges: [WMFObjectChange] = []
    weak var delegate: CollectionViewUpdaterDelegate?
    
    required init(fetchedResultsController: NSFetchedResultsController<T>, collectionView: UICollectionView) {
        self.fetchedResultsController = fetchedResultsController
        self.collectionView = collectionView
        super.init()
        self.fetchedResultsController.delegate = self
        self.collectionView.reloadData()
        self.updateSectionCounts()
    }
    
    deinit {
        self.fetchedResultsController.delegate = nil
    }
    
    @objc func controllerWillChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
        sectionChanges = []
        objectChanges = []
    }
    
    @objc func controller(_ controller: NSFetchedResultsController<NSFetchRequestResult>, didChange anObject: Any, at indexPath: IndexPath?, for type: NSFetchedResultsChangeType, newIndexPath: IndexPath?) {
        let objectChange = WMFObjectChange()
        objectChange.fromIndexPath = indexPath
        objectChange.toIndexPath = newIndexPath
        objectChange.type = type
        objectChanges.append(objectChange)
    }
    
    @objc func controller(_ controller: NSFetchedResultsController<NSFetchRequestResult>, didChange sectionInfo: NSFetchedResultsSectionInfo, atSectionIndex sectionIndex: Int, for type: NSFetchedResultsChangeType) {
        let sectionChange = WMFSectionChange()
        sectionChange.sectionIndex = sectionIndex
        sectionChange.type = type
        sectionChanges.append(sectionChange)
    }
    
    private var sectionCounts: [Int] = []
    private func updateSectionCounts() {
        let sections = fetchedResultsController.sections ?? []
        sectionCounts = sections.map { $0.numberOfObjects }
    }
    
    @objc func controllerDidChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
        let previousSectionCounts = self.sectionCounts
        updateSectionCounts()
        let sectionCounts = self.sectionCounts
        var didInsertFirstSection = false
        var didOnlyChangeItems = true
        var sectionDelta = 0
        for sectionChange in sectionChanges {
            didOnlyChangeItems = false
            switch sectionChange.type {
            case .delete:
                sectionDelta -= 1
            case .insert:
                sectionDelta += 1
                if sectionChange.sectionIndex == 0 {
                    didInsertFirstSection = true
                }
            default:
                break
            }
        }
        
        let sectionCountsMatch = (previousSectionCounts.count + sectionDelta) == sectionCounts.count
        guard sectionCountsMatch, objectChanges.count < 1000 && sectionChanges.count < 10 else { // reload data for larger changes
            collectionView.reloadData()
            self.delegate?.collectionViewUpdater(self, didUpdate: self.collectionView)
            return
        }
        
        guard isSlidingNewContentInFromTheTopEnabled else {
            performBatchUpdates(sectionCounts: sectionCounts, previousSectionCounts: previousSectionCounts)
            return
        }

        guard let columnarLayout = collectionView.collectionViewLayout as? ColumnarCollectionViewLayout else {
            performBatchUpdates(sectionCounts: sectionCounts, previousSectionCounts: previousSectionCounts)
            return
        }
        
        guard previousSectionCounts.count > 0 && didInsertFirstSection && sectionDelta > 0 else {
            if didOnlyChangeItems {
                columnarLayout.animateItems = true
                columnarLayout.slideInNewContentFromTheTop = false
                UIView.animate(withDuration: 0.8, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0, options: .allowUserInteraction, animations: {
                    self.performBatchUpdates(sectionCounts: sectionCounts, previousSectionCounts: previousSectionCounts)
                }, completion: nil)
            } else {
                columnarLayout.animateItems = false
                columnarLayout.slideInNewContentFromTheTop = false
                performBatchUpdates(sectionCounts: sectionCounts, previousSectionCounts: previousSectionCounts)
            }
            return
        }
        columnarLayout.animateItems = true
        columnarLayout.slideInNewContentFromTheTop = true
        UIView.animate(withDuration: 0.7 + 0.1 * TimeInterval(sectionDelta), delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0, options: .allowUserInteraction, animations: {
            self.performBatchUpdates(sectionCounts: sectionCounts, previousSectionCounts: previousSectionCounts)
        }, completion: nil)
    }
    
    func performBatchUpdates(sectionCounts: [Int], previousSectionCounts: [Int]) {
        let collectionView = self.collectionView
        collectionView.performBatchUpdates({
            DDLogDebug("=== WMFBU BATCH UPDATE START ===")
            let insertedSections = NSMutableIndexSet()
            let deletedSections = NSMutableIndexSet()
            let updatedSections = NSMutableIndexSet()
            
            for sectionChange in sectionChanges {
                switch sectionChange.type {
                case .delete:
                    DDLogDebug("WMFBU section delete: \(sectionChange.sectionIndex)")
                    collectionView.deleteSections(IndexSet(integer: sectionChange.sectionIndex))
                    deletedSections.add(sectionChange.sectionIndex)
                case .insert:
                    DDLogDebug("WMFBU section insert: \(sectionChange.sectionIndex)")
                    collectionView.insertSections(IndexSet(integer: sectionChange.sectionIndex))
                    insertedSections.add(sectionChange.sectionIndex)
                default:
                    DDLogDebug("WMFBU section update: \(sectionChange.sectionIndex)")
                    collectionView.reloadSections(IndexSet(integer: sectionChange.sectionIndex))
                    updatedSections.add(sectionChange.sectionIndex)
                }
            }
            for objectChange in objectChanges {
                switch objectChange.type {
                case .delete:
                    if let fromIndexPath = objectChange.fromIndexPath {
                        if !deletedSections.contains(fromIndexPath.section) {
                            DDLogDebug("WMFBU object delete: \(fromIndexPath)")
                            collectionView.deleteItems(at: [fromIndexPath])
                        }
                    }
                case .insert:
                    if let toIndexPath = objectChange.toIndexPath {
                        DDLogDebug("WMFBU object insert: \(toIndexPath)")
                        collectionView.insertItems(at: [toIndexPath])
                    }
                case .move:
                    DDLogDebug("WMFBU object move (fallthrough)")
                    fallthrough
                default:
                    if let fromIndexPath = objectChange.fromIndexPath, let toIndexPath = objectChange.toIndexPath, toIndexPath != fromIndexPath {
                        DDLogDebug("WMFBU object move: \(fromIndexPath) \(toIndexPath)")
                        if deletedSections.contains(fromIndexPath.section) {
                            DDLogDebug("WMFBU inserting: \(toIndexPath)")
                            collectionView.insertItems(at: [toIndexPath])
                        } else {
                            DDLogDebug("WMFBU moving: \(fromIndexPath) \(toIndexPath)")
                            collectionView.moveItem(at: fromIndexPath, to: toIndexPath)
                        }
                    } else if let updatedIndexPath = objectChange.toIndexPath ?? objectChange.fromIndexPath {
                        DDLogDebug("WMFBU object update: \(updatedIndexPath)")
                        if insertedSections.contains(updatedIndexPath.section) {
                            DDLogDebug("WMFBU inserting: \(updatedIndexPath)")
                            collectionView.insertItems(at: [updatedIndexPath])
                        } else {
                            DDLogDebug("WMFBU reloading: \(updatedIndexPath)")
                            collectionView.reloadItems(at: [updatedIndexPath])
                        }
                    } else {
                        DDLogDebug("WMFBU unhandled update: \(objectChange)")
                    }
                }
            }
            DDLogDebug("=== WMFBU BATCH UPDATE END ===")
        }) { (done) in
            self.delegate?.collectionViewUpdater(self, didUpdate: collectionView)
        }
    }
    
}
