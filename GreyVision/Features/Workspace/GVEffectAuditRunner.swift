#if DEBUG
    import Foundation

    /// Steps the live workspace through every effect for a visual and
    /// performance audit. Debug builds only, launched with `--effect-audit`.
    ///
    /// Each effect is applied exactly as the browser applies it, warmed up long
    /// enough for temporal history and flow to fill, and then held while a
    /// `GVAUDIT READY` line is logged with its measured GPU time and its
    /// *energy* — how much it actually changed the frame, from
    /// `GVEffectEnergyProbe`. An external script captures the screen on that
    /// line, so every frame on disk is the production graph rendering the
    /// production effect. Pair it with `--synthetic-still` for a photographic
    /// source, and add `--synthetic-still-static` to freeze it: an effect that
    /// only works on motion reads as dead on a static feed, which is exactly
    /// the case a phone on a tripod presents.
    ///
    /// `--effect-audit-only a,b,c` restricts the run to those raw values.
    @MainActor
    enum GVEffectAuditRunner {
        static let argument = "--effect-audit"
        static let onlyArgument = "--effect-audit-only"

        static var isRequested: Bool {
            ProcessInfo.processInfo.arguments.contains(argument)
        }

        static func run(
            editor: EffectEditingSession,
            audio: AudioReactiveRuntime,
            stats: CameraRenderStatsMailbox,
            hideChrome: (Bool) -> Void
        ) async {
            audio.beginAuditSignal()
            hideChrome(true)
            GVEffectEnergyProbe.isEnabled = true
            defer { GVEffectEnergyProbe.isEnabled = false }
            try? await Task.sleep(for: .seconds(2))
            let effects = selection(ProcessInfo.processInfo.arguments)
            GVLog.capture.notice("GVAUDIT BEGIN count=\(effects.count, privacy: .public)")
            for (index, effect) in effects.enumerated() {
                guard !Task.isCancelled else { return }
                editor.disableAll()
                editor.applyFromBrowser(effect)
                editor.focus(nil)
                try? await Task.sleep(for: .milliseconds(1_500))
                var samples: [Double] = []
                var energies: [Double] = []
                var shed = 0
                for _ in 0 ..< 24 {
                    let latest = stats.latest
                    samples.append(latest.gpuMilliseconds)
                    energies.append(GVEffectEnergyProbe.latest)
                    shed = max(shed, latest.shedEffects)
                    try? await Task.sleep(for: .milliseconds(50))
                }
                let average = samples.reduce(0, +) / Double(max(samples.count, 1))
                let peak = samples.max() ?? 0
                let energy = energies.reduce(0, +) / Double(max(energies.count, 1))
                let energyPeak = energies.max() ?? 0
                GVLog.capture.notice(
                    "GVAUDIT READY \(index, privacy: .public) \(effect.rawValue, privacy: .public) gpu=\(String(format: "%.2f", average), privacy: .public) max=\(String(format: "%.2f", peak), privacy: .public) shed=\(shed, privacy: .public) energy=\(String(format: "%.4f", energy), privacy: .public) epeak=\(String(format: "%.4f", energyPeak), privacy: .public)"
                )
                try? await Task.sleep(for: .milliseconds(ProcessInfo.processInfo.arguments.contains("--effect-audit-fast") ? 200 : 2_200))
            }
            editor.disableAll()
            GVLog.capture.notice("GVAUDIT DONE")
        }

        /// `--ar-objects` switches the workspace into AR Objects at launch, for
        /// checking ARKit on a device without driving the menu.
        static func enterARObjectsIfRequested(_ appModel: AppModel) async {
            guard ProcessInfo.processInfo.arguments.contains("--ar-objects") else { return }
            try? await Task.sleep(for: .seconds(2.5))
            GVLog.capture.notice("Audit: entering AR Objects")
            appModel.activateObjectMode()
        }

        /// `--apply-effect <raw value>` puts one effect on at launch, the way
        /// the browser would.
        static func applyEffectIfRequested(_ editor: EffectEditingSession) {
            let arguments = ProcessInfo.processInfo.arguments
            guard let flag = arguments.firstIndex(of: "--apply-effect"), arguments.indices.contains(flag + 1),
                  let effect = WorkspaceAdjustableEffect.resolving(arguments[flag + 1])
            else { return }
            editor.applyFromBrowser(effect)
            GVLog.capture.notice("Audit: applied \(effect.rawValue, privacy: .public)")
        }

        /// `--auto-record <seconds>` records one take after launch and stops
        /// it, so recording can be measured on a device nobody is holding.
        static func autoRecordIfRequested(
            capture: GVRecordingTransaction,
            camera: CameraRuntime,
            objects: ARObjectRuntime,
            sourceMode: @escaping () -> WorkspaceSourceMode
        ) async {
            let arguments = ProcessInfo.processInfo.arguments
            guard let flag = arguments.firstIndex(of: "--auto-record"), arguments.indices.contains(flag + 1),
                  let seconds = Double(arguments[flag + 1])
            else { return }
            try? await Task.sleep(for: .seconds(4))
            GVLog.recording.notice("Audit: auto-record \(seconds, privacy: .public)s")
            capture.toggleRecording(cameraRuntime: camera, objectsRuntime: objects, sourceMode: sourceMode())
            try? await Task.sleep(for: .seconds(seconds))
            capture.toggleRecording(cameraRuntime: camera, objectsRuntime: objects, sourceMode: sourceMode())
        }

        /// `--tracking-preset <id>` starts the tracking suite on a preset at
        /// launch, for checking overlays without driving the browser.
        static func applyTrackingPresetIfRequested(_ tracking: BlobTrackingRuntime) {
            let arguments = ProcessInfo.processInfo.arguments
            guard let flag = arguments.firstIndex(of: "--tracking-preset"), arguments.indices.contains(flag + 1),
                  let preset = GVTrackingPreset.all.first(where: { $0.id == arguments[flag + 1] })
            else { return }
            tracking.apply(preset)
        }

        private static func selection(_ arguments: [String]) -> [WorkspaceAdjustableEffect] {
            guard let flag = arguments.firstIndex(of: onlyArgument), arguments.indices.contains(flag + 1) else {
                return WorkspaceAdjustableEffect.allCases
            }
            return arguments[flag + 1].split(separator: ",").compactMap { WorkspaceAdjustableEffect(rawValue: String($0)) }
        }
    }
#endif
