require_relative '../support/tournament_generic_team_round'
include TournamentGenericTeamRoundSupport

# The existing local Taboo fixture controls elapsed turn time, not results.
$generic_round_time = Time.now
Time.singleton_class.prepend(Module.new do
  def now; $generic_round_time || super; end
end)
checks = 0
names = %w[Alpha Beta Gamma Delta Epsilon Zeta Eta Theta]
with_fixture(game: 'taboo', names: names, players_per_match: 4, rematch: false,
    game_options: {'turns_each' => 1, 'turn_seconds' => 30},
    group_advancement: T::GroupAdvancement::AUTOMATIC) do |fixture|
  parent = nil
  with_declared_team_backend(fixture, 'Organizator') do |backend|
    shown = backend.preview_pairs(publication_ref: fixture.reference,
      pairs: names.each_slice(2).map { |team| team.map(&:downcase) }, team_template: [0, 1, 0, 1],
      intent_id: 'team-facade-shape-parent')
    parent = backend.accept(preview: shown)
  end
  assert_equal(2, parent['evidence']['plan']['matches'].size)
  start_generic_team_round(fixture, parent)
  parent['evidence']['plan']['matches'].each_index { |index| finish_generic_team_taboo(fixture, parent, index) }
  originals = generic_team_state(fixture)
  assert_equal(2, originals['executions'].values.count { |execution| execution['result'] })
  assert_equal({}, originals['busy'])
  snapshot = lambda do
    Dir.glob(File.join(fixture.directory, '**', '*.json')).sort.to_h { |path| [path, File.binread(path)] }
  end
  child = nil
  with_declared_team_execution(fixture, parent, 'Organizator') do |execution|
    sports = execution.knockout_preview
    assert_equal(:confirmed, sports[:state])
    assert_equal(:confirmed, execution.knockout_accept(preview: sports[:preview])[:state])
    generated = execution.knockout_execution_preview
    assert_equal(:confirmed, generated[:state])
    shown = generated[:preview]
    before = snapshot.call
    [nil, true, false, 0, 0.0, 'bad', [], {}].each do |value|
      [value, JSON.parse(JSON.generate(shown)).merge('source' => value)].each do |input|
        input_before = JSON.generate(input)
        assert_raises(T::Publication::Invalid) { execution.knockout_execution_accept(preview: input) }
        assert_equal(input_before, JSON.generate(input))
        assert_equal(before, snapshot.call, 'Team refusal must not mutate completed games, approval, plans or journals')
        checks += 1
      end
    end
    child = execution.knockout_execution_accept(preview: shown)
    assert_equal(:confirmed, child[:state])
    assert_equal(child, execution.knockout_execution_accept(preview: shown))
  end
  with_declared_team_execution(fixture, parent, 'Organizator') do |execution|
    assert_equal(child, execution.knockout_execution_readback)
  end
  assert_equal(originals, generic_team_state(fixture), 'Accepting the next plan must preserve the two completed native games')
end
puts "PASS local team phase facade: #{checks} malformed previews refused; two actual Taboo games, valid/idempotent child and cold readback"
