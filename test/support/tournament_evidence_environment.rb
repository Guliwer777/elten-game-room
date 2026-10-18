# frozen_string_literal: true

module TournamentTestEvidence
  # Reproduction paths and interpreter settings only. Never persist the entire
  # inherited process environment: it may contain unrelated credentials.
  ENVIRONMENT_KEYS = %w[
    TMPDIR TMP TEMP GEM_PATH GEM_HOME RUBYLIB RUBYOPT ELTEN_HOST_SOURCE
    ELTEN_ZSTD_LIBRARY FT1_SCRATCH FT2_SCRATCH FT2_SOURCE ENTRY_SCRATCH
    ENTRY_EVIDENCE COORD_EVIDENCE_DIR
  ].freeze

  def self.environment(source = ENV)
    ENVIRONMENT_KEYS.each_with_object({}) do |name, result|
      value = source[name]
      result[name] = value.dup unless value.nil?
    end
  end
end
