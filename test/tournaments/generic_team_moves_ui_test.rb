require_relative '../support/tournament_moves_fixture'
require_relative '../../games/catalog'
include GameRoomTest::Assertions
F = TournamentFT2B1
T = F::T
language = ARGV.include?('--pl') ? 'pl' : 'en'
GameRoomLocalization.boot(settings: {'interface_language' => language, 'known_languages' => [language]})
L = ->(value) { GameRoomContent.utf8(GameRoomLocalization.translate(value)) }
if ARGV.include?('--binary')
  path = File.expand_path('../../lib/tournaments/local_fixed_team_execution_screen.rb', __dir__)
  previous_verbose, $VERBOSE = $VERBOSE, nil
  begin
    Object.class_eval(File.binread(path), path)
  ensure
    $VERBOSE = previous_verbose
  end
end
fixture = TournamentMovesFixture.build(game_id: 'domino', registry: GameRoomGames::CATALOG,
  game_options: {'teams' => true, 'team_count' => '2'})
begin
  driver = TournamentNativeDriver.new
  hub = T::LocalTestHub.new(**F.args(fixture))
  complete = lambda do |form|
    2.times do
      screen = hub.instance_variable_get(:@fixed_team_entry)
      work = screen.instance_variable_get(:@readiness_work)
      wait_background_work(work, timeout: 30) if work && work.busy?
      form.update
    end
  end
  driver.step(L.call('Choose a test participant'), [13]) do |form|
    F.field(form, L.call('Test participant name')).set_text('Beata')
    form.index = form.fields.index(F.button(form, L.call('Use test participant')))
  end
  driver.step(L.call('Local tournament tests'), [13]) { |form| form.index = form.fields.index(F.button(form, L.call(F::ACTION))) }
  driver.step(L.call('Accepted fixed-team plans')) do |form|
    F.button(form, L.call('Check status')).press; complete.call(form)
    view_button = F.button(form, L.call('View'))
    assert(form.instance_variable_get(:@hidden)[form.fields.index(view_button)] != true, 'Generic team view must be visible')
    F.button(form, L.call('Check original local game')).press; complete.call(form)
    screen = hub.instance_variable_get(:@fixed_team_entry)
    before = screen.controller.view[:local_game][:status]
    assert_equal(0, before['event_count'])
    assert_equal([{'kind' => 'tile', 'action' => 'deal'}], before['actions'])
    F.button(form, L.call('Submit selected local move')).press; complete.call(form)
    status = screen.controller.view[:local_game][:status]
    assert_equal('playing', status['phase'])
    assert_equal(1, status['event_count'])
    assert(status['phase_label'].is_a?(String), 'Actual game owns its turn description')
    content = F.field(form, L.call('Fixed-team execution status')).text
    assert(content.include?(GameRoomContent.utf8(status['phase_label'])), content)
    assert(!content.include?(L.call('Playing cards')), 'Domino must not be labelled as a card game')
    assert_equal(status['action_labels'].map { |label| GameRoomContent.utf8(label) }, F.field(form, L.call('My legal local moves')).options)
    matches = F.field(form, L.call('My fixed-team matches'))
    matches.index = 1; matches.trigger(:move); complete.call(form)
    assert_equal(nil, screen.controller.view[:local_game])
    assert_equal([], F.field(form, L.call('My legal local moves')).options)
  end
  driver.step(L.call('Accepted fixed-team plans'), [27])
  driver.step(L.call('Local tournament tests'), [27])
  hub.run
  driver.finish
  assert_equal(0, fixture[:program].class.app_runtime.managed_resources.size)
  puts 'PASS generic native team window: visible game view, real Domino deal, game-owned labels, selection isolation and cleanup'
ensure
  fixture[:program].finalize
  fixture[:program].class.app_runtime.close
end
