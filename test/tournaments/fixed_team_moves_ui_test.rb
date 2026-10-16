# encoding: UTF-8
require_relative '../support/tournament_moves_fixture'
include GameRoomTest::Assertions
F = TournamentFT2B1
T = F::T
language = ARGV.include?('--pl') ? 'pl' : 'en'
GameRoomLocalization.boot(settings: {'interface_language' => language, 'known_languages' => [language]})
L = ->(value) { GameRoomContent.utf8(GameRoomLocalization.translate(value)) }
if ARGV.include?('--binary')
  verbose, $VERBOSE = $VERBOSE, nil
  begin
    %w[game_session_contracts live_session_store game_room_transport game_repository live_session_writer].each do |name|
      path = File.expand_path('../../lib/' + name + '.rb', __dir__)
      Object.class_eval(File.binread(path), path)
    end
    %w[local_fixed_team_admission local_fixed_team_start local_fixed_team_moves local_fixed_team_result local_fixed_team_execution_storage local_fixed_team_execution local_fixed_team_coordination_port local_fixed_team_connection local_fixed_team_entry local_fixed_team_native_endpoint local_fixed_team_native_provider local_fixed_team_execution_screen].each do |name|
      path = File.expand_path('../../lib/tournaments/' + name + '.rb', __dir__)
      Object.class_eval(File.binread(path), path)
    end
  ensure
    $VERBOSE = verbose
  end
end
require_relative '../support/elten_array_shuffle'
fixture = TournamentMovesFixture.build
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
  fault = Module.new do
    def write(document, receipt: nil)
      result = super
      if $ui_move_lost && receipt && receipt['kind'] == 'move'
        $ui_move_lost = false
        raise GameRoomTournaments::LocalFixedTeamExecutionStorage::Unconfirmed.new(attempt_id: 'ui-lost-move', receipt: receipt)
      end
      result
    end
  end
  T::LocalFixedTeamExecutionStorage.prepend(fault)
  driver.open_test_participant
  driver.step(L.call('Choose a test participant'), [13]) do |form|
    F.field(form, L.call('Test participant name')).set_text('Beata')
    form.index = form.fields.index(F.button(form, L.call('Use test participant')))
  end
  driver.step(L.call('Local tournament tests'), [13]) { |form| form.index = form.fields.index(F.button(form, L.call(F::ACTION))) }
  driver.step(L.call('Accepted fixed-team plans')) do |form|
    F.button(form, L.call('Check status')).press; complete.call(form)
    F.button(form, L.call('Submit selected local move')).press; complete.call(form)
    screen = hub.instance_variable_get(:@fixed_team_entry)
    assert_equal(nil, screen.controller.view[:local_game])
    F.button(form, L.call('Check original local game')).press; complete.call(form)
    before = screen.controller.view[:local_game][:status]
    assert_equal(0, before['event_count'])
    assert_equal([{'kind' => 'command', 'action' => 'deal'}], before['actions'])
    actions = F.field(form, L.call('My legal local moves'))
    assert_equal([L.call('Deal cards')], actions.options)
    $ui_move_lost = true
    F.button(form, L.call('Submit selected local move')).press
    F.button(form, L.call('Submit selected local move')).press
    complete.call(form)
    assert_equal(:uncertain, screen.controller.view[:local_game][:state])
    assert_equal(1, screen.instance_variable_get(:@move_intents).size)
    F.button(form, L.call('Check original local move')).press; complete.call(form)
    result = screen.controller.view[:local_game]
    assert_equal(:confirmed, result[:state])
    assert_equal('bidding', result[:status]['phase'])
    assert_equal(1, result[:status]['event_count'])
    assert_equal({}, screen.instance_variable_get(:@move_intents))
    assert(F.field(form, L.call('Fixed-team execution status')).text.include?(L.call('Bidding')), 'Wrong phase presentation')
    matches = F.field(form, L.call('My fixed-team matches'))
    matches.index = 1; matches.trigger(:move); complete.call(form)
    assert_equal(nil, screen.controller.view[:local_game])
    assert_equal([], actions.options)
  end
  driver.step(L.call('Accepted fixed-team plans'), [27])
  driver.step(L.call('Local tournament tests'), [27])
  hub.run
  driver.finish
  assert_equal(0, fixture[:program].class.app_runtime.managed_resources.size)
  puts 'PASS native move UI: own legal list, one deal, lost response, exact intent readback, phase, selection isolation'
ensure
  fixture[:program].finalize
  fixture[:program].class.app_runtime.close
end
