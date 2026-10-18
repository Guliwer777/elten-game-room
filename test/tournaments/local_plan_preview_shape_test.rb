require_relative '../support/tournament_declared_team_execution'
require_relative '../../lib/tournaments/local_execution_plan_backend'
include TournamentDeclaredTeamExecutionSupport

checks = 0
check = lambda do |backend, preview|
  record = backend.accept(preview: preview)
  assert_equal(record, backend.accept(preview: preview))
  assert_equal(record, backend.readback(intent_id: preview.fetch('intent_id')))
  path = backend.instance_variable_get(:@storage).path
  original = File.binread(path)
  [nil, true, false, 0, 0.0, '', [], {}].each do |value|
    assert_raises(T::Publication::Invalid) { backend.accept(preview: value) }
    assert_equal(original, File.binread(path), 'Rejected accept changed a confirmed document')
    [:record, :preview].each do |location|
      changed = JSON.parse(original)
      if location == :record
        changed['records'][0] = value
      else
        changed['records'][0]['preview'] = value
      end
      bytes = JSON.generate(changed)
      begin
        File.binwrite(path, bytes)
        assert_raises(T::Publication::Invalid) { backend.readback(intent_id: preview.fetch('intent_id')) }
        assert_equal(bytes.b, File.binread(path), 'Cold read rewrote malformed stored data')
      ensure
        File.binwrite(path, original)
      end
    end
    checks += 3
  end
  assert_equal(record, backend.readback(intent_id: preview.fetch('intent_id')))
  assert_equal(original, File.binread(path))
end
with_fixture(game: 'tic_tac_toe', rematch: false) do |fixture|
  backend = fixture.backend
  check.call(backend, backend.preview(publication_ref: fixture.reference, base_seats: fixture.base,
    intent_id: 'individual-preview-shape'))
end
with_fixture(game: 'taboo', names: %w[Alpha Beta Gamma Delta Epsilon Zeta], players_per_match: 6, rematch: false) do |fixture|
  with_declared_team_backend(fixture, 'Organizator') do |backend|
    check.call(backend, backend.preview_teams(publication_ref: fixture.reference,
      teams: [%w[alpha beta gamma], %w[delta epsilon zeta]], team_template: [0, 1, 0, 1, 0, 1],
      intent_id: 'team-preview-shape'))
  end
end
puts "PASS local preview shapes: #{checks} typed refusals, real individual/team acceptance and cold reads, preserved bytes"
