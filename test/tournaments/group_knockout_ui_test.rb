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
    %w[local_fixed_team_execution_screen local_fixed_team_execution_details local_individual_execution_screen local_individual_plan_screen].each do |name|
      path = File.expand_path('../../lib/tournaments/' + name + '.rb', __dir__)
      Object.class_eval(File.binread(path), path)
    end
  ensure
    $VERBOSE = verbose
  end
end
execute_round = ARGV.include?('--execute')
organizer_view = ARGV.include?('--organizer-view') || execute_round
accept_round = ARGV.include?('--accept-round') || organizer_view
automatic = ARGV.include?('--automatic') || accept_round
settings = automatic ? {group_advancement: T::GroupAdvancement::AUTOMATIC} : {group_count: 2, places_per_group: 1}
names = accept_round && !organizer_view ? %w[Organizator Beta Charlie Delta] : %w[Alpha Beta Charlie Delta]
fixture = I.fixture(names: names, rematch: false, **settings)
driver = TournamentNativeDriver.new
hub = T::LocalTestHub.new(**I.args(fixture))
driver.open_test_participant
driver.step(L.call('Choose a test participant'), [13]) do |form|
  F.field(form, L.call('Test participant name')).set_text('Organizator')
  form.index = form.fields.index(F.button(form, L.call('Use test participant')))
end
driver.step(L.call('Local tournament tests'), [13]) { |form| form.index = form.fields.index(F.button(form, L.call('Individual matches — create a plan'))) }
driver.step(L.call('Tournament to plan'), [27]) do |form|
  F.button(form, L.call('Preview individual plan')).press
  F.button(form, L.call('Accept displayed plan')).press
  assert(F.field(form, L.call('Individual plan preview')).text.include?(L.call('Plan accepted. Open Individual matches — local execution to check its matches.')), 'Group plan not accepted')
end
driver.step(L.call('Local tournament tests'), [27])
hub.run; driver.finish
record = I.record(fixture)
intent = record['preview']['intent_id']
fixture[:now] = record['evidence']['plan']['matches'].first['windows'].first['opens'] + 60
record['evidence']['plan']['matches'].each do |match|
  selectors = {intent_id: intent, match_id: match['match_id'], leg: match['leg'], window_id: match['windows'].first['id']}
  people = match['players'].sort_by { |person| person['seat'] }.map { |person| person['username'] }
  people.each { |actor| I.with_connection(fixture, actor) { |c| assert_equal(:confirmed, c.perform(action: :declare, selectors: selectors, availability: 'ready', expected_revision: 0)[:operation][:state]) } }
  digest = nil
  I.with_connection(fixture, people.first) do |c|
    result = c.perform(action: :request_match, selectors: selectors, expires_at: match['windows'].first['closes'] - 1)
    assert_equal(:bound, result[:coordination][:state], result.inspect)
    digest = T::CoordinationContract.digest(result[:coordination][:binding].to_h)
  end
  people.each do |actor|
    I.with_connection(fixture, actor) do |c|
      consent = c.perform(action: :consent, selectors: selectors, binding_digest: digest)[:admission][:effect]
      assert_equal(:confirmed, c.perform(action: :enter, selectors: selectors, consent_id: consent['id'])[:admission][:state])
    end
  end
  I.with_connection(fixture, people.first) { |c| assert_equal(:confirmed, c.perform(action: :start_local_game, selectors: selectors, binding_digest: digest)[:local_game][:state]) }
  [[0,0],[1,0],[0,1],[1,1],[0,2]].each_with_index do |(x,y), index|
    I.with_connection(fixture, people[index % 2]) do |c|
      status = c.perform(action: :local_game_status, selectors: selectors)[:local_game][:status]
      result = c.perform(action: :local_game_move, selectors: selectors, operation_id: "group-ui-#{match['match_id']}-#{index}",
        revision: status['revision'], move_selection: {'kind' => 'grid', 'action' => 'select', 'x' => x, 'y' => y})
      assert_equal(:confirmed, result[:local_game][:state])
    end
  end
  I.with_connection(fixture, people.first) do |c|
    status = c.perform(action: :local_game_status, selectors: selectors)[:local_game][:status]
    assert_equal(:confirmed, c.perform(action: :finalize_local_game, selectors: selectors, revision: status['revision'])[:local_game][:state])
  end
end
path = File.join(fixture[:plans], 'individual-v1/execution-v1/state.json')
before = File.binread(path)
if organizer_view
  match = record['evidence']['plan']['matches'].first
  selectors = {intent_id: intent, match_id: match['match_id'], leg: match['leg'], window_id: match['windows'].first['id']}
  I.with_connection(fixture, 'Organizator') do |connection|
    assert_equal(1, connection.catalog[:catalog].size)
    denied = connection.perform(action: :declare, selectors: selectors, availability: 'ready', expected_revision: 0)
    assert_equal(:not_participant, denied[:operation][:reason])
  end
  assert_equal(before, File.binread(path))
end
driver = TournamentNativeDriver.new
hub = T::LocalTestHub.new(**I.args(fixture))
drain = lambda do |form|
  2.times do
    work = hub.instance_variable_get(:@individual_entry).instance_variable_get(:@readiness_work)
    wait_background_work(work, timeout: 30) if work && work.busy?
    form.update
  end
end
driver.open_test_participant
driver.step(L.call('Choose a test participant'), [13]) do |form|
  F.field(form, L.call('Test participant name')).set_text(accept_round ? 'Organizator' : 'Alpha')
  form.index = form.fields.index(F.button(form, L.call('Use test participant')))
end
driver.step(L.call('Local tournament tests'), [13]) { |form| form.index = form.fields.index(F.button(form, L.call('Individual matches — local execution'))) }
driver.step(L.call('Accepted individual plans'), [13]) do |form|
  F.button(form, L.call('Check status')).press; drain.call(form)
  form.index = form.fields.index(F.button(form, L.call('View tournament standings')))
end
driver.step(L.call('Tournament standings'), [27]) do |form|
  content = F.field(form, L.call('Tournament standings')).text
  assert(content.include?(L.call('Group matches completed')), content)
  assert(!content.include?(L.call('Tournament completed')), 'Group finish presented as whole tournament finish')
  assert(content.include?(L.call('Group %{number}') % {number: 1}) && content.include?(L.call('Group %{number}') % {number: 2}), content)
end
chosen = nil
driver.step(L.call('Accepted individual plans'), [13]) { |form| form.index = form.fields.index(F.button(form, L.call('Preview knockout round'))) }
unless automatic
driver.step(L.call('Qualified units'), [13]) do |form|
  chosen = F.field(form, L.call('Qualified units')).text.split(/\r?\n/).reverse
  edit = F.field(form, L.call('Knockout seed order (one qualified unit per line)'))
  assert_equal('', edit.text)
  F.button(form, L.call('Preview knockout round')).press
  assert(F.field(form, L.call('Status')).text.include?(L.call('Enter every qualified unit exactly once in the chosen seed order.')), 'Empty seeds accepted')
  edit.set_text(chosen.join("\r\n"))
  form.index = form.fields.index(F.button(form, L.call('Preview knockout round')))
end
end
driver.step(L.call('Accepted individual plans')) if accept_round
driver.step(L.call('Accepted individual plans'), accept_round ? [13] : [27]) do |form|
  drain.call(form)
  effect = hub.instance_variable_get(:@individual_entry).controller.view[:phase_preview]
  assert_equal(:confirmed, effect[:state])
  if automatic
    expected = accept_round && !organizer_view ? [%w[beta organizator], %w[delta charlie]] : [%w[alpha delta], %w[charlie beta]]
    assert_equal(expected, effect[:plan]['matches'].map { |match| match['participants'] })
  else
    assert_equal(chosen, effect[:plan]['matches'].first['participants'])
  end
  assert(F.field(form, L.call('Individual execution status')).text.include?(L.call('Knockout preview only. No plan was accepted, no invitations were sent and no game was started.')), 'Missing preview boundary')
  if accept_round
    form.index = form.fields.index(F.button(form, L.call('Accept displayed knockout pairings')))
  end
end
if accept_round
  approval = nil
  driver.step(L.call('Accepted individual plans'))
  driver.step(L.call('Accepted individual plans'), [13]) do |form|
    drain.call(form)
    view = hub.instance_variable_get(:@individual_entry).controller.view
    approval = view[:phase_approval]
    assert(approval, F.field(form, L.call('Individual execution status')).text)
    assert_equal(:confirmed, approval[:state])
    assert_equal(view[:phase_preview][:preview], approval[:record]['preview'])
    assert(F.field(form, L.call('Individual execution status')).text.include?(L.call('Knockout pairings accepted and saved. Preview and accept the match plan to enable local matches.')), 'Missing acceptance boundary')
    form.index = form.fields.index(F.button(form, L.call('Check accepted knockout pairings')))
  end
  driver.step(L.call('Accepted individual plans')) if execute_round
  driver.step(L.call('Accepted individual plans'), execute_round ? [13] : [27]) do |form|
    drain.call(form)
    assert_equal(approval, hub.instance_variable_get(:@individual_entry).controller.view[:phase_approval])
    form.index = form.fields.index(F.button(form, L.call('Preview knockout match plan'))) if execute_round
  end
end
if execute_round
  phase_record = nil
  driver.step(L.call('Accepted individual plans'))
  driver.step(L.call('Accepted individual plans'), [13]) do |form|
    drain.call(form)
    view = hub.instance_variable_get(:@individual_entry).controller.view
    assert_equal(:confirmed, view[:phase_execution_preview][:state])
    assert(F.field(form, L.call('Individual execution status')).text.include?(L.call('Knockout match plan preview. Check players, seats and playing windows before accepting.')), 'Missing reviewed roles/windows')
    form.index = form.fields.index(F.button(form, L.call('Accept displayed knockout match plan')))
  end
  driver.step(L.call('Accepted individual plans'))
  driver.step(L.call('Accepted individual plans'), [13]) do |form|
    drain.call(form)
    result = hub.instance_variable_get(:@individual_entry).controller.view[:phase_execution]
    assert_equal(:confirmed, result[:state])
    phase_record = result[:record]
    assert_equal('knockout', phase_record['preview']['source']['candidate']['format'])
    form.index = form.fields.index(F.button(form, L.call('Check accepted knockout match plan')))
  end
  driver.step(L.call('Accepted individual plans'))
  driver.step(L.call('Accepted individual plans'), [13]) do |form|
    drain.call(form)
    assert_equal(phase_record, hub.instance_variable_get(:@individual_entry).controller.view[:phase_execution][:record])
    form.index = form.fields.index(F.button(form, L.call('Check status')))
  end
  driver.step(L.call('Accepted individual plans'), [27]) do |form|
    drain.call(form)
    rows = hub.instance_variable_get(:@individual_entry).controller.view[:tournaments]
    phase_row = rows.find { |r| r['record']['preview']['intent_id'] == phase_record['preview']['intent_id'] }
    assert_equal('awaiting_results', phase_row['progress']['knockout_state'])
    assert_equal(2, rows.size)
    assert(F.button(form, L.call('Set tournament table limit')), 'Phase table policy must be configurable')
  end
end
driver.step(L.call('Local tournament tests'), [27])
hub.run; driver.finish
assert_equal(before, File.binread(path))
fixture[:program].finalize; fixture[:program].class.app_runtime.close
puts 'PASS native group/knockout UI: actual Runner results, group tables, explicit seeds, fresh worker preview and unchanged history'
