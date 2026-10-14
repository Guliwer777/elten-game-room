# encoding: UTF-8
require_relative '../support/tournament_ft2b1_entry'
include GameRoomTest::Assertions
F = TournamentFT2B1
T = F::T
language = ARGV.include?('--pl') ? 'pl' : 'en'
GameRoomLocalization.boot(settings: {'interface_language' => language, 'known_languages' => [language]})
L = ->(value) { GameRoomContent.utf8(GameRoomLocalization.translate(value)) }
if ARGV.include?('--binary')
  verbose, $VERBOSE = $VERBOSE, nil
  begin
    %w[standings local_fixed_team_standings local_fixed_team_result local_fixed_team_progress local_fixed_team_execution_screen local_fixed_team_execution_details].each do |name|
      path = File.expand_path('../../lib/tournaments/' + name + '.rb', __dir__)
      Object.class_eval(File.binread(path), path)
    end
  ensure
    $VERBOSE = verbose
  end
end
generic = ARGV.include?('--generic')
if generic
  require_relative '../../games/catalog'
end
options = generic ? {game_id: 'domino', registry: GameRoomGames::CATALOG, game_options: {'teams' => true, 'team_count' => '2'}} : {}
fixture = F.fixture(Dir.mktmpdir('s', File.expand_path('../../tmp', __dir__)), **options)
driver = TournamentNativeDriver.new
hub = T::LocalTestHub.new(**F.args(fixture))
complete = lambda do |form|
  2.times do
    work = hub.instance_variable_get(:@fixed_team_entry).instance_variable_get(:@readiness_work)
    wait_background_work(work, timeout: 30) if work && work.busy?
    form.update
  end
end
driver.step(L.call('Local tournament tests'), [13]) do |form|
  F.button(form, L.call('Advanced local test tools')).press
  form.index = form.fields.index(F.button(form, L.call('Change test participant')))
end
driver.step(L.call('Choose a test participant'), [13]) do |form|
  F.field(form, L.call('Test participant name')).set_text('Ala')
  form.index = form.fields.index(F.button(form, L.call('Use test participant')))
end
driver.step(L.call('Local tournament tests'), [13]) { |form| form.index = form.fields.index(F.button(form, L.call(F::ACTION))) }
selection = nil
driver.step(L.call('Accepted fixed-team plans'), [13]) do |form|
  F.button(form, L.call('Check status')).press; complete.call(form)
  controller = hub.instance_variable_get(:@fixed_team_entry).controller
  choices = F.field(form, L.call('My fixed-team matches')).options.join('\n')
  assert(!choices.match?(/[a-f0-9]{64}/), 'Match labels expose internal digest')
  controller.view[:matches].each do |match|
    expected = controller.view[:tournaments].first['record']['evidence']['plan']['matches'].index { |row| row['match_id'] == match['match_id'] && row['leg'] == match['leg'] } + 1
    screen = hub.instance_variable_get(:@fixed_team_entry)
    assert_equal(expected, screen.send(:match_number, match), 'Participant filtering changed match numbers')
  end
  assert_equal(nil, controller.view[:local_game])
  progress = controller.view[:tournaments].first['progress']
  assert_equal(3, progress['standings'].size)
  assert_equal(6, progress['remaining'])
  selection = controller.view[:selection]
  form.index = form.fields.index(F.button(form, L.call('View tournament standings')))
end
driver.step(L.call('Tournament standings'), [27]) do |form|
  content = F.field(form, L.call('Tournament standings')).text
  assert(content.include?(L.call('Tournament in progress')), 'Missing overall state')
  assert(content.include?(L.call('No numeric small points recorded.')), 'Missing explicit absence of game points') if generic
  %w[unit-A unit-B unit-C].each { |team| assert(content.include?(team), "Missing #{team}") }
  assert(content.include?(L.call('Tournament points: win 2, draw 1, loss 0. Game points are recorded separately.')), 'Missing scoring scope')
end
driver.step(L.call('Accepted fixed-team plans'), [27]) do |form|
  assert_equal(selection, hub.instance_variable_get(:@fixed_team_entry).controller.view[:selection])
end
driver.step(L.call('Local tournament tests'), [27])
hub.run; driver.finish
assert_equal(false, File.exist?(File.join(fixture[:plans], 'fixed-teams-v1/execution-ft2-v1/state.json')), 'Viewing table created execution data')
assert_equal(0, fixture[:program].class.app_runtime.managed_resources.size)
fixture[:program].finalize; fixture[:program].class.app_runtime.close
puts 'PASS whole standings native UI: all teams before Start, progress, read-only modal, selection and resource cleanup'
