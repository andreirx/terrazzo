//
//  ScanController.swift — drives the live scan into the canvas + status bar.
//  Module maturity: PROTOTYPE (slice TZ-2)
//
//  The App-layer coordinator that closes the streaming loop: it owns the PURE
//  `ScanReducer`, consumes the walker's `AsyncStream<[ScanEvent]>`, and folds
//  every batch on the MAIN ACTOR — which is how the reducer stays single-threaded
//  (ratified decision 5) even though the walker is massively parallel. The
//  concurrency was already dissolved into an ordered event stream by ScanFS's
//  EventBatcher; here we just apply it on one thread.
//
//  RELAYOUT CADENCE (ratified decision 3): a ~1 s timer snapshots the reducer
//  into a SizeTree and hands it to the canvas, which animates the ~300 ms rect
//  lerp. We deliberately do NOT relayout per batch — batched, calm, never
//  jittering. Sizes shown are always real recursive totals; the depth window
//  (policy) prunes only retained child detail (decision 4).
//
//  This is App-layer glue (I/O/UI side), instantiated by AppDelegate (the Main
//  assembly). Not a core abstraction — a single concrete coordinator with one
//  caller; no protocol, no seam invented.
//

import AppKit

@MainActor
final class ScanController {
    /// Relayout cadence — ratified decision 3 ("batched ~1 s, animated").
    static let relayoutCadenceSeconds: TimeInterval = 1.0

    private let root: URL
    private let policy: ScanPolicy
    private weak var canvas: CanvasView?
    private let onStatus: (ScanStatus) -> Void

    private var reducer: ScanReducer
    private var scanTask: Task<Void, Never>?
    private var relayoutTimer: Timer?
    private var volume: VolumeProbe.VolumeInfo?
    private var running = false

    init(root: URL, policy: ScanPolicy, canvas: CanvasView,
         onStatus: @escaping (ScanStatus) -> Void) {
        self.root = root
        self.policy = policy
        self.canvas = canvas
        self.onStatus = onStatus
        self.reducer = ScanReducer(rootId: root.path, rootName: root.lastPathComponent)
    }

    func start() {
        volume = VolumeProbe.volumeInfo(for: root)
        running = true

        // Consume the stream on the main actor → the reducer is only ever touched
        // from one thread. The walk itself runs off-main (the AsyncStream's
        // internal Task), so folding here does not block the walk.
        scanTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await batch in FileSystemWalker.scan(root: self.root, policy: self.policy) {
                self.reducer.apply(batch)
            }
            self.running = false
            self.relayout()            // final settle
            self.relayoutTimer?.invalidate()
            self.relayoutTimer = nil
        }

        // Batched relayout cadence.
        let timer = Timer(timeInterval: Self.relayoutCadenceSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayout() }
        }
        RunLoop.main.add(timer, forMode: .common)
        relayoutTimer = timer

        relayout() // initial frame (root tile, empty/pending)
    }

    func cancel() {
        scanTask?.cancel()
        relayoutTimer?.invalidate()
        relayoutTimer = nil
    }

    private func relayout() {
        let tree = reducer.makeTree(depthWindow: policy.depthDetailWindow)
        canvas?.updateTree(tree)
        onStatus(ScanStatus(volume: volume, scannedBytes: tree.allocatedBytes, running: running))
    }
}
