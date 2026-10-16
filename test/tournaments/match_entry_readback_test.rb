# encoding: UTF-8
require_relative '../support/ui'
require_relative '../support/tournament_local_hub'
require_relative '../support/tournament_entry_context'
require_relative '../support/tournament_match_entry'
require_relative '../support/tournament_coordination_port'
require_relative '../../lib/tournaments/match_entry_screen'
include GameRoomTest::Assertions
G = GameRoomTournaments
T = TournamentLocalHubTest
Form.prepend(T::Script)
assert(G::MatchEntry.instance_method(:initialize).parameters.any? { |_, name| name == :readback }, 'R12: brak odrębnej wstrzykiwanej ścieżki odczytu pierwotnej koordynacji')
Dir.mktmpdir('entry-readback-', ENV.fetch('TMPDIR')) do |directory|
  raw = TournamentCoordinationFixture.request
  request = G::CoordinationRequest.build(raw, registry: GameRoomGames::CATALOG)
  port = TournamentCoordinationPort.new(raw)
  original_context = TournamentCoordinationFixture.context
  service = G::CoordinationService.new(port: port, trusted_identity: port.identity,
    directory: directory, registry: GameRoomGames::CATALOG, context: -> { original_context })
  port.hook = ->(event, _) { raise G::CoordinationContract::PortUnavailable if event == :create_after }
  result = service.request_match(request: request)
  assert(result[:state] == :unknown, 'Fixture nie osiągnął niepewnego create po store')
  original_id = port.operations.fetch('create_bind').fetch('operation_id')
  original_operation = Marshal.dump(port.operations['create_bind']['operation'])
  journal = G::CoordinationJournal.new(directory: directory, scope: raw['scope'], account: 'alice', registry: GameRoomGames::CATALOG, io: ->(**_, &work) { work.call })
  journal.with_attempt do |store|
    assert(store.records(raw).any? { |record| record['operation']['operation_id'] == original_id && record['status'] == 'attempted' }, 'Fixture nie ma rzeczywistego attempted')
  end
  prepared_calls = port.calls.dup
  port.hook = nil
  port.ready.each_value { |ready| ready['state'] = 'withdrawn'; ready['revision'] = 'ready-2' }
  port.grant = nil
  port.time = 201
  lookups = []
  native_lookup = port.method(:lookup)
  port.define_singleton_method(:lookup) do |**args|
    lookups << args
    native_lookup.call(**args)
  end
  confirmed = port.copy(port.operations['create_bind'])
  [:pending, :unknown, :bound].each do |expected|
    if expected == :bound
      port.operations['create_bind'] = confirmed
    else
      port.operations['create_bind'] = confirmed.merge('status' => expected.to_s, 'reason' => 'awaiting_receipt', 'receipt' => nil, 'result' => nil)
    end
    program = TournamentEntryContextTest::Program.new
    sources = [TournamentEntryContextTest::Events.new('alice'), TournamentEntryContextTest::Events.new(port.identity), TournamentEntryContextTest::Events.new(nil)]
    context = G::EntryContext.new(program: program, runtime: program.class.app_runtime,
      owner_reader: -> { 'Alice' }, actor: 'alice', backend_identity: port.identity,
      account_events: sources[0], backend_events: sources[1], grant_events: sources[2])
    workspace = Object.new
    workspace.define_singleton_method(:actor) { 'alice' }
    service = G::CoordinationService.new(port: port, trusted_identity: port.identity, directory: directory,
      registry: GameRoomGames::CATALOG, context: -> { context.coordination_context(request: request) })
    received = []
    controller = G::MatchEntry.new(workspace: workspace, context: context, request: request,
      readback: ->(request:) { received << request; service.reconcile(request: request) })
    owner = G::LocalTestDialogs::Owner.new(-> { 'Alice' }, ->(message) { raise message })
    T.script(->(form) {
      2.times { T.button(form, 'Check status').trigger(:press) }
      assert(controller.readback_result[:state] == expected, 'Sprawdź stan nie zwróciło dokładnego receipt')
      assert(controller.readback_result[:operation_id] == original_id, 'Utworzono inne operation_id')
      assert(controller.declare_ready == :context_unavailable && controller.propose_now == :context_unavailable, 'Bound odblokował start/mutację')
      form.cancel_button.trigger(:press)
    }) { G::MatchEntryScreen.new(program: program, workspace: workspace, owner: owner, controller: controller).run }
    assert(received.length == 2 && received.all? { |item| item.equal?(request) }, 'Odtworzono request z innej generacji')
    assert(sources.all? { |source| source.listeners.empty? }, 'Reopen zachował subskrypcje')
  end
  phase = port.calls.drop(prepared_calls.length)
  assert(phase.all? { |name| [:negotiate, :snapshot, :lookup].include?(name) }, 'Readback wykonał rezerwację/create')
  assert(lookups.length == 6 && lookups.all? { |args| args[:operation_id] == original_id && args[:kind] == 'create_bind' }, 'Sprawdź stan ponowiło próbę lub inny klucz')
  assert(Marshal.dump(port.operations['create_bind']['operation']) == original_operation, 'Zmienił się oryginalny attempted')
  program = TournamentEntryContextTest::Program.new
  runtime = program.class.app_runtime
  sources = [TournamentEntryContextTest::Events.new('alice'), TournamentEntryContextTest::Events.new(port.identity), TournamentEntryContextTest::Events.new(nil)]
  context = G::EntryContext.new(program: program, runtime: runtime, owner_reader: -> { 'Alice' },
    backend_identity: port.identity, account_events: sources[0], backend_events: sources[1], grant_events: sources[2])
  service = G::CoordinationService.new(port: port, trusted_identity: port.identity, directory: directory,
    registry: GameRoomGames::CATALOG, context: -> { context.coordination_context(request: request) })
  gate, entered = Queue.new, Queue.new
  before_late = port.calls.length
  port.define_singleton_method(:lookup) do |**args|
    entered << true
    gate.pop
    native_lookup.call(**args)
  end
  workspace = Object.new
  workspace.define_singleton_method(:actor) { 'alice' }
  controller = G::MatchEntry.new(workspace: workspace, context: context, request: request,
    readback: ->(request:) { service.reconcile(request: request) })
  $entry_task_tick = lambda do
    next if entered.empty?
    entered.pop
    runtime.close
    gate << true
  end
  begin
    controller.refresh
  ensure
    $entry_task_tick = nil
  end
  assert(controller.readback_result.nil?, 'R8 readback: stary wynik receipt trafił do kontrolera')
  assert(port.calls.drop(before_late).all? { |name| [:negotiate, :snapshot, :lookup].include?(name) }, 'R8 readback: stary worker wykonał mutację')
  controller.close
  program = TournamentEntryContextTest::Program.new
  context = G::EntryContext.new(program: program, runtime: program.class.app_runtime, owner_reader: -> { 'Alice' })
  workspace = Object.new
  workspace.define_singleton_method(:actor) { 'alice' }
  controller = G::MatchEntry.new(workspace: workspace, context: context, request: request,
    readback: ->(**_) { raise 'Chroniony odczyt bez authority' })
  controller.refresh
  assert(controller.readback_result[:reason] == :context_unavailable, 'R5: zwykły czytnik konta dopuścił receipt')
  controller.close
end
puts 'PASS R12/R5: rzeczywisty Service/Journal, pierwotny attempted, Check x2/nowy controller; pending/unknown/exact bound, withdrawn/grant=nil/koniec okna, zero nowych skutków'
