if ARGV.first
  ENV['ELTEN_TEST_NATIVE_CONTROLS'] = '1'
  begin
    require_relative '../support/binary_rules_load'
  ensure
    ENV.delete('ELTEN_TEST_NATIVE_CONTROLS')
  end
end
require_relative '../support/tournament_individual_ui'
require_relative '../../lib/tournaments/local_tournament_overview'
include GameRoomTest::Assertions
GameRoomLocalization.boot(settings: {'interface_language' => 'en', 'known_languages' => ['en']})
state = TournamentIndividualUI.fixture(names: %w[Alpha Beta])
owner = -> { TournamentIndividualUI::F::OWNER }
workspace = GameRoomTournaments::LocalWorkspace.new(program: state[:program], registry: GameRoomGames::CATALOG,
  user: owner, actor: 'Organizator', alert: ->(message) { raise message }, clock: -> { state[:now] })
publication = workspace.load['announcements'].first
2.times do |pass|
  driver = TournamentNativeDriver.new
  driver.step('Matches, groups and standings', [27]) do |form|
    value = TournamentIndividualUI::F.field(form, 'Matches, groups and standings').text
    if pass.zero?
      assert(value.include?('Match awaiting play'), value)
      assert(!value.include?('The tournament time has ended.'), value)
      record = TournamentIndividualUI.record(state)
      state[:now] = record['evidence']['plan']['matches'].flat_map { |match| match['windows'] }.map { |window| window['closes'] }.max
    else
      assert(value.include?('The tournament time has ended.'), value)
      assert(value.include?('Match unfinished after its deadline'), value)
      assert(!value.include?('Match awaiting play'), value)
      assert(value.include?('tournament points 0'), value)
    end
  end
  GameRoomTournaments::LocalTournamentOverview.new(program: state[:program], workspace: workspace,
    owner: GameRoomTournaments::LocalTestDialogs::Owner.new(owner, ->(message) { raise message }), publication: publication).run
  driver.finish
end
state[:program].finalize
state[:program].class.app_runtime.close
puts 'PASS native overview: exact deadline, unfinished matches and no awarded points'
