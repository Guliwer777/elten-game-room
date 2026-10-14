require_relative '../support/tournament_generic_team_round'
include TournamentGenericTeamRoundSupport
$stdout.sync = true
$generic_round_time = Time.now
Time.singleton_class.prepend(Module.new do
  def now; $generic_round_time || super; end
end)
size = ARGV.include?('--large') ? 3 : 2
names = %w[Alpha Beta Gamma Delta Epsilon Zeta Eta Theta Iota Kappa Lambda Mu].take(size * 4)
with_fixture(game: 'taboo', names: names, players_per_match: size * 2, rematch: false,
    game_options: {'turns_each' => 1, 'turn_seconds' => 30}, group_advancement: T::GroupAdvancement::AUTOMATIC) do |fixture|
  records = []
  with_declared_team_backend(fixture, 'Organizator') do |backend|
    teams = names.each_slice(size).map { |team| team.map(&:downcase) }
    input = {publication_ref: fixture.reference, team_template: Array.new(size * 2) { |index| index % 2 }, intent_id: 'generic-team-groups'}
    preview = size == 2 ? backend.preview_pairs(**input, pairs: teams) : backend.preview_teams(**input, teams: teams)
    records << backend.accept(preview: preview)
  end
  originals = {}
  3.times do |round|
    record = records.last
    assert_equal(T::GameResult::CURRENT_RESULT_POLICY, record['evidence']['source']['result_policy'])
    assert_equal(size == 2 ? 1 : 2, record['evidence']['source']['source_version'])
    assert_equal(size, T::FixedTeamSeats.unit_size(record['evidence']['source']['membership']))
    record['evidence']['plan']['matches'].each do |match|
      assert_equal(size * 2, match['players'].size)
      assert_equal([size, size], match['players'].group_by { |person| person['team'] }.values.map(&:size))
    end
    assert_equal(round == 2 ? 1 : 2, record['evidence']['plan']['matches'].size)
    start_generic_team_round(fixture, record)
    record['evidence']['plan']['matches'].each_index { |index| finish_generic_team_taboo(fixture, record, index) }
    assert_equal({}, generic_team_state(fixture)['busy'])
    originals.each do |key, row|
      assert_equal(row, generic_team_state(fixture)['executions'][key], 'Earlier genuine game history must remain immutable')
    end
    generic_team_state(fixture)['executions'].each { |key, row| originals[key] ||= row }
    with_declared_team_execution(fixture, record, 'Organizator') do |execution|
      if round == 2
        progress = execution.progress
        assert_equal('completed', progress['knockout_state'])
        assert_equal(progress['qualified'].first, progress['champion'])
      else
        sports = execution.knockout_preview
        assert_equal(:confirmed, sports[:state], sports.inspect)
        assert_equal(:confirmed, execution.knockout_accept(preview: sports[:preview])[:state])
        shown = execution.knockout_execution_preview
        assert_equal(:confirmed, shown[:state])
        accepted = execution.knockout_execution_accept(preview: shown[:preview])
        assert_equal(:confirmed, accepted[:state])
        records << accepted[:record]
        assert_equal(record['evidence']['source']['result_policy'], records.last['evidence']['source']['result_policy'])
      end
    end
    puts "PASS generic Taboo tournament stage #{round + 1}: actual results, busy release and immutable prior games"
  end
  with_declared_team_backend(fixture, 'Organizator') do |backend|
    records.each { |record| assert_equal(record, backend.readback(intent_id: record['preview']['intent_id'])) }
  end
  state = generic_team_state(fixture)
  assert_equal(5, state['native']['creates'].size)
  assert_equal(5, state['executions'].values.count { |row| row['result'] })
  probe = File.expand_path('../support/tournament_generic_team_lifecycle_probe.rb', __dir__)
  assert(system(RbConfig.ruby, probe, fixture.directory, size.to_s), 'The real generic tournament must survive a cold process')
end
puts "PASS generic team tournament: #{size * 4} signup players, four teams, real groups/semifinals/final, inherited v3, champion and cold ancestor readback"
