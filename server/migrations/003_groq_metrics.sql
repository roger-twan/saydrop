CREATE TABLE metric_samples_v3 (
 id TEXT PRIMARY KEY,
 name TEXT NOT NULL CHECK(name IN (
  'submitCount','rejectedCount','idempotentReplayCount','acceptedCount','terminalCount',
  'uploadSeconds','validationSeconds','submissionSeconds','taskTotalSeconds','resultReadySeconds',
  'sttSeconds','polishSeconds','sttTtfbSeconds','polishTtfbSeconds','ttftSeconds','audioSeconds',
  'rawCharacters','outputCharacters','rtf','audioThroughput','characterThroughput',
  'polishAttemptCount','polishFallbackCount','outputValidCount','upstreamInvalidCount',
  'upstreamTruncatedCount','upstreamHttpFailedCount','resultExpiredCount','recoveryCount',
  'qualityCER','qualityStrictCER','qualityWER','qualityMixedErrorRate','qualityOmissionRate',
  'qualityProtectedRetention','qualityReferenceUnits','qualitySubstitutions','qualityDeletions',
  'qualityInsertions','qualityProtectedExpected','qualityProtectedRetained','qualitySampleCount',
  'polishTimeoutCount',
  'qualityCERReferenceUnits','qualityCERSubstitutions','qualityCERDeletions','qualityCERInsertions',
  'qualityStrictCERReferenceUnits','qualityStrictCERSubstitutions','qualityStrictCERDeletions','qualityStrictCERInsertions',
  'qualityWERReferenceUnits','qualityWERSubstitutions','qualityWERDeletions','qualityWERInsertions',
  'qualityMixedErrorRateReferenceUnits','qualityMixedErrorRateSubstitutions','qualityMixedErrorRateDeletions','qualityMixedErrorRateInsertions'
 )),
 mode TEXT NOT NULL CHECK(mode IN ('none','raw','light_polish')),
 model TEXT NOT NULL CHECK(model IN (
  'whisper-large-v3','whisper-large-v3-turbo','none','elevenlabs/scribe-v2','openai/whisper-large-v3-turbo','openai/gpt-4.1-mini'
 )),
 outcome TEXT NOT NULL CHECK(outcome IN ('none','ready','failed','cancelled','unknown','rejected')),
 source TEXT NOT NULL CHECK(source IN ('live','mock','offline')),
 reason TEXT CHECK(reason IS NULL OR reason IN (
  'non_streaming','not_observed','missing_reference','empty_reference','not_english',
  'no_protected_terms','alignment_limit','missing_hypothesis',
  'invalid_request','invalid_token','installation_revoked','invalid_wav','audio_too_large',
  'audio_too_long','empty_audio','quota_exhausted','budget_unavailable','rate_limited',
  'idempotency_conflict','not_found','forbidden','upstream_failed','request_timeout',
  'result_expired','request_cancelled','internal_error'
 )),
 observed_at TEXT NOT NULL,
 expires_at TEXT NOT NULL,
 value REAL CHECK(value IS NULL OR value BETWEEN 0 AND 1.7976931348623157e308),
 CHECK(value IS NOT NULL OR reason IS NOT NULL),
 CHECK(name <> 'ttftSeconds' OR (value IS NULL AND reason = 'non_streaming')),
 CHECK(name NOT LIKE 'quality%' OR value IS NULL OR source = 'offline')
);
INSERT INTO metric_samples_v3 SELECT * FROM metric_samples;
DROP TABLE metric_samples;
ALTER TABLE metric_samples_v3 RENAME TO metric_samples;
CREATE INDEX metric_samples_observed_at ON metric_samples(observed_at);
CREATE INDEX metric_samples_expires_at ON metric_samples(expires_at);
CREATE INDEX metric_samples_snapshot_group ON metric_samples(
 source, observed_at, expires_at, name, mode, model, outcome, reason
);
