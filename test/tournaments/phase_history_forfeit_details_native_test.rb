require_relative '../support/tournament_forfeit_native'
require_relative '../support/tournament_native'
require_relative '../support/tournament_entry_context'
require_relative '../../lib/tournaments/server_phase_store'
require_relative '../../lib/tournaments/server_schedule_overview'

T = GameRoomTournaments
GameRoomLocalization.boot(settings: {'interface_language' => 'en', 'known_languages' => ['en']})

def show_forfeit_details(program, response, publication, phase_id: nil)
  program.define_singleton_method(:ordinary_tournament_overview) { |*_, **| response }
  workspace = Object.new
  workspace.define_singleton_method(:actor) { 'alice' }
  owner = T::Dialogs::Owner.new(-> { 'alice' }, ->(message) { raise message })
  driver = TournamentNativeDriver.new
  driver.step('Tournament matches') do |form|
    form.fields.first.index = 1
    actions = {}
    menu = Object.new
    menu.define_singleton_method(:option) { |label, *_, &action| actions[label] = action }
    form.fields.first.context(menu, false)
    actions.fetch('Result details').call
  end
  driver.step('Result details', [27]) do |form|
    details = form.fields.first.text
    assert(details.include?('loses by forfeit'), 'Missing public forfeit decision')
    assert(details.include?('Organizer: alice'), 'Missing authenticated organizer')
    assert(details.include?('Forfeit before the match started.'), 'Missing basis of places')
  end
  driver.step('Tournament matches', [27])
  T::ServerScheduleOverview.new(program: program, workspace: workspace, owner: owner,
    publication: publication, initial_phase_id: phase_id).run
  driver.finish
end

TournamentForfeitNative.with_fixture(users: %w[Alice Bob Carol Dave]) do |fixture|
  candidate = fixture.candidate
  plan = T::KnockoutRound.build(seeds: candidate.fetch('roster'), players_per_match: 2, round_number: 1)
  metadata = plan.slice('round', 'seeds', 'players_per_match', 'generation')
    .merge('phase_digest' => 'e' * 64, 'parent_plan_digest' => 'f' * 64)
  candidate.merge!('format' => 'knockout', 'players_per_match' => 2, 'knockout' => metadata)
  candidate['schedule_id'], candidate['matches'] = T::KnockoutSchedule.matches(
    metadata: metadata, generation: candidate['roster_generation'])
  candidate['matches'].each do |match|
    preview = fixture.services.fetch('Alice').forfeit_preview(match_id: match['match_id'],
      leg: match['leg'], loser: match['players'].last, expected_schedule_id: candidate['schedule_id'])
    fixture.services.fetch('Alice').confirm_forfeit(preview: preview)
  end
  validated = fixture.services.fetch('Alice').result_view
  assert_equal(2, validated['results'].size)
  assert(validated['results'].all? { |receipt| receipt['kind'] == 'ordinary-match-forfeit-v2' &&
    receipt['decision'] && receipt['organizer'] == 'alice' }, 'Fixture lacks validated v2 public decisions')
  original = Marshal.dump(validated)
  root = {'candidate' => candidate, 'tournament_id' => 5}
  reader = ->(phase, _) { phase['schedule_id'] == candidate['schedule_id'] ?
    fixture.services.fetch('Alice').result_view : {'results' => [], 'standings' => []} }
  journal = T::OperationJournal.new(directory: File.join(fixture.instance_variable_get(:@directory), 'phase'),
    owner: 'alice', backend_identity: 'historical-forfeit')
  make_store = -> { T::ServerPhaseStore.new(table: fixture.documents.for_user('Alice'),
    journal: journal, user: -> { 'Alice' }, source: -> { root }, results: reader) }
  program = TournamentEntryContextTest::Program.new
  publication = {'title' => 'Historical forfeit', '__insertion_user' => 'alice', 'publication_key' => 'fixture'}
  show_forfeit_details(program, root.merge('storage' => 'confirmed', 'results' => validated), publication)
  make_store.call.advance(expected_schedule_id: candidate['schedule_id'])
  # Reconstruct via a new store, rather than feeding a hand-built history to UI.
  observed = make_store.call.current
  assert(observed['candidate']['schedule_id'] != candidate['schedule_id'], 'Sporting phase did not advance')
  compact = observed.fetch('phase_history').first.fetch('view').fetch('results')
  assert_equal(validated['results'].map { |row| row.slice('kind', 'match_id', 'leg', 'summary', 'decision', 'organizer') },
    compact, 'History dropped already validated public forfeit fields')
  assert(compact.all? { |row| row.frozen? && row['decision'].frozen? }, 'History is not an immutable projection')
  response = observed.merge('storage' => 'confirmed', 'results' => reader.call(observed['candidate'], root))
  show_forfeit_details(program, response, publication, phase_id: candidate['schedule_id'])
  assert_equal(original, Marshal.dump(validated), 'History projection mutated validated receipts')
ensure
  program&.finalize
  program&.class&.app_runtime&.close
end
puts 'PASS validated current and cold historical v2 forfeit details: decision, organizer and unchanged receipts'
