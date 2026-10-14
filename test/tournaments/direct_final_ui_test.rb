require_relative '../support/tournament_individual_ui'
include GameRoomTest::Assertions
I = TournamentIndividualUI
F = I::F
T = I::T
language = ARGV.include?('--pl') ? 'pl' : 'en'
GameRoomLocalization.boot(settings: {'interface_language' => language, 'known_languages' => [language]})
L = ->(message) { GameRoomContent.utf8(GameRoomLocalization.translate(message)) }
if ARGV.include?('--binary')
  verbose, $VERBOSE = $VERBOSE, nil
  begin
    %w[local_fixed_team_execution_screen local_fixed_team_execution_details local_individual_execution_screen].each do |name|
      path = File.expand_path('../../lib/tournaments/' + name + '.rb', __dir__)
      Object.class_eval(File.binread(path), path)
    end
  ensure
    $VERBOSE = verbose
  end
end
fixture = I.fixture(names: ARGV.include?('--unicode') ? %w[Żaneta Łukasz] : %w[Alpha Beta],
  rematch: true, group_advancement: T::GroupAdvancement::AUTOMATIC)
driver = TournamentNativeDriver.new
hub = T::LocalTestHub.new(**I.args(fixture))
driver.step(L.call('Choose a test participant'), [13]) do |form|
  F.field(form, L.call('Test participant name')).set_text('Organizator')
  form.index = form.fields.index(F.button(form, L.call('Use test participant')))
end
driver.step(L.call('Local tournament tests'), [13]) { |form| form.index = form.fields.index(F.button(form, L.call('Individual matches — create a plan'))) }
driver.step(L.call('Tournament to plan'), [27]) do |form|
  F.button(form, L.call('Preview individual plan')).press
  F.button(form, L.call('Accept displayed plan')).press
end
driver.step(L.call('Local tournament tests'), [27])
hub.run; driver.finish
record = I.record(fixture)
assert_equal('knockout', record['preview']['source']['candidate']['format'])
assert_equal(1, record['evidence']['plan']['matches'].size)
match = record['evidence']['plan']['matches'].first
fixture[:now] = match['windows'].first['opens'] + 60
selectors = {intent_id: record['preview']['intent_id'], match_id: match['match_id'], leg: match['leg'], window_id: match['windows'].first['id']}
people = match['players'].sort_by { |person| person['seat'] }.map { |person| person['username'] }
people.each { |actor| I.with_connection(fixture, actor) { |c| assert_equal(:confirmed, c.perform(action: :declare, selectors: selectors, availability: 'ready', expected_revision: 0)[:operation][:state]) } }
digest = nil
I.with_connection(fixture, people.first) do |c|
  effect = c.perform(action: :request_match, selectors: selectors, expires_at: match['windows'].first['closes'] - 1)[:coordination]
  assert_equal(:bound, effect[:state])
  digest = T::CoordinationContract.digest(effect[:binding].to_h)
end
people.each do |actor|
  I.with_connection(fixture, actor) do |c|
    consent = c.perform(action: :consent, selectors: selectors, binding_digest: digest)[:admission][:effect]
    assert_equal(:confirmed, c.perform(action: :enter, selectors: selectors, consent_id: consent['id'])[:admission][:state])
  end
end
I.with_connection(fixture, people.first) { |c| assert_equal(:confirmed, c.perform(action: :start_local_game, selectors: selectors, binding_digest: digest)[:local_game][:state]) }
moves = ARGV.include?('--draw') ? [[0,0],[0,1],[0,2],[1,1],[1,0],[1,2],[2,1],[2,0],[2,2]] : [[0,0],[1,0],[0,1],[1,1],[0,2]]
moves.each_with_index do |(x,y), index|
  I.with_connection(fixture, people[index % 2]) do |c|
    status = c.perform(action: :local_game_status, selectors: selectors)[:local_game][:status]
    assert_equal(:confirmed, c.perform(action: :local_game_move, selectors: selectors, operation_id: "direct-ui-move-#{index}", revision: status['revision'], move_selection: {'kind' => 'grid', 'action' => 'select', 'x' => x, 'y' => y})[:local_game][:state])
  end
end
I.with_connection(fixture, people.first) do |c|
  status = c.perform(action: :local_game_status, selectors: selectors)[:local_game][:status]
  assert_equal(:confirmed, c.perform(action: :finalize_local_game, selectors: selectors, revision: status['revision'])[:local_game][:state])
end
path = File.join(fixture[:plans], 'individual-v1/execution-v1/state.json')
before = File.binread(path)
driver = TournamentNativeDriver.new
hub = T::LocalTestHub.new(**I.args(fixture))
drain = lambda do |form|
  2.times do
    work = hub.instance_variable_get(:@individual_entry).instance_variable_get(:@readiness_work)
    wait_background_work(work, timeout: 30) if work && work.busy?
    form.update
  end
end
driver.step(L.call('Choose a test participant'), [13]) do |form|
  F.field(form, L.call('Test participant name')).set_text(people.first)
  form.index = form.fields.index(F.button(form, L.call('Use test participant')))
end
driver.step(L.call('Local tournament tests'), [13]) { |form| form.index = form.fields.index(F.button(form, L.call('Individual matches — local execution'))) }
driver.step(L.call('Accepted individual plans'), [13]) do |form|
  F.button(form, L.call('Check status')).press; drain.call(form)
  form.index = form.fields.index(F.button(form, L.call('View tournament standings')))
end
driver.step(L.call('Tournament standings'), [27]) do |form|
  content = F.field(form, L.call('Tournament standings')).text
  if ARGV.include?('--draw')
    assert(content.include?(L.call('Knockout draw: prepare an additional game for the tied participants.')), content)
    assert(!content.include?(L.call('Tournament completed')), 'Draw claimed a champion')
  else
    assert(content.include?(L.call('Tournament completed')), content)
    assert(content.include?(L.call('Tournament winner: %{player}') % {player: people.first.downcase}), content)
  end
end
driver.step(L.call('Accepted individual plans'), [13]) { |form| form.index = form.fields.index(F.button(form, L.call('Preview knockout round'))) }
driver.step(L.call('Accepted individual plans'))
driver.step(L.call('Accepted individual plans'), [27]) do |form|
  drain.call(form)
  if ARGV.include?('--draw')
    view = hub.instance_variable_get(:@individual_entry).controller.view
    assert_equal(:confirmed, view[:phase_preview][:state])
    assert_equal(1, view[:phase_preview][:plan]['replay']['attempt'])
    expected = L.call('Additional knockout games, attempt %{number}. Only unresolved matches are repeated.') % {number: 1}
    assert(F.field(form, L.call('Individual execution status')).text.include?(expected), 'Missing additional match explanation')
  else
    assert(F.field(form, L.call('Individual execution status')).text.include?(L.call('Tournament completed')), 'Completed final asked for group results')
  end
end
driver.step(L.call('Local tournament tests'), [27])
hub.run; driver.finish
assert_equal(before, File.binread(path))
fixture[:program].finalize; fixture[:program].class.app_runtime.close
puts(ARGV.include?('--draw') ? 'PASS native knockout draw UI: actual drawn game, additional match preview and unchanged history' :
  'PASS direct final native UI: actual Runner winner, completed standings, no next round and unchanged history')
