require_relative '../support/binary_rules_load' if ARGV.first&.end_with?('.eltsetup')
require_relative '../support/tournament_dispatch'
require_relative '../../lib/tournaments/local_dispatch_runtime'
include TournamentDispatchSupport
with_fixture(game: 'tic_tac_toe', names: %w[Alpha Beta], rematch: false) do |fixture|
  backend = fixture.backend
  record = backend.accept(preview: backend.preview(publication_ref: fixture.reference, base_seats: fixture.base, intent_id: 'dispatch-events'))
  intent = record['preview']['intent_id']
  fixture.now = record['evidence']['plan']['matches'].first['windows'].first['opens'] + 1
  with_dispatch(fixture, record, 'Organizator') { |d| d.configure(intent_id: intent, max_tables: 2,consent_before_table:ARGV.include?('--consent')) }
  program = TournamentEntryContextTest::Program.new(fixture.directory)
  runtime = program.class.app_runtime
  resources = []
  begin
    clients = %w[Alpha Beta].map do |name|
      fixture.actor = name
      session = T::LocalReadinessSession.new
      session.choose_actor(name)
      identity = T::LocalExecutionPlanBackend.identity(directory: File.join(fixture.directory, 'k02'), source_identity: fixture.tables.backend_identity)
      session.bind_backend(identity)
      entry = T::EntryContext.new(program: program, runtime: runtime, owner_reader: -> { fixture.owner }, account_events: session.actor_events)
      authority = session.context(program: program, owner_reader: -> { fixture.owner }, entry: entry, lease: entry.capture, actor: name, identity: identity)
      service = T::LocalTournamentDispatcher.new(plan_backend: fixture.backend(context: authority), plan_directory: File.join(fixture.directory, 'k02'),
        source_identity: fixture.tables.backend_identity, context: authority, registry: fixture.registry,
        clock: -> { fixture.now }, policy_ref: 'individual-technical-test-v1', expires_at: nil)
      original = service.method(:advance)
      calls = []
      service.define_singleton_method(:advance) { |**input| calls << Thread.current; original.call(**input) }
      worker = T::LocalDispatchRuntime.new(dispatcher: service, intent_id: intent, identity: identity, runtime: runtime)
      resources.concat([worker, authority, entry, session])
      [service, worker, calls]
    end
    drain = lambda do
      6.times do
        clients.each do |_service, worker, _calls|
          worker.update
          work = worker.instance_variable_get(:@work)
          wait_background_work(work, timeout: 30) if work.busy?
          worker.update
        end
      end
    end
    clients.each { |service, _worker, _calls| service.available(intent_id: intent, available: true) }
    drain.call
    if ARGV.include?('--consent')
      assert_equal([],dispatch_state(fixture)['native']['cores'],'Proposal created a table before acceptance')
      path=File.join(fixture.directory,'k02/individual-v1/execution-v1/state.json')
      bytes=File.binread(path)
      counts=clients.map{|_,_,calls|calls.size}
      20.times{clients.each{|_,worker,_|worker.update}}
      assert_equal(counts,clients.map{|_,_,calls|calls.size},'Waiting for consent keeps waking its own dispatcher')
      assert_equal(bytes,File.binread(path),'Waiting for consent keeps writing its own proposal')
      clients.each do |service,_worker,_calls|
        token=service.snapshot(intent_id:intent)['proposal']['token']
        service.accept(intent_id:intent,expected_proposal:token,require_expected:true)
      end
      drain.call
    end
    core = dispatch_state(fixture)['native']['cores'].fetch(0)
    assert_equal(1, core['invitations'].size)
    assert_equal(1, core['participants'].size)
    counts = clients.map { |_, _, calls| calls.size }
    20.times { clients.each { |_, worker, _| worker.update } }
    assert_equal(counts, clients.map { |_, _, calls| calls.size })
    before_leases = dispatch_state(fixture)['dispatch']['availability'].fetch(intent)
    fixture.now += T::LocalDispatchContract::TTL / 2
    drain.call
    renewed = dispatch_state(fixture)['dispatch']['availability'].fetch(intent)
    %w[alpha beta].each do |account|
      assert_equal(fixture.now, renewed[account]['observed_at'])
      assert_equal(fixture.now + T::LocalDispatchContract::TTL, renewed[account]['expires_at'])
      assert_equal(before_leases[account]['revision'], renewed[account]['revision'])
    end
    assert_equal(1, dispatch_state(fixture)['native']['cores'].first['participants'].size)
    clients.each { |service, _, _| assert_equal(:confirmed, service.accept(intent_id: intent)[:state]) }
    drain.call
    assert_equal(1, dispatch_state(fixture)['executions'].values.count { |row| row['start'] })
    if ARGV.include?('--completion')
      if ARGV.include?('--lost-result')
        fault = Module.new do
          def write(document, receipt: nil)
            result = super
            if receipt && receipt['kind'] == 'result' && !$dispatch_result_lost
              $dispatch_result_lost = true
              raise GameRoomTournaments::LocalFixedTeamExecutionStorage::Unconfirmed.new(attempt_id: 'dispatch-lost-result', receipt: receipt)
            end
            result
          end
        end
        T::LocalFixedTeamExecutionStorage.prepend(fault)
      end
      row = dispatch_state(fixture)['executions'].values.find { |value| value['start'] }
      begin
        moves = ARGV.include?('--draw') ? [[0,0],[1,1],[2,2],[0,1],[0,2],[2,0],[1,0],[1,2],[2,1]] : [[0,0],[1,0],[0,1],[1,1],[0,2]]
        finish_dispatch_board(fixture, record, row, clock: -> { fixture.now }, moves: moves, finalize: false)
      ensure
        # The sequential actor helper creates its own test Program runtime.
        # Restore the still-open clients' runtime before delivering their events.
        program.class.app_runtime = runtime
      end
      fixture.now = row['request']['window']['closes'] if ARGV.include?('--past-deadline')
      drain.call
      clients.each { |_, worker, _| assert_equal(:matches_completed, worker.last[:reason]) }
      path = File.join(fixture.directory, 'k02/individual-v1/execution-v1/state.json')
      bytes = File.binread(path)
      counts = clients.map { |_, _, calls| calls.size }
      fixture.now += T::LocalDispatchContract::TTL * 2
      20.times { clients.each { |_, worker, _| worker.signal; worker.update } }
      assert_equal(counts, clients.map { |_, _, calls| calls.size })
      assert_equal(bytes, File.binread(path))
      assert_equal({}, dispatch_state(fixture)['busy'])
      assert_equal(1, dispatch_state(fixture)['executions'].values.count { |value| value['result'] })
      assert_equal(true, $dispatch_result_lost) if ARGV.include?('--lost-result')
    elsif ARGV.include?('--interruption')
      service = clients.first[0]
      active = service.snapshot(intent_id: intent)['active'].first
      execution = service.send(:execution, record, active)
      execution.revoke_coordinator(expected_epoch: execution.coordinator_epoch)
      drain.call
      clients.each { |_, worker, _| assert_equal(:execution_interrupted, worker.last[:reason]) }
      bytes = File.binread(File.join(fixture.directory, 'k02/individual-v1/execution-v1/state.json'))
      counts = clients.map { |_, _, calls| calls.size }
      fixture.now += T::LocalDispatchContract::TTL * 2
      20.times { clients.each { |_, worker, _| worker.signal; worker.update } }
      assert_equal(counts, clients.map { |_, _, calls| calls.size })
      assert_equal(bytes, File.binread(File.join(fixture.directory, 'k02/individual-v1/execution-v1/state.json')))
      assert_equal(2, dispatch_state(fixture)['busy'].size)
      assert_equal(nil, dispatch_state(fixture)['executions'].values.first['result'])
      clients.each { |service, _, _| service.available(intent_id: intent, available: true) }
      renewed_bytes = File.binread(File.join(fixture.directory, 'k02/individual-v1/execution-v1/state.json'))
      clients.each do |service, _, calls|
        effect = service.advance(intent_id: intent)
        assert_equal(Thread.current, calls.pop) # Explicit synchronous service probe.
        assert_equal(:blocked, effect[:state])
        assert_equal(:execution_interrupted, effect[:reason])
      end
      assert_equal(renewed_bytes, File.binread(File.join(fixture.directory, 'k02/individual-v1/execution-v1/state.json')))
      assert_equal(1, dispatch_state(fixture)['native']['cores'].size)
      assert_equal(2, dispatch_state(fixture)['busy'].size)
    else
    # A separate consumer of the same authenticated account withdraws. The
    # earlier heartbeat may not overwrite that newer snapshot.
    fixture.now += T::LocalDispatchContract::TTL / 2
    other = T::LocalTournamentDispatcher.new(**clients[0][0].instance_variable_get(:@options))
    other.available(intent_id: intent, available: false)
    drain.call
    assert_equal(false, dispatch_state(fixture)['dispatch']['availability'][intent]['alpha']['available'])
    assert_equal(:availability_changed, clients[0][1].last[:reason])
    counts = clients.map { |_, _, calls| calls.size }
    20.times { clients.each { |_, worker, _| worker.update } }
    assert_equal(counts, clients.map { |_, _, calls| calls.size })
    clients[0][1].close
    withdrawn = dispatch_state(fixture)['dispatch']['availability'][intent]['alpha']
    fixture.now += T::LocalDispatchContract::TTL
    drain.call
    assert_equal(withdrawn, dispatch_state(fixture)['dispatch']['availability'][intent]['alpha'])
    assert_equal(2, dispatch_state(fixture)['busy'].size)
    end
    clients.each { |_, _, calls| assert(calls.all? { |thread| thread != Thread.current }) }
  ensure
    resources.each(&:close)
    program.finalize
    runtime.close
  end
  assert_equal(0, runtime.managed_resources.size)
end
puts 'PASS event-driven tournament dispatcher, native background tasks, no idle polling, automatic Start and cleanup'
