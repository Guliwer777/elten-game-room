require_relative '../support/tournament_generic_team_round'
include TournamentGenericTeamRoundSupport
$stdout.sync = true
large = ARGV.include?('--large')
# Reproducible inputs from two previously completed isolated real games.
# The normal action_for, recorded randomness and Runner still create every move.
$generic_replay_seeds = [
  [227,89,103,234,170,240,115,188,64,188,218,149,28,117,14,112],
  [83,108,202,20,144,72,14,69,61,156,222,17,112,141,246,218]
]
if large
  # Selected by bounded legal simulations of the production Domino model.
  # These are only random inputs; normal Runner actions must recreate both games.
  $generic_replay_seeds = [
    [154,192,81,92,82,184,14,77,162,72,83,25,110,93,177,254],
    [173,48,118,193,68,252,196,104,10,212,22,243,37,88,71,217]
  ]
end
GameRoomRandom::LocalSecureSource.prepend(Module.new do
  def roll(count:, sides:)
    if count == 16 && sides == 256 && !$generic_replay_seeds.empty?
      return GameRoomRandom::Roll.new(values: $generic_replay_seeds.shift, sides: sides, source: 'local_secure', proof: nil)
    end
    super
  end
end)
size = large ? 3 : 2
game = 'domino'
names = %w[Alpha Beta Gamma Delta Epsilon Zeta].take(size * 2)
options = {'teams' => true, 'team_count' => '2', 'score_limit' => 1}
options.merge!('tile_set' => 'd12', 'forbid_draw' => true, 'whole_team' => true) if large
with_fixture(game: game, names: names, players_per_match: size * 2, rematch: false,
    game_options: options, group_advancement: T::GroupAdvancement::AUTOMATIC) do |fixture|
  record = nil
  with_declared_team_backend(fixture, 'Organizator') do |backend|
    input = {publication_ref: fixture.reference, team_template: Array.new(size * 2) { |index| index % 2 }, intent_id: 'generic-teams'}
    teams = names.each_slice(size).map { |team| team.map(&:downcase) }
    preview = large ? backend.preview_teams(**input, teams: teams) : backend.preview_pairs(**input, pairs: teams)
    record = backend.accept(preview: preview)
  end
  start_generic_team_round(fixture, record)
  first = finish_generic_team_domino(fixture, record)
  assert_equal(true, first['draw'])
  assert_equal([], first['winners'])
  original = generic_team_state(fixture)['executions'].values.first
  with_declared_team_execution(fixture, record, 'Organizator') do |execution|
    progress = execution.progress
    assert_equal('tie_requires_resolution', progress['knockout_state'])
    assert_equal(nil, progress['champion'])
    assert_equal([1,1], progress['standings'].map { |unit| unit['points'] })
    sports = execution.knockout_preview
    assert_equal(:confirmed, sports[:state])
    assert_equal(1, sports[:plan]['matches'].size)
    assert_equal(:confirmed, execution.knockout_accept(preview: sports[:preview])[:state])
    shown = execution.knockout_execution_preview
    assert_equal(:confirmed, shown[:state])
    accepted = execution.knockout_execution_accept(preview: shown[:preview])
    assert_equal(:confirmed, accepted[:state])
    record = accepted[:record]
  end
  assert_equal(T::GameResult::CURRENT_RESULT_POLICY, record['evidence']['source']['result_policy'])
  assert_equal(size, T::FixedTeamSeats.unit_size(record['evidence']['source']['membership']))
  assert_equal(size * 2, record['evidence']['plan']['matches'].first['players'].size)
  puts 'PASS real generic team draw: 1/1, no champion, one reviewed additional-game plan with inherited v3'
  start_generic_team_round(fixture, record)
  decisive = finish_generic_team_domino(fixture, record)
  assert_equal(false, decisive['draw'])
  assert_equal(1, decisive['winners'].size)
  with_declared_team_execution(fixture, record, 'Organizator') do |execution|
    assert_equal('completed', execution.progress['knockout_state'])
    assert_equal(decisive['winners'].first, execution.progress['champion'])
  end
  final = generic_team_state(fixture)
  assert_equal({}, final['busy'])
  assert_equal(2, final['native']['creates'].size)
  assert_equal(original, final['executions'].values.find { |row| row['record_intent'] == original['record_intent'] })
  assert_equal([], $generic_replay_seeds)
  probe = File.expand_path('../support/tournament_generic_team_replay_probe.rb', __dir__)
  assert(system(RbConfig.ruby, probe, fixture.directory, game, size.to_s), 'The genuine additional team game must survive restart')
end
puts "PASS generic team additional game: real #{game} draw, another actual game, #{size * 2} players, champion, cold history and no duplicate Start"
