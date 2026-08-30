import Foundation

// MARK: - AppSettings Keys & Defaults
//
// UserDefaults key strings and their factory defaults, plus `Key.all` (used by
// resetToDefaults). Split out of AppSettings.swift; kept as nested types via an
// extension so `Key.x` / `Default.x` references are unchanged.

extension AppSettings {

    enum Key {
        static let onboardingCompleted    = "onboarding.completed"
        static let shortcutOverrides      = "shortcuts.overrides"
        static let apiBaseURL             = "api.baseURL"
        static let transcriptionModel     = "api.transcriptionModel"
        static let polishingModel         = "api.polishingModel"
        static let fastModel              = "api.fastModel"
        static let pttKeyCode             = "dictation.pttKeyCode"
        static let pttActivation          = "dictation.pttActivation"
        static let preferBuiltInMic       = "audio.preferBuiltInMic"
        static let meetingMicThreshold    = "meeting.micThresholdDBFS"
        static let systemAudioThreshold   = "meeting.systemAudioThresholdDBFS"
        static let silenceDebounce        = "meeting.silenceDebounceSeconds"
        static let maxSegmentSeconds      = "meeting.maxSegmentSeconds"
        static let echoGateWindow         = "meeting.echoGateWindowSeconds"
        static let echoSuppressionEnabled = "meeting.echoSuppressionEnabled"
        static let speakerLabelYou        = "meeting.speakerLabelYou"
        static let speakerLabelThem       = "meeting.speakerLabelThem"
        static let notesFolderPath        = "meeting.notesFolderPath"
        static let overlayMode            = "meeting.overlayMode"
        static let summariesEnabled       = "meeting.summariesEnabled"
        static let actionItemsEnabled     = "meeting.actionItemsEnabled"
        static let structuredExtraction   = "meeting.structuredExtraction"
        static let extractKeyFields       = "meeting.extractKeyFields"
        static let extractUnanswered      = "meeting.extractUnanswered"
        static let watchlistKeywords      = "meeting.watchlistKeywords"
        static let draftGuidance          = "meeting.draftGuidance"
        static let userDraftTemplates     = "meeting.userDraftTemplates"
        static let openNotesExternally    = "notes.openExternally"
        static let topicChapters          = "meeting.topicChapters"
        static let talkTimeAnalytics      = "meeting.talkTimeAnalytics"
        static let objectionIntel         = "meeting.objectionIntel"
        static let agenticAsk             = "meeting.agenticAsk"
        static let agenticAskMaxHops      = "meeting.agenticAskMaxHops"
        static let liveAssistantEnabled   = "meeting.liveAssistantEnabled"
        static let meetingPrepCard        = "meeting.prepCard"
        static let notifyOnMeetingEnd     = "meeting.notifyOnMeetingEnd"
        static let retainMeetingAudio     = "meeting.retainAudio"
        static let frontMatterEnabled     = "meeting.frontMatterEnabled"
        static let diarizationEnabled     = "meeting.diarizationEnabled"
        static let offlineFallback        = "transcription.offlineFallback"
        static let preferOnDeviceAI       = "ai.preferOnDevice"
        static let digestEnabled          = "digest.enabled"
        static let digestFrequency        = "digest.frequency"   // "daily" | "weekly" | "monthly" | "yearly"
        static let digestHour             = "digest.hour"        // 0–23
        static let digestWeekday          = "digest.weekday"     // 1=Sun … 7=Sat
        static let staleRelationshipDays  = "digest.staleDays"
        static let lastDigestDay          = "digest.lastDay"     // "yyyy-MM-dd" of last run
        static let transcriptionLanguage  = "transcription.language"
        static let vocabulary             = "transcription.vocabulary"
        static let replacements           = "transcription.replacements"
        static let appProfiles            = "polishing.appProfiles"
        static let pasteOnlyApps          = "dictation.pasteOnlyApps"
        static let dictationHistoryOn     = "dictation.historyEnabled"
        static let dictationHistoryLimit  = "dictation.historyLimit"
        static let captionLingerSeconds   = "meeting.captionLingerSeconds"
        static let retryMaxAttempts       = "meeting.retryMaxAttempts"
        static let retryIntervalSeconds   = "meeting.retryIntervalSeconds"
        static let notesOrganization      = "meeting.notesOrganization"
        static let meetingAutoDetect      = "meeting.autoDetect"
        static let voiceCommandsEnabled   = "dictation.voiceCommands"
        static let voiceCommandRules      = "dictation.voiceCommandRules"
        static let streamingDictation     = "dictation.streaming"
        static let streamChunkSeconds     = "dictation.streamChunkSeconds"
        static let skipSilentDictation    = "dictation.skipSilent"
        static let dictationSilenceThreshold = "dictation.silenceThreshold"
        static let maxSpeakers            = "meeting.maxSpeakers"
        static let speakerSensitivity     = "meeting.speakerSensitivity"
        static let liveBriefInterval      = "meeting.liveBriefInterval"
        static let aiCacheLimit           = "ai.cacheLimit"
        static let searchDepth            = "assistant.searchDepth"
        static let meetingTemplate        = "meeting.template"
        static let customTemplateSections = "meeting.customTemplateSections"
        static let customTemplateFollowUp = "meeting.customTemplateFollowUp"
        static let userTemplates          = "meeting.userTemplates"
        static let dictationStyleOverrides = "dictation.styleOverrides"
        static let userDictationStyles     = "dictation.userStyles"
        static let defaultDictationStyle   = "dictation.defaultStyle"
        static let quickNotesFolderPath   = "quicknotes.folderPath"
        static let quickNoteNotify        = "quicknotes.notifyOnSave"
        static let localOnlyMode          = "privacy.localOnly"
        static let redactionEnabled       = "privacy.redactionEnabled"
        static let redactEmails           = "privacy.redactEmails"
        static let redactPhones           = "privacy.redactPhones"
        static let redactNumbers          = "privacy.redactNumbers"
        static let autoTagging            = "meeting.autoTagging"
        static let errorNotifications     = "diagnostics.errorNotifications"
        static let uiDateFormat           = "ui.dateFormat"
        static let pdfPaperSize           = "export.pdfPaperSize"
        static let browserTabDetection    = "dictation.browserTabDetection"
        static let domainStyleRules       = "dictation.domainStyleRules"
        static let saveDictations         = "dictation.saveToFiles"
        static let dictationsFolderPath   = "dictation.folderPath"
        static let dictationOrganization  = "dictation.organization"
        static let audioImportMaxMB       = "import.maxMB"
        static let meetingDetectInterval  = "meeting.detectInterval"
        static let liveBriefMinGrowth     = "meeting.liveBriefMinGrowth"
        static let transcriptionTimeout   = "transcription.requestTimeout"
        static let importTranscriptionTimeout = "transcription.importTimeout"
        static let meetingEndQuietPolls   = "meeting.endQuietPolls"
        static let summaryContextChars    = "ai.summaryContextChars"
        static let pttTapThreshold        = "dictation.pttTapThreshold"
        static let priceAudioPerHour      = "cost.audioPerHour"
        static let priceInputPerMTok      = "cost.inputPerMTok"
        static let priceOutputPerMTok     = "cost.outputPerMTok"
        static let monthlyBudgetUSD       = "cost.monthlyBudgetUSD"
        static let webhookEnabled         = "integrations.webhookEnabled"
        static let webhookURL             = "integrations.webhookURL"
        static let scriptHookEnabled      = "integrations.scriptHookEnabled"
        static let scriptHookPath         = "integrations.scriptHookPath"
        static let packetIncludeEmail     = "packet.includeEmail"
        static let packetIncludePOC       = "packet.includePOC"
        static let packetIncludeActions   = "packet.includeActions"   // legacy — migrated into packetSections
        static let packetConfirmBeforeRun = "packet.confirmBeforeRun"
        static let packetSections         = "packet.sections"
        static let autoBackupEnabled      = "backup.autoEnabled"
        static let autoBackupRetentionDays = "backup.retentionDays"
        static let autoBackupFolderPath   = "backup.folderPath"
        static let lastAutoBackupAt       = "backup.lastAt"       // epoch seconds of last auto-backup (0 = never)

        static let all = [onboardingCompleted, shortcutOverrides, apiBaseURL, transcriptionModel, polishingModel, fastModel, pttKeyCode,
                          pttActivation,
                          preferBuiltInMic,
                          meetingMicThreshold, systemAudioThreshold,
                          silenceDebounce, maxSegmentSeconds, echoGateWindow,
                          echoSuppressionEnabled, speakerLabelYou, speakerLabelThem,
                          notesFolderPath, overlayMode,
                          summariesEnabled, actionItemsEnabled,
                          structuredExtraction, extractKeyFields, extractUnanswered, watchlistKeywords, draftGuidance, userDraftTemplates, openNotesExternally, topicChapters, talkTimeAnalytics, objectionIntel, agenticAsk, agenticAskMaxHops, liveAssistantEnabled, meetingPrepCard,
                          notifyOnMeetingEnd, retainMeetingAudio, frontMatterEnabled,
                          diarizationEnabled, offlineFallback, preferOnDeviceAI, transcriptionLanguage,
                          digestEnabled, digestFrequency, digestHour, digestWeekday, staleRelationshipDays, lastDigestDay,
                          vocabulary, replacements, appProfiles, pasteOnlyApps,
                          dictationHistoryOn, dictationHistoryLimit,
                          captionLingerSeconds, retryMaxAttempts, retryIntervalSeconds,
                          notesOrganization, meetingAutoDetect,
                          voiceCommandsEnabled, voiceCommandRules, streamingDictation,
                          streamChunkSeconds, skipSilentDictation, dictationSilenceThreshold,
                          maxSpeakers, speakerSensitivity,
                          liveBriefInterval, aiCacheLimit,
                          searchDepth, meetingTemplate,
                          customTemplateSections, customTemplateFollowUp, userTemplates,
                          dictationStyleOverrides, userDictationStyles, defaultDictationStyle,
                          quickNotesFolderPath, quickNoteNotify,
                          localOnlyMode, redactionEnabled, redactEmails, redactPhones, redactNumbers,
                          autoTagging, errorNotifications, uiDateFormat, pdfPaperSize,
                          browserTabDetection, domainStyleRules,
                          saveDictations, dictationsFolderPath, dictationOrganization, audioImportMaxMB,
                          meetingDetectInterval, liveBriefMinGrowth, transcriptionTimeout,
                          importTranscriptionTimeout, meetingEndQuietPolls, summaryContextChars, pttTapThreshold,
                          priceAudioPerHour, priceInputPerMTok, priceOutputPerMTok,
                          monthlyBudgetUSD,
                          webhookEnabled, webhookURL, scriptHookEnabled, scriptHookPath,
                          packetIncludeEmail, packetIncludePOC, packetIncludeActions,
                          packetConfirmBeforeRun, packetSections,
                          autoBackupEnabled, autoBackupRetentionDays, autoBackupFolderPath, lastAutoBackupAt]
    }

    // MARK: - Defaults (previous hard-coded values)

    enum Default {
        static let apiBaseURL                      = "https://api.groq.com/openai/v1"
        static let transcriptionModel              = "whisper-large-v3"
        static let polishingModel                  = "openai/gpt-oss-120b"  // Groq's replacement for the retired llama-3.3-70b; reasoning output handled by send()
        static let fastModel                       = "openai/gpt-oss-20b"
        static let pttKeyCode: Int                 = 61     // Right Option
        static let pttActivation                   = "toggle" // hold | tapLock | toggle
        static let preferBuiltInMic                = false  // use the system default input
        static let meetingMicThreshold: Float      = -40.0
        static let systemAudioThreshold: Float     = -50.0
        static let silenceDebounce: TimeInterval   = 1.5
        static let maxSegmentSeconds: TimeInterval = 25.0
        static let echoGateWindow: TimeInterval    = 0.4
        static let echoSuppressionEnabled          = true
        static let speakerLabelYou                 = "You"
        static let speakerLabelThem                = "Them"
        static let overlayMode                     = MeetingOverlayMode.minimal
        static let summariesEnabled                = true
        static let actionItemsEnabled              = true
        static let structuredExtraction            = true
        static let extractKeyFields                = true
        static let extractUnanswered               = true
        static let openNotesExternally             = false
        static let topicChapters                   = true
        static let talkTimeAnalytics               = true
        static let objectionIntel                  = true
        static let agenticAsk                      = true
        static let agenticAskMaxHops               = 3
        static let liveAssistantEnabled            = true
        static let meetingPrepCard                 = true
        static let notifyOnMeetingEnd              = true
        static let retainMeetingAudio              = true
        static let frontMatterEnabled              = true
        static let diarizationEnabled              = true
        static let offlineFallback                 = true
        static let preferOnDeviceAI                = false
        static let digestEnabled                   = false
        static let digestFrequency                 = "daily"
        static let digestHour                      = 9
        static let digestWeekday                   = 2       // Monday
        static let staleRelationshipDays           = 30
        static let transcriptionLanguage           = "en"
        static let dictationHistoryOn              = true
        static let dictationHistoryLimit           = 20
        static let captionLingerSeconds: Double    = 6.0
        static let retryMaxAttempts                = 3
        static let retryIntervalSeconds: Double    = 20.0
        static let notesOrganization               = NotesOrganization.byDay
        static let dictationOrganization           = NotesOrganization.byMonth
        static let audioImportMaxMB: Int           = 200   // long recordings are chunked to fit Groq's per-request limit; this only guards the in-memory decode
        static let meetingDetectInterval: Double   = 3.0    // auto-detect poll seconds
        static let liveBriefMinGrowth: Int         = 350    // chars of new transcript before a brief refresh
        static let transcriptionTimeout: Int       = 30     // seconds for a Groq STT request (live chunk)
        static let importTranscriptionTimeout: Int = 120    // seconds for a whole-file STT request (import)
        static let meetingEndQuietPolls: Int       = 2      // consecutive quiet polls before meeting-end
        static let summaryContextChars: Int        = 24000  // char budget fed to summary/extraction prompts
        static let pttTapThreshold: Double         = 0.4    // seconds: below = tap-lock, above = hold
        static let meetingAutoDetect               = true
        static let voiceCommandsEnabled            = true
        static let voiceCommandRules = """
        "new paragraph" or "new line" → insert a paragraph or line break
        spoken punctuation ("comma", "period", "question mark", "exclamation mark", "colon", "semicolon") → that punctuation character
        "open quote" / "close quote" → quotation marks
        "scratch that" or "delete that" → remove the immediately preceding phrase or sentence
        "all caps <words> end caps" → uppercase those words
        """
        static let streamingDictation              = true
        static let streamChunkSeconds: Double      = 10.0
        static let skipSilentDictation             = true
        static let dictationSilenceThreshold: Float = -45.0
        static let maxSpeakers                     = 4
        static let speakerSensitivity: Double      = 1.0
        static let liveBriefInterval               = 25
        static let aiCacheLimit                    = 500
        static let searchDepth                     = 200
        static let meetingTemplate                 = MeetingTemplate.customerCall
        static let quickNoteNotify                 = true
        static let localOnlyMode                   = false
        static let redactionEnabled                = false
        static let redactEmails                    = true
        static let redactPhones                    = true
        static let redactNumbers                   = true
        static let autoTagging                     = true
        static let errorNotifications              = true
        static let uiDateFormat                    = "dd MMM yyyy"
        static let pdfPaperSize                     = "letter"   // "letter" | "a4"
        static let browserTabDetection             = true
        static let saveDictations                  = true
        static let domainStyleRules = """
        mail.google.com: email
        outlook.office.com: email
        github.com: code
        docs.google.com: notes
        """
        // Estimate defaults (USD) — Groq list prices as of shipping; editable
        // in Settings since provider pricing drifts over time.
        static let priceAudioPerHour               = 0.111   // whisper-large-v3
        static let priceInputPerMTok               = 0.59    // llama-3.3-70b input
        static let priceOutputPerMTok              = 0.79    // llama-3.3-70b output
        static let monthlyBudgetUSD                = 0.0     // 0 = no budget set
        static let webhookEnabled                  = false
        static let webhookURL                      = ""
        static let scriptHookEnabled               = false
        static let scriptHookPath                  = ""
        static let packetIncludeEmail              = true
        static let packetIncludePOC                = true
        static let packetIncludeActions            = true
        static let packetConfirmBeforeRun          = true
        static let autoBackupEnabled               = true   // data-safety feature — on by default (writes to Application Support)
        static let autoBackupRetentionDays         = 3      // keep this many most-recent daily archives

        static var notesFolder: URL {
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Notes", isDirectory: true)
        }
    }

}
