//
//  DiagnosticsLogger.swift
//  MeloNX
//
//  Lightweight on-device audit log. Persists diagnostics to
//  Documents/melonx_diag.log so they can be exported via the Files app.
//
//  Goal: give visibility we can't get over USB/network (iOS is not ADB).
//  Captures RAM footprint, available RAM before jetsam, ROM source
//  (internal vs external drive) and disk read latency.
//

import Foundation

#if canImport(os)
import os
#endif

final class DiagnosticsLogger {

    static let shared = DiagnosticsLogger()

    private let queue = DispatchQueue(label: "com.melonx.diaglog")
    private let fileURL: URL
    private var sampler: DispatchSourceTimer?
    private let startDate = Date()

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        fileURL = docs.appendingPathComponent("melonx_diag.log")
    }

    // MARK: - Public API

    /// Log a single timestamped event. `category` groups related entries,
    /// e.g. "LAUNCH", "ROM", "DISK", "EVICT".
    func event(_ category: String, _ message: String) {
        let line = "[\(timestamp())] [\(category)] \(message)\n"
        append(line)
        #if canImport(os)
        os_log("%{public}@", "[\(category)] \(message)")
        #endif
    }

    /// Begin periodic sampling of memory pressure (1 Hz). Idempotent.
    func startSampling() {
        queue.async { [weak self] in
            guard let self, self.sampler == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 1.0)
            timer.setEventHandler { [weak self] in self?.sampleMemory() }
            self.sampler = timer
            timer.resume()
            self.event("DIAG", "sampling started")
        }
    }

    func stopSampling() {
        queue.async { [weak self] in
            self?.sampler?.cancel()
            self?.sampler = nil
            self?.event("DIAG", "sampling stopped")
        }
    }

    /// Measure how long it takes to read the first chunk of a file.
    /// On a mechanical HDD this exposes seek/spin-up latency; on internal
    /// storage / SSD it should be sub-millisecond.
    func probeReadLatency(_ url: URL, bytes: Int = 4 * 1024 * 1024) {
        queue.async { [weak self] in
            guard let self else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                self.event("DISK", "probe failed: cannot open \(url.lastPathComponent)")
                return
            }
            defer { try? handle.close() }
            let t0 = DispatchTime.now()
            let data = try? handle.read(upToCount: bytes)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000.0
            let read = data?.count ?? 0
            let mbps = ms > 0 ? (Double(read) / 1_048_576.0) / (ms / 1000.0) : 0
            self.event("DISK", String(format: "read %d KB in %.1f ms (%.0f MB/s) from %@",
                                       read / 1024, ms, mbps, url.lastPathComponent))
        }
    }

    /// Returns the full log as text (for an in-app share sheet, if desired).
    func currentLogText() -> String {
        (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }

    func clear() {
        queue.async { [weak self] in
            guard let self else { return }
            try? FileManager.default.removeItem(at: self.fileURL)
            self.event("DIAG", "log cleared")
        }
    }

    // MARK: - Internals

    private func sampleMemory() {
        let footprint = Self.physFootprint()
        var line = String(format: "footprint=%.0f MB", Double(footprint) / 1_048_576.0)
        if #available(iOS 13.0, *) {
            let avail = os_proc_available_memory()
            line += String(format: " available=%.0f MB", Double(avail) / 1_048_576.0)
        }
        event("MEM", line)
        dumpEngineLogs()
    }

    /// Mirror the in-memory Ryujinx engine logs (captured by LogCapture) to a
    /// file so they survive a hang and can be exported via the Files app. The
    /// stdout-redirected MeloNX-App-Log stays empty because LogCapture owns the
    /// pipe, so this is the only on-disk copy of what the emulator is doing.
    private func dumpEngineLogs() {
        let logs = LogCapture.shared.capturedLogs
        guard !logs.isEmpty else { return }
        let text = logs.suffix(2000).joined(separator: "\n")
        let url = fileURL.deletingLastPathComponent().appendingPathComponent("melonx_engine.log")
        try? text.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    static func physFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    private func append(_ line: String) {
        queue.async { [weak self] in
            guard let self, let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: self.fileURL) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            } else {
                try? data.write(to: self.fileURL, options: .atomic)
            }
        }
    }

    private func timestamp() -> String {
        String(format: "%8.3f", Date().timeIntervalSince(startDate))
    }
}
