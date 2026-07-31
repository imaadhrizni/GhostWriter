import AppKit
import Foundation

// MARK: - Meeting Audio Processing

/// Segment-level audio handling for meeting mode: microphone ("You") capture
/// with echo suppression, system-audio ("Them") buffering with voice-based
/// diarization, and the failed-segment retry queue that recovers transcripts
/// dropped by a transient network blip. Split out of `AppDelegate`; all state
/// still lives on the delegate.
extension AppDelegate {

    // MARK: - Mic Capture (self) in Meeting Mode

    func setupMicMeetingCallback() {
        let vad = VoiceActivityDetector()
        micCapture.onAudioBuffer = { [weak self] buffer in
            guard let self, !self.isTranscriptionPaused else { return }
            self.audioRetainer?.appendMic(buffer)
            let rms = vad.calculateRMS(from: buffer)
            let isVoice = vad.rmsToDBFS(rms) >= self.settings.meetingMicThreshold  // mic threshold — louder than system audio
            self.micMeetingQueue.async { [weak self] in
                self?.processMicMeetingBuffer(buffer, isVoice: isVoice)
            }
        }
        micCapture.start()
    }

    func processMicMeetingBuffer(_ buffer: Data, isVoice: Bool) {
        let now = Date()

        // Echo suppression: if the speaker was active within the gate window, the
        // mic is almost certainly hearing the remote party through the speaker, not
        // the local user. Drop it so it isn't mislabeled as "You".
        var speakerActive = false
        if settings.echoSuppressionEnabled {
            echoGateLock.lock()
            if let last = speakerLastActiveTime, now.timeIntervalSince(last) < echoGateWindow {
                speakerActive = true
            }
            echoGateLock.unlock()
        }

        let isVoice = isVoice && !speakerActive

        if isVoice {
            if micMeetingSpeechBuffer.isEmpty { micMeetingSegmentStart = now }
            micMeetingSpeechBuffer.append(buffer)
            micMeetingLastVoiceTime = now
            if let start = micMeetingSegmentStart,
               now.timeIntervalSince(start) >= meetingMaxSegmentSeconds {
                flushMicMeetingSegment()
            }
        } else if let lastVoice = micMeetingLastVoiceTime,
                  now.timeIntervalSince(lastVoice) >= meetingSilenceDebounce,
                  !micMeetingSpeechBuffer.isEmpty {
            flushMicMeetingSegment()
        }
    }

    func flushMicMeetingSegment() {
        let captured = micMeetingSpeechBuffer
        // Stamp lines with when the speech was captured, not when the API
        // returns — keeps interleaved You/Them lines in true order.
        let capturedAt = micMeetingSegmentStart ?? Date()
        micMeetingSpeechBuffer = Data()
        micMeetingLastVoiceTime = nil
        micMeetingSegmentStart = nil

        let minBytes = 16000 * 2 / 2
        guard captured.count >= minBytes else { return }

        beginPendingTranscription()
        Task {
            defer { self.endPendingTranscription() }
            do {
                let text = try await transcribeWithFallback(captured, context: self.meetingNotes.promptContext)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      !self.whisperHallucinations.contains(trimmed.lowercased()) else { return }
                Log.meeting.debug("🎤 You: \(trimmed, privacy: .private)")
                self.meetingNotes.append(segment: trimmed, speaker: "You", at: capturedAt)
            } catch {
                Log.meeting.error("❌ Mic transcription error: \(error.localizedDescription)")
                await MainActor.run { [weak self] in
                    self?.enqueueFailedSegment(audio: captured, speaker: "You", capturedAt: capturedAt)
                }
            }
        }
    }

    func processMeetingBuffer(_ buffer: Data, isVoice: Bool, rms: Float) {
        // Must be called on meetingQueue
        let now = Date()

        if isVoice {
            // Mark the speaker as active so the mic path can suppress echo.
            echoGateLock.lock()
            speakerLastActiveTime = now
            echoGateLock.unlock()

            if meetingSpeechBuffer.isEmpty {
                meetingSegmentStart = now
                DispatchQueue.main.async { [weak self] in
                    self?.appState.isSpeakerActive = true
                    self?.appState.audioLevel = rms
                }
            }
            meetingSpeechBuffer.append(buffer)
            meetingLastVoiceTime = now

            // Flush if segment is too long (Whisper's 25s limit)
            if let start = meetingSegmentStart,
               now.timeIntervalSince(start) >= meetingMaxSegmentSeconds {
                flushMeetingSegment()
            }
        } else {
            // Update UI level
            DispatchQueue.main.async { [weak self] in
                self?.appState.audioLevel = rms
            }

            // Check if we've been silent long enough after speech
            if let lastVoice = meetingLastVoiceTime,
               now.timeIntervalSince(lastVoice) >= meetingSilenceDebounce,
               !meetingSpeechBuffer.isEmpty {
                flushMeetingSegment()
                DispatchQueue.main.async { [weak self] in
                    self?.appState.isSpeakerActive = false
                }
            }
        }
    }

    // MARK: - Failed-Segment Retry Queue

    /// Queue a failed segment for retry (main thread).
    func enqueueFailedSegment(audio: Data, speaker: String, capturedAt: Date) {
        retryQueue.append(PendingSegment(audio: audio, speaker: speaker, capturedAt: capturedAt, attempts: 1))
        Log.meeting.warning("⚠️ Segment transcription failed — queued for retry (\(self.retryQueue.count) pending)")
        if retryTimer == nil {
            retryTimer = Timer.scheduledTimer(
                timeInterval: max(5, settings.retryIntervalSeconds), target: self,
                selector: #selector(drainRetryQueue), userInfo: nil, repeats: true)
        }
    }

    @objc func drainRetryQueue() {
        guard !retryQueue.isEmpty else {
            retryTimer?.invalidate(); retryTimer = nil
            return
        }
        let pending = retryQueue
        retryQueue.removeAll()

        Task { @MainActor [weak self] in
            guard let self else { return }
            for var segment in pending {
                do {
                    let text = try await self.transcribeWithFallback(segment.audio, context: self.meetingNotes.promptContext)
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, !self.whisperHallucinations.contains(trimmed.lowercased()) {
                        self.meetingNotes.append(segment: trimmed, speaker: segment.speaker, at: segment.capturedAt)
                        Log.meeting.info("✅ Recovered segment from \(segment.capturedAt)")
                    }
                } catch {
                    segment.attempts += 1
                    if segment.attempts >= self.maxRetryAttempts {
                        self.writeFailureMarker(for: segment)
                    } else {
                        self.retryQueue.append(segment)
                    }
                }
            }
            if self.retryQueue.isEmpty {
                self.retryTimer?.invalidate(); self.retryTimer = nil
            }
        }
    }

    /// A gap should be visible in the notes, not silent.
    func writeFailureMarker(for segment: PendingSegment) {
        let seconds = segment.audio.count / (16000 * 2)
        meetingNotes.appendMarker("⚠️ Transcription failed for a \(seconds)s segment captured around this time")
        Log.meeting.error("❌ Gave up on segment from \(segment.capturedAt) after \(self.maxRetryAttempts) attempts")
    }

    /// Wait for in-flight segment transcriptions to finish (bounded).
    func waitForPendingTranscriptions(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while pendingTranscriptions > 0 && Date() < deadline {
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        if pendingTranscriptions > 0 {
            Log.meeting.warning("⚠️ \(self.pendingTranscriptions) transcription(s) still pending at meeting end — proceeding")
        }
    }

    /// At meeting end: one final retry for queued failures, then whatever is
    /// still failing becomes a visible marker before the file is finalized.
    @MainActor
    func finalRetryPass() async {
        retryTimer?.invalidate(); retryTimer = nil
        let pending = retryQueue
        retryQueue.removeAll()

        for segment in pending {
            do {
                let text = try await transcribeWithFallback(segment.audio, context: meetingNotes.promptContext)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, !whisperHallucinations.contains(trimmed.lowercased()) {
                    meetingNotes.append(segment: trimmed, speaker: segment.speaker, at: segment.capturedAt)
                }
            } catch {
                writeFailureMarker(for: segment)
            }
        }
    }

    /// Experimental voice-based diarization for remote audio: each segment's
    /// voice fingerprint (pitch, timbre) is clustered into speaker profiles,
    /// so distinct voices get distinct labels (Them / Them 2 / …).
    /// Must be called on meetingQueue.
    func diarizedSpeakerLabel(for audio: Data) -> String {
        guard settings.diarizationEnabled else { return "Them" }
        return speakerProfiler.label(for: audio)
    }

    func flushMeetingSegment() {
        // Must be called on meetingQueue
        let capturedAudio = meetingSpeechBuffer
        let capturedAt = meetingSegmentStart ?? Date()
        meetingSpeechBuffer = Data()
        meetingLastVoiceTime = nil
        meetingSegmentStart = nil

        guard !capturedAudio.isEmpty else { return }

        // Require at least 0.5s of audio (16kHz × 2 bytes × 0.5s = 16000 bytes)
        // Whisper hallucinates on very short clips
        let minBytes = 16000 * 2 / 2  // 0.5s at 16kHz Int16
        guard capturedAudio.count >= minBytes else {
            Log.meeting.debug("⏭ Segment too short (\(capturedAudio.count) bytes), skipping")
            return
        }

        let speakerLabel = diarizedSpeakerLabel(for: capturedAudio)

        beginPendingTranscription()
        Task {
            defer { self.endPendingTranscription() }
            do {
                let text = try await transcribeWithFallback(capturedAudio, context: self.meetingNotes.promptContext)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }

                // Discard known Whisper hallucinations
                guard !self.whisperHallucinations.contains(trimmed.lowercased()) else {
                    Log.meeting.debug("⏭ Filtered hallucination: '\(trimmed, privacy: .private)'")
                    return
                }

                Log.meeting.debug("📡 Meeting transcript: \(trimmed, privacy: .private)")
                self.meetingNotes.append(segment: trimmed, speaker: speakerLabel, at: capturedAt)
                if self.settings.overlayMode == .captions {
                    await MainActor.run { [weak self] in
                        self?.appState.meetingCaption = trimmed
                    }
                }
            } catch {
                Log.meeting.error("❌ Meeting transcription error: \(error.localizedDescription)")
                await MainActor.run { [weak self] in
                    self?.enqueueFailedSegment(audio: capturedAudio, speaker: speakerLabel, capturedAt: capturedAt)
                }
            }
        }
    }
}
