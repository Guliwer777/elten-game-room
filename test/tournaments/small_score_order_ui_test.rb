require_relative '../support/tournament_generic_team_round'
require_relative '../support/tournament_native'
require_relative '../../lib/tournaments/local_fixed_team_execution_screen'
require_relative '../../lib/tournaments/local_individual_execution_screen'
require_relative '../support/tournament_scored_game'
require_relative '../support/tournament_individual_execution'
include TournamentGenericTeamRoundSupport
include TournamentIndividualExecutionSupport
individual = ARGV.include?('--individual')
language = ARGV.include?('--pl') ? 'pl' : 'en'
GameRoomLocalization.boot(settings: {'interface_language' => language, 'known_languages' => [language]})
l = ->(message) { GameRoomContent.utf8(GameRoomLocalization.translate(message)) }
if ARGV.include?('--binary')
  previous, $VERBOSE = $VERBOSE, nil
  begin
    %w[local_fixed_team_execution_screen local_individual_execution_screen].each do |name|
      path = File.expand_path('../../lib/tournaments/' + name + '.rb', __dir__)
      Object.class_eval(File.binread(path), path)
    end
  ensure
    $VERBOSE = previous
  end
end
registry = individual ? TournamentScoredGameSupport.registry(lower: true) : GameRoomGames::CATALOG
fixture = TournamentLocalExecutionPlanSupport::Fixture.new(ARGV.fetch(0), game: individual ? 'future_scored_game' : 'domino',
  registry: registry, reopen: true)
begin
  state_path = individual ? File.join(fixture.directory, 'k02/individual-v1/execution-v1/state.json') : generic_team_state_path(fixture)
  bytes = File.binread(state_path)
  record = nil
  if individual
    record = fixture.backend(context: nil).readback(intent_id: 'score-policy')
  else
    with_declared_team_backend(fixture, 'Organizator') { |backend| record = backend.readback(intent_id: 'generic-teams') }
  end
  assert_equal(T::GameResult::CURRENT_RESULT_POLICY, record['evidence']['source']['result_policy'])
  progress = nil
  if individual
    with_individual_execution(fixture, record, 'Organizator') { |execution| progress = execution.progress }
  else
    with_declared_team_execution(fixture, record, 'Organizator') { |execution| progress = execution.progress }
  end
  assert_equal(['lower'], progress['standings'].map { |row| row['score_order'] }.uniq)
  screen = (individual ? T::LocalIndividualExecutionScreen : T::LocalFixedTeamExecutionScreen).allocate
  content = progress['standings'].map { |row| screen.send(:standings_row_text, row) }.join("\r\n")
  program = TournamentEntryContextTest::Program.new
  session = T::LocalReadinessSession.new
  session.choose_actor('Organizator')
  context = T::EntryContext.new(program: program, runtime: program.class.app_runtime,
    owner_reader: -> { fixture.owner }, actor: 'Organizator', account_events: session.actor_events)
  driver = TournamentNativeDriver.new
  driver.step(l.call('Tournament standings'), [27]) do |form|
    field = form.fields.find { |item| item.respond_to?(:header) && item.header == l.call('Tournament standings') }
    assert(field, 'The native read-only standings field must be present')
    assert(field.text.include?(l.call('Small points: lower is better.')), 'The actual score direction must be explained')
    progress['standings'].each do |row|
      assert(field.text.include?(row[individual ? 'unit' : 'team']), 'Every real participant or team must be displayed')
      assert(field.text.include?(row['score_for'].to_s), 'The public game score must retain its original value')
    end
  end
  window = T::LocalFixedTeamExecutionScreen.const_get(:Standings, false)
  window.new(program: program, content: content, context: context, lease: context.capture).run
  driver.finish
  assert_equal(bytes, File.binread(state_path))
  puts "PASS native #{individual ? 'individual' : 'team'} ordered small scores: actual source-v4 result, original public numbers, lower-is-better label, unchanged archive"
ensure
  context&.close
  session&.close
  program&.finalize
  program&.class&.app_runtime&.close
  fixture.close
end
