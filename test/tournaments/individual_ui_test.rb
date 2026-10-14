require_relative '../support/tournament_individual_ui'
include GameRoomTest::Assertions
I = TournamentIndividualUI
F = I::F
T = I::T
if ARGV.include?('--surface')
  require File.join(EltenTestHost.root, 'src/ui/controls/grid_box')
  Object.const_set(:GridBox, EltenAPI::Controls.const_get(:GridBox))
  require_relative '../../lib/game_surfaces'
end
language = ARGV.include?('--pl') ? 'pl' : 'en'
GameRoomLocalization.boot(settings: {'interface_language' => language, 'known_languages' => [language]})
L = ->(value) { GameRoomContent.utf8(GameRoomLocalization.translate(value)) }
if ARGV.include?('--binary')
  verbose, $VERBOSE = $VERBOSE, nil
  begin
    %w[local_dispatch_screen local_fixed_team_plan_screen local_fixed_team_execution_screen local_fixed_team_execution_details local_individual_execution_screen local_individual_plan_screen].each do |name|
      path = File.expand_path('../../lib/tournaments/' + name + '.rb', __dir__)
      Object.class_eval(File.binread(path), path)
    end
  ensure
    $VERBOSE = verbose
  end
end
fixture = I.fixture
T::LocalExecutionPlanStorage.prepend(Module.new do
  def write(document)
    result = super
    if $individual_ui_lost_plan_reply
      $individual_ui_lost_plan_reply = false
      raise IOError, 'Simulated lost plan reply after durable acceptance'
    end
    result
  end
end)
driver = TournamentNativeDriver.new
hub = T::LocalTestHub.new(**I.args(fixture))
driver.step(L.call('Local tournament tests'), [13]) do |form|
  F.button(form, L.call('Advanced local test tools')).press
  form.index = form.fields.index(F.button(form, L.call('Change test participant')))
end
driver.step(L.call('Choose a test participant'), [13]) do |form|
  F.field(form, L.call('Test participant name')).set_text('Organizator')
  form.index = form.fields.index(F.button(form, L.call('Use test participant')))
end
driver.step(L.call('Local tournament tests'), [13]) do |form|
  form.index = form.fields.index(F.button(form, L.call('Individual matches — create a plan')))
end
driver.step(L.call('Tournament to plan'), [27]) do |form|
  seats = F.field(form, L.call('Seats: one match per line, accounts separated by commas'))
  assert(seats.text.include?('alpha') && seats.text.include?('beta'), seats.text)
  seats.set_text('beta, alpha')
  F.button(form, L.call('Preview individual plan')).press
  assert(F.field(form, L.call('Individual plan preview')).text.include?('Beta'), 'Missing reviewed roster')
  # Exercise the shared failure renderer against the actual native details field.
  screen = T::LocalIndividualPlanScreen.allocate
  screen.instance_variable_set(:@details, F.field(form, L.call('Individual plan preview')))
  screen.send(:show_failure, {state: :blocked, reason: :non_competing_player})
  assert(F.field(form, L.call('Individual plan preview')).text.include?(L.call('Every assigned participant must compete for the result. Choose a mode without a permanent non-playing judge.')), 'Missing translated non-competing judge explanation')
  F.button(form, L.call('Preview individual plan')).press
  $individual_ui_lost_plan_reply = true
  F.button(form, L.call('Accept displayed plan')).press
  assert(F.field(form, L.call('Individual plan preview')).text.include?(L.call('Acceptance is uncertain. Use Check plan acceptance; do not send a new plan.')), 'Lost acceptance reply was not retained')
  F.button(form, L.call('Check plan acceptance')).press
  assert(F.field(form, L.call('Individual plan preview')).text.include?(L.call('Plan accepted. Open Individual matches — local execution to check its matches.')), 'UI acceptance was not confirmed')
  if ARGV.include?('--dispatch-config')
    F.field(form, L.call('Maximum simultaneous tables')).set_text('3')
    F.button(form, L.call('Set tournament table limit')).press
    assert(F.field(form, L.call('Individual plan preview')).text.include?('3'), 'Missing confirmed table limit')
  end
end
driver.step(L.call('Local tournament tests'), [27])
hub.run; driver.finish
record = I.record(fixture)
assert(record, 'No durable UI acceptance')
match = record['evidence']['plan']['matches'].first
fixture[:now] = match['windows'].first['opens'] + 60
selectors = {intent_id: record['preview']['intent_id'], match_id: match['match_id'], leg: match['leg'], window_id: match['windows'].first['id']}
%w[Alpha Beta].each do |actor|
  I.with_connection(fixture, actor) { |c| assert_equal(:enabled, c.perform(action: :dispatch_enable, selectors: selectors)[:dispatch][:state]) } if ARGV.include?('--dispatch-config')
  I.with_connection(fixture, actor) { |c| assert_equal(:confirmed, c.perform(action: :declare, selectors: selectors, availability: 'ready', expected_revision: 0)[:operation][:state]) }
end
digest = nil
I.with_connection(fixture, 'Alpha') do |c|
  result = c.perform(action: :request_match, selectors: selectors, expires_at: match['windows'].first['closes'] - 1)
  assert_equal(:bound, result[:coordination][:state], result.inspect)
  digest = T::CoordinationContract.digest(result[:coordination][:binding].to_h)
end
%w[Alpha Beta].each do |actor|
  I.with_connection(fixture, actor) do |c|
    consent = c.perform(action: :consent, selectors: selectors, binding_digest: digest)[:admission][:effect]
    assert_equal(:confirmed, c.perform(action: :enter, selectors: selectors, consent_id: consent['id'])[:admission][:state])
  end
end
I.with_connection(fixture, 'Alpha') { |c| assert_equal(:confirmed, c.perform(action: :start_local_game, selectors: selectors, binding_digest: digest)[:local_game][:state]) }
surface_header = nil
if ARGV.include?('--surface')
  I.with_connection(fixture, 'Beta') { |c| surface_header = c.perform(action: :local_game_surface, selectors: selectors)[:private_surface][:effect][:spec].header }
end
driver = TournamentNativeDriver.new
hub = T::LocalTestHub.new(**I.args(fixture))
complete = lambda do |form|
  2.times do
    work = hub.instance_variable_get(:@individual_entry).instance_variable_get(:@readiness_work)
    wait_background_work(work, timeout: 30) if work && work.busy?
    form.update
  end
end
driver.step(L.call('Local tournament tests'), [13]) do |form|
  F.button(form, L.call('Advanced local test tools')).press
  form.index = form.fields.index(F.button(form, L.call('Change test participant')))
end
driver.step(L.call('Choose a test participant'), [13]) do |form|
  F.field(form, L.call('Test participant name')).set_text('Beta')
  form.index = form.fields.index(F.button(form, L.call('Use test participant')))
end
driver.step(L.call('Local tournament tests'), [13]) do |form|
  form.index = form.fields.index(F.button(form, L.call('Individual matches — local execution')))
end
driver.step(L.call('Accepted individual plans'), [13]) do |form|
  F.button(form, L.call('Check status')).press; complete.call(form)
  F.button(form, L.call('Resume saved tournament')).press; complete.call(form)
  if ARGV.include?('--dispatch-config')
    F.button(form, L.call('Renew an expired tournament invitation')).press; complete.call(form)
    assert_equal(:not_coordinator, hub.instance_variable_get(:@individual_entry).controller.view[:dispatch][:reason])
    assert(F.field(form, L.call('Individual execution status')).text.include?(L.call('Only the match coordinator can perform this action.')), 'Missing readable dispatch explanation')
    screen = hub.instance_variable_get(:@individual_entry)
    labels = {
      match_window_not_open: 'The scheduled match time has not started yet.',
      match_window_closed: 'The scheduled match time has ended. No result was awarded.',
      previous_match_pending: 'The first match must finish before the return match can start.',
      matches_completed: 'All your matches in this phase are completed.'
    }
    # Presentation-only effects: backend waiting diagnostics are exercised by
    # dispatch tests; this checks their binary/translated native rendering.
    prior = screen.instance_variable_get(:@dispatch_status)
    begin
      labels.each do |reason, label|
        screen.instance_variable_set(:@dispatch_status, {state: :waiting, reason: reason}.freeze)
        F.field(form, L.call('Individual execution status')).set_text(screen.send(:status_text))
        assert(F.field(form, L.call('Individual execution status')).text.include?(L.call(label)), "Missing waiting explanation: #{reason}")
        if reason == :matches_completed
          assert(F.field(form, L.call('Individual execution status')).text.include?(L.call('Completed')), 'Completed phase must not be presented as waiting for another match')
        end
        assert(L.call(label) != label, 'Missing Polish waiting translation') if language == 'pl'
      end
    ensure
      screen.instance_variable_set(:@dispatch_status, prior)
      F.field(form, L.call('Individual execution status')).set_text(screen.send(:status_text))
    end
  end
  actions = F.field(form, L.call('My legal local moves'))
  assert_equal(9, actions.options.size)
  assert(actions.options.all? { |label| !label.include?('select') }, actions.options.inspect)
  F.button(form, L.call(ARGV.include?('--surface') ? 'View' : 'Submit selected local move')).press; complete.call(form)
  status = hub.instance_variable_get(:@individual_entry).controller.view[:local_game][:status]
  assert_equal(1, status['event_count'])
  assert_equal([], status['actions'])
  path = File.join(fixture[:plans], 'individual-v1', 'execution-v1', 'state.json')
  bytes = File.binread(path)
  damaged = JSON.parse(bytes)
  damaged['native']['cores'].first['capacity'] += 1
  File.binwrite(path, JSON.generate(damaged))
  begin
    previous = hub.instance_variable_get(:@individual_entry).controller.view
    F.button(form, L.call('Check status')).press; complete.call(form)
    assert_equal(previous, hub.instance_variable_get(:@individual_entry).controller.view)
    assert(F.field(form, L.call('Individual execution status')).text.include?(L.call('The accepted plan storage is damaged or incompatible. The last valid view is retained; no data was replaced.')), 'Missing damaged storage notice')
  ensure
    File.binwrite(path, bytes)
  end
  form.index = form.fields.index(F.button(form, L.call('View tournament standings')))
end
driver.step(surface_header, [13]) if ARGV.include?('--surface')
driver.step(L.call('Tournament standings'), [27]) do |form|
  content = F.field(form, L.call('Tournament standings')).text
  assert(content.include?('alpha') && content.include?('beta'), content)
end
driver.step(L.call('Accepted individual plans'), [27])
driver.step(L.call('Local tournament tests'), [27])
hub.run; driver.finish
assert_equal(0, fixture[:program].class.app_runtime.managed_resources.size)
fixture[:program].finalize; fixture[:program].class.app_runtime.close
puts 'PASS individual native UI: reviewed/uncertain plan acceptance, standard connection, resume, game-owned move labels, real Runner move, corrupt view retention, standings and cleanup'
