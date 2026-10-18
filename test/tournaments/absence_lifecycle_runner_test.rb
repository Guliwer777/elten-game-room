require_relative '../support/tournament_presence_native'
P = TournamentPresenceNative

TournamentForfeitNative.with_fixture do |f|
  f.start
  h, clock = f.h, [0.0]
  old = P.runner(f, 'Alice', clock)
  step(h, old)
  h.as('Bob') { h.view('Bob').leave }
  step(h, old)
  2.times { clock[0] += 15; step(h, old) }
  assert_equal(30_000, P.presence(h)['totals_ms']['Bob'])
  observer = P.observer(f)
  clock[0] += 400 # The new host did not observe this interval.
  fresh = P.runner(f, observer, clock)
  step(h, fresh, observer)
  assert_equal(30_000, P.presence(h, observer)['totals_ms']['Bob'], 'New host invented an unobserved absence')
  2.times { clock[0] += 15; step(h, fresh, observer) }
  assert_equal(60_000, P.presence(h, observer)['totals_ms']['Bob'])
  step(h, old, count: 5)
  assert_equal(60_000, P.presence(h)['totals_ms']['Bob'], 'Former host wrote more absence time')
  fresh.close
  clock[0] += 200
  fresh = P.runner(f, observer, clock)
  step(h, fresh, observer)
  assert_equal(60_000, P.presence(h, observer)['totals_ms']['Bob'], 'Reopened executor counted time while stopped')
  clock[0] += 15
  step(h, fresh, observer)
  assert_equal(75_000, P.presence(h, observer)['totals_ms']['Bob'])
  assert(h.join('Bob'))
  step(h, fresh, observer)
  assert(!P.snapshot(h, observer).session['__frozen'])
  assert_equal(75_000, P.presence(h, 'Bob')['totals_ms']['Bob'], 'Returning account lost the accepted cumulative history')
ensure
  old&.close
  fresh&.close
end

TournamentForfeitNative.with_fixture do |f|
  f.start
  h, clock = f.h, [0.0]
  observer = P.observer(f)
  runner = P.runner(f, observer, clock)
  step(h, runner, observer)
  %w[Alice Bob].each { |user| h.as(user) { h.view(user).leave } }
  step(h, runner, observer)
  20.times { clock[0] += 15; step(h, runner, observer) }
  assert_equal({'Alice'=>300_000, 'Bob'=>300_000}, P.presence(h, observer)['totals_ms'])
  assert(!P.snapshot(h, observer).session['__aborted'], 'Both absent fabricated a winner')
  count = h.core.entries.size
  40.times { clock[0] += 15; step(h, runner, observer) }
  assert_equal(count, h.core.entries.size, 'Exhausted unresolved absence kept writing')
  assert(h.join('Alice'))
  step(h, runner, observer)
  assert(!P.snapshot(h, observer).session['__aborted'], 'One exhausted returnee was awarded a win')
  assert(h.join('Bob'))
  step(h, runner, observer)
  assert(P.snapshot(h, observer).session['__frozen'], 'Ambiguous exhaustion silently resumed the match')
  assert_equal([], f.services.fetch(observer).result_view['results'])
ensure
  runner&.close
end

TournamentForfeitNative.with_fixture do |f|
  f.start
  h, clock = f.h, [0.0]
  runner = P.runner(f, 'Alice', clock)
  step(h, runner)
  h.as('Bob') { h.view('Bob').leave }
  step(h, runner)
  clock[0] += 15
  step(h, runner)
  clock[0] += 15
  h.view('Alice').fail_next_read = EltenAPI::LiveSessions::TimeoutError.new('presence read unavailable')
  h.as('Alice') { runner.step }
  assert(runner.take_error.is_a?(EltenAPI::LiveSessions::TimeoutError))
  assert(h.transports['Alice'].pending_move_error(h.table['__id']).nil?, 'Preflight read created a phantom write')
  clock[0] += 400
  step(h, runner)
  assert_equal(15_000, P.presence(h)['totals_ms']['Bob'], 'Host outage counted towards the absence')
  clock[0] += 15
  step(h, runner)
  assert_equal(30_000, P.presence(h)['totals_ms']['Bob'])
ensure
  runner&.close
end
puts 'PASS presence lifecycle: host/cold handover, both absent unresolved, bounded history and failed read exclusion'
