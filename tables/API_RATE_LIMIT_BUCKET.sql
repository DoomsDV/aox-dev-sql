PROMPT CREATE TABLE api_rate_limit_bucket
CREATE TABLE api_rate_limit_bucket (
  scope_code         VARCHAR2(64)  NOT NULL,
  bucket_key         VARCHAR2(255) NOT NULL,
  attempt_count      NUMBER        DEFAULT 1 NOT NULL,
  window_started_at  TIMESTAMP WITH TIME ZONE DEFAULT SYSTIMESTAMP NOT NULL,
  updated_at         TIMESTAMP WITH TIME ZONE DEFAULT SYSTIMESTAMP NOT NULL,
  CONSTRAINT pk_api_rate_limit_bucket PRIMARY KEY (scope_code, bucket_key)
)
/

PROMPT CREATE INDEX ix_api_rate_limit_window
CREATE INDEX ix_api_rate_limit_window
  ON api_rate_limit_bucket (scope_code, window_started_at)
/
