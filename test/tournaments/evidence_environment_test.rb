require_relative '../support/assertions'
require_relative '../support/tournament_evidence_environment'
require 'json'
include GameRoomTest::Assertions

source = {'ELTEN_HOST_SOURCE' => 'C:/host', 'ENTRY_EVIDENCE' => 'C:/own-evidence',
  'FT2_SOURCE' => 'C:/sources', 'TMPDIR' => '', 'CI_UNRELATED_TOKEN' => 'synthetic-not-a-credential',
  'GITHUB_TOKEN' => 'another-synthetic-value', 'UNRELATED_SETTING' => 'private'}
before = Marshal.dump(source)
captured = TournamentTestEvidence.environment(source)
assert_equal(source.slice('ELTEN_HOST_SOURCE', 'ENTRY_EVIDENCE', 'FT2_SOURCE', 'TMPDIR'), captured)
assert_equal(before, Marshal.dump(source), 'Evidence filtering changed the child environment')
assert(!JSON.generate(captured).include?('synthetic'), 'Unrelated inherited data leaked into evidence')
captured['ENTRY_EVIDENCE'].replace('changed')
assert_equal('C:/own-evidence', source['ENTRY_EVIDENCE'], 'Snapshot aliases the caller environment')
assert_equal({}, TournamentTestEvidence.environment({}))
puts 'PASS tournament evidence records only reproduction settings without mutating child-process environment'
