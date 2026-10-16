# encoding: UTF-8
require_relative '../support/tournament_moves_fixture'
require_relative '../support/elten_array_shuffle'
require 'open3'
require 'rbconfig'
include GameRoomTest::Assertions
F = TournamentFT2B1
T = F::T
module Session
  def self.name; 'RealAuthenticatedUser'; end
end unless defined?(Session)
language = ARGV.include?('--pl') ? 'pl' : 'en'
GameRoomLocalization.boot(settings: {'interface_language' => language, 'known_languages' => [language]})
L = ->(value) { GameRoomContent.utf8(GameRoomLocalization.translate(value)) }
if ARGV.include?('--binary')
  verbose, $VERBOSE = $VERBOSE, nil
  begin
    %w[local_fixed_team_progress local_fixed_team_execution local_fixed_team_connection local_fixed_team_entry local_fixed_team_execution_screen].each do |name|
      path = File.expand_path('../../lib/tournaments/' + name + '.rb', __dir__)
      Object.class_eval(File.binread(path), path)
    end
  ensure
    $VERBOSE = verbose
  end
end
fixture = TournamentMovesFixture.build
state_path = File.join(fixture[:plans], 'fixed-teams-v1/execution-ft2-v1/state.json')
original = File.binread(state_path)
F.with_execution(fixture, 'Beata') do |execution|
  F.select_execution(execution, fixture[:record], 0, history: true)
  progress = execution.progress
  assert_equal(6, progress['total'])
  assert_equal(0, progress['completed'])
  assert_equal(4, progress['matches'].size)
  assert_equal('playing', progress['recommendation']['stage'])
  assert_equal(fixture[:record]['evidence']['plan']['matches'].first['match_id'], progress['recommendation']['match_id'])
  assert(!JSON.generate(progress).include?('hands'), 'Private hands leaked into progress')
end
assert_equal(original, File.binread(state_path), 'Progress mutated stored execution')
2.times do |iteration|
  driver = TournamentNativeDriver.new
  hub = T::LocalTestHub.new(**F.args(fixture))
  complete = lambda do |form|
    2.times do
      work = hub.instance_variable_get(:@fixed_team_entry).instance_variable_get(:@readiness_work)
      wait_background_work(work, timeout: 30) if work && work.busy?
      form.update
    end
  end
  driver.open_test_participant
  driver.step(L.call('Choose a test participant'), [13]) do |form|
    F.field(form, L.call('Test participant name')).set_text('Beata')
    form.index = form.fields.index(F.button(form, L.call('Use test participant')))
  end
  driver.step(L.call('Local tournament tests'), [13]) { |form| form.index = form.fields.index(F.button(form, L.call(F::ACTION))) }
  driver.step(L.call('Accepted fixed-team plans')) do |form|
    F.button(form, L.call('Check status')).press; complete.call(form)
    before = File.binread(state_path)
    F.button(form, L.call('Resume saved tournament')).press; complete.call(form)
    assert_equal(before, File.binread(state_path), 'Resume wrote a second execution')
    result = hub.instance_variable_get(:@fixed_team_entry).controller.view[:local_game]
    assert_equal(:confirmed, result[:state])
    assert_equal(iteration, result[:status]['event_count'])
    assert_equal(iteration == 0 ? 'awaiting_deal' : 'bidding', result[:status]['phase'])
    assert_equal(result[:status]['actions'].size, F.field(form, L.call('My legal local moves')).options.size)
    assert(result[:status]['actions'].size > 0, 'Own deal was not restored') if iteration == 0
    if iteration == 0
      F.button(form, L.call('Submit selected local move')).press; complete.call(form)
      assert_equal(1, hub.instance_variable_get(:@fixed_team_entry).controller.view[:local_game][:status]['event_count'])
    else
      controller = hub.instance_variable_get(:@fixed_team_entry).controller
      prior = controller.view
      good = File.binread(state_path)
      begin
        bad = JSON.parse(good)
        bad['version'] = 999
        File.binwrite(state_path, JSON.generate(bad))
        F.button(form, L.call('Check status')).press; complete.call(form)
        assert_equal(:sandbox_corrupt, controller.reason)
        assert_equal(prior, controller.view)
      ensure
        File.binwrite(state_path, good)
      end
    end
  end
  driver.step(L.call('Accepted fixed-team plans'), [27])
  driver.step(L.call('Local tournament tests'), [27])
  hub.run; driver.finish
  assert_equal(0, fixture[:program].class.app_runtime.managed_resources.size)
end
probe_path = File.join(fixture[:program].data_path, 'progress-probe.json')
File.write(probe_path, JSON.generate({'directory' => fixture[:program].data_path, 'record' => fixture[:record],
  'sandbox' => fixture[:sandbox], 'plans' => fixture[:plans], 'now' => fixture[:now]}))
output, error, process = Open3.capture3(RbConfig.ruby, File.expand_path('../support/tournament_progress_cold_probe.rb', __dir__), probe_path)
assert(process.success?, output + error)
assert(output.include?('PASS cold tournament'), 'Cold progress probe did not finish')
fixture[:now] = fixture[:record]['evidence']['plan']['matches'].first['windows'].first['closes']
F.with_execution(fixture, 'Beata') do |execution|
  F.select_execution(execution, fixture[:record], 0, history: true)
  assert_equal(true, execution.progress['recommendation']['window_expired'])
  game = execution.local_game(action: :local_game_status)[:status]
  assert_equal(:outside_window, execution.local_game(action: :local_game_move, operation_id: 'expired-resume',
    revision: game['revision'], move_selection: game['actions'].first)[:reason])
end
fixture[:program].finalize; fixture[:program].class.app_runtime.close
puts 'PASS tournament resume: own progress, read-only restoration, real move, reopened UI and resource cleanup'
