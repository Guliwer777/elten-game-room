if ARGV.first && !ARGV.first.start_with?('--')
  ENV['ELTEN_TEST_NATIVE_CONTROLS'] = '1'
  begin
    require_relative '../support/binary_rules_load'
  ensure
    ENV.delete('ELTEN_TEST_NATIVE_CONTROLS')
  end
end
require_relative '../support/tournament_individual_ui'
require_relative '../../lib/tournaments/local_organizer_decision_screen'
require_relative '../../lib/tournaments/local_tournament_overview'
I = TournamentIndividualUI
T = GameRoomTournaments
include GameRoomTest::Assertions
language = ARGV.include?('--pl') ? 'pl' : 'en'
GameRoomLocalization.boot(settings: {'interface_language' => language, 'known_languages' => [language]})
L = ->(value) { GameRoomContent.utf8(GameRoomLocalization.translate(value)) }
state = I.fixture(rematch: false)
owner_reader = -> { I::F::OWNER }
owner = T::LocalTestDialogs::Owner.new(owner_reader, ->(message) { raise message })
workspace = T::LocalWorkspace.new(program: state[:program], registry: GameRoomGames::CATALOG,
  user: owner_reader, actor: 'Organizator', alert: ->(message) { raise message }, clock: -> { state[:now] })
session = T::LocalReadinessSession.new
session.choose_actor('Organizator')
entry = T::EntryContext.new(program: state[:program], runtime: state[:program].class.app_runtime,
  owner_reader: owner_reader, actor: 'Organizator', account_events: session.actor_events)
overview = workspace.tournament_overview(publication_ref: state[:reference], context: entry, lease: entry.capture, session: session)
assert_equal(:confirmed, overview[:state])
decision_calls = 0
original_operation = workspace.method(:individual_plan)
workspace.define_singleton_method(:individual_plan) do |**arguments|
  result = original_operation.call(**arguments)
  if arguments[:action] == :organizer_forfeit
    decision_calls += 1
    ARGV.include?('--lost-ack') ? {state: :uncertain} : result
  else
    result
  end
end
driver = TournamentNativeDriver.new
driver.step(L.call('Match for organizer decision'), [27]) do |form|
  award = I::F.button(form, L.call('Confirm forfeit: 2 points to winner, 0 to loser, no small points'))
  award.press
  assert(I::F.field(form, L.call('Decision status')).text.include?(L.call('Enter the reason for this decision.')), 'Empty decision was accepted')
  I::F.field(form, L.call('Reason for organizer decision')).set_text('Nieobecność — decyzja organizatora')
  I::F.field(form, L.call('Winner by forfeit')).index = 0
  award.press
  if ARGV.include?('--lost-ack')
    assert(I::F.field(form, L.call('Decision status')).text.include?(L.call('Decision unconfirmed. Check decision before any further action.')), 'Lost reply was treated as confirmed')
    award.press
    assert_equal(1, decision_calls, 'Uncertain decision was submitted twice')
    I::F.button(form, L.call('Check decision')).press
  end
  assert(I::F.field(form, L.call('Decision status')).text.include?(L.call('Result already recorded. It cannot be overwritten.')), 'Missing confirmed decision')
  award.press
  assert_equal(1, decision_calls, 'Immutable decision was submitted twice')
end
T::LocalOrganizerDecisionScreen.new(program: state[:program], workspace: workspace, owner: owner, rows: overview[:rows]).run
driver.finish
I.with_connection(state, 'Organizator') do |connection|
  progress = connection.tournament_catalog(publication_ref: state[:reference]).first['progress']
  assert_equal(true, progress['complete'])
  assert_equal([0,2], progress['standings'].map { |row| row['points'] }.sort)
  assert(progress['standings'].all? { |row| row['score_for'].nil? }, 'Small points invented')
end
2.times do
  driver = TournamentNativeDriver.new
  driver.step(L.call('Matches, groups and standings'), [27]) do |form|
    value = GameRoomContent.utf8(I::F.field(form, L.call('Matches, groups and standings')).text)
    assert(value.include?('Nieobecność — decyzja organizatora'), 'Overview lost organizer reason')
    assert(value.include?(L.call('Forfeit — organizer decision: %{reason}') % {reason: 'Nieobecność — decyzja organizatora'}), value)
    assert(value.include?('Alpha') && value.include?('Beta'), 'Overview lost player names')
    assert(!value.match?(/[a-f0-9]{64}/), 'Overview exposes internal match digest')
    assert(!value.include?(L.call('Match awaiting play')), 'Completed forfeit still awaits play')
  end
  T::LocalTournamentOverview.new(program: state[:program], workspace: workspace, owner: owner,
    publication: workspace.load['announcements'].first).run
  driver.finish
end
screen = T::LocalIndividualExecutionScreen.new(program: state[:program], workspace: workspace, owner: owner)
driver = TournamentNativeDriver.new
driver.step(L.call('Accepted individual plans'), [27]) do |form|
  I::F.button(form, L.call('Check status')).press
  2.times do
    work = screen.instance_variable_get(:@readiness_work)
    wait_background_work(work, timeout: 30) if work && work.busy?
    form.update
  end
  labels = I::F.field(form, L.call('My individual matches')).options.map { |value| GameRoomContent.utf8(value) }.join('\n')
  assert(labels.include?('Alpha') && labels.include?('Beta'), labels)
  assert(!labels.match?(/[a-f0-9]{64}/), 'Execution match list exposes internal digest')
  status = GameRoomContent.utf8(I::F.field(form, L.call('Individual execution status')).text)
  assert(!status.match?(/[a-f0-9]{64}/), 'Execution progress exposes internal match digest')
end
screen.run
driver.finish
entry.close
session.close
state[:program].finalize
state[:program].class.app_runtime.close
puts 'PASS native organizer decision form: required reason, explicit 2/0 award, no duplicate and cold standings'
