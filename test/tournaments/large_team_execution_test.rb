require_relative '../support/tournament_generic_team_round'
include TournamentGenericTeamRoundSupport
$stdout.sync = true
$generic_round_time = Time.now
Time.singleton_class.prepend(Module.new do
  def now; $generic_round_time || super; end
end)
size = ARGV.include?('--eight') ? 4 : 3
names = %w[Alpha Beta Gamma Delta Epsilon Zeta Eta Theta].take(size * 2)
with_fixture(game: 'taboo', names: names, players_per_match: size * 2, rematch: false,
    game_options: {'turns_each' => 1, 'turn_seconds' => 30}, group_advancement: T::GroupAdvancement::AUTOMATIC) do |fixture|
  record = nil
  teams = names.each_slice(size).map { |team| team.map(&:downcase) }
  template = Array.new(size * 2) { |index| index % 2 }
  with_declared_team_backend(fixture, 'Organizator') do |backend|
    assert_raises(T::Publication::Invalid) do
      backend.preview_pairs(publication_ref: fixture.reference, pairs: teams, team_template: template, intent_id: 'old-pairs-must-stay-strict')
    end
    record = backend.accept(preview: backend.preview_teams(publication_ref: fixture.reference,
      teams: teams, team_template: template, intent_id: 'large-team-final'))
    assert_equal(2, record['evidence']['source']['source_version'])
    assert_equal(size, record['evidence']['source']['membership']['team_size'])
    assert_equal(T::FixedTeamSeats::LARGE_POLICY, record['evidence']['plan']['matches'].first['role_policy_ref'])
    assert_equal(size * 2, record['evidence']['plan']['matches'].first['players'].size)
    assert_equal(record, backend.readback(intent_id: 'large-team-final'))
    assert_raises(T::Publication::Invalid) do
      backend.preview_teams(publication_ref: fixture.reference, teams: [teams.first, teams.last.take(size - 1)],
        team_template: template, intent_id: 'unequal')
    end
    assert_raises(T::Publication::Invalid) do
      backend.preview_teams(publication_ref: fixture.reference, teams: [teams.first, teams.last.map { teams.first.first }],
        team_template: template, intent_id: 'duplicate')
    end
  end
  start_generic_team_round(fixture, record)
  state = generic_team_state(fixture)
  core = state['native']['cores'].first
  assert_equal(size * 2, core['capacity'])
  assert_equal(size * 2, core['participants'].size)
  assert_equal(size * 2 - 1, core['invitations'].size)
  if ARGV.include?('--cold-resume')
    assert_equal(:paused, finish_generic_team_taboo(fixture, record, 0, pause_after: 4))
    resume = File.expand_path('../support/tournament_large_team_resume_probe.rb', __dir__)
    assert(system(RbConfig.ruby, resume, fixture.directory, $generic_round_time.to_f.to_s), 'The unfinished larger-team game must resume in a fresh process')
  else
    finish_generic_team_taboo(fixture, record, 0)
  end
  state = generic_team_state(fixture)
  assert_equal({}, state['busy'])
  assert_equal(1, state['native']['creates'].size)
  with_declared_team_execution(fixture, record, 'Organizator') do |execution|
    progress = execution.progress
    assert_equal('completed', progress['knockout_state'])
    assert_equal([2, 0], progress['standings'].map { |unit| unit['points'] }.sort.reverse)
    assert(progress['standings'].all? { |unit| unit.values_at('score_for', 'score_against') == [nil, nil] },
      'Taboo exported unsupported small points')
  end
  probe = File.expand_path('../support/tournament_large_team_finish_probe.rb', __dir__)
  assert(system(RbConfig.ruby, probe, fixture.directory, size.to_s), 'The actual larger-team game must survive restart')
end
puts "PASS large fixed teams: #{size * 2} real players, two complete teams of #{size}, automatic invitations, real Taboo final, points and cold archive"
