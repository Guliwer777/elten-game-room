# encoding: UTF-8
require_relative '../support/ui'
require_relative '../support/tournament_local_hub'
require_relative '../support/tournament_entry_context'
require_relative '../../lib/tournaments/local_test_hub'
include GameRoomTest::Assertions
G = GameRoomTournaments
assert(G.const_defined?(:EntryContext), 'R3: brak lifecycle lokalnego wejścia zarządzanego przez Program i runtime')
program = TournamentEntryContextTest::Program.new
runtime = program.class.app_runtime
owner = 'RealOwner'
context = G::EntryContext.new(program: program, runtime: runtime, owner_reader: -> { owner }, actor: 'Bob')
lease = context.capture
assert(context.current?(lease), 'Nowy lease nie jest aktualny')
assert(program.managed_resources.include?(context) && runtime.managed_resources.include?(context), 'Brak dwóch rejestracji zasobów')
assert(context.coordination_context(request: nil) == :context_unavailable, 'Stabilne konto podszywa się pod źródło auth')
owner = 'InneKonto'
assert(!context.current?(lease), 'Nie zauważono zmiany właściciela')
owner = 'RealOwner'
assert(!context.current?(lease), 'Powrót konta ożywił stary lease')
context.close
context.close
assert(program.managed_resources.size == 0 && runtime.managed_resources.size == 0, 'Zamknięty lease pozostał w rejestrze')
20.times do
  fresh = G::EntryContext.new(program: program, runtime: runtime, owner_reader: -> { owner }, actor: 'Bob')
  assert(!fresh.current?(lease), 'Nowe wejście przyjęło lease starego')
  fresh.close
end
assert(program.managed_resources.size == 0 && runtime.managed_resources.size == 0, 'Reopen gromadzi zamknięte konteksty')
context = G::EntryContext.new(program: program, runtime: runtime, owner_reader: -> { owner }, actor: 'Bob')
lease = context.capture
program.finalize
assert(!context.current?(lease) && runtime.managed_resources.size == 0, 'Finalizacja Programu nie zamknęła kontekstu')
program = TournamentEntryContextTest::Program.new
runtime = program.class.app_runtime
context = G::EntryContext.new(program: program, runtime: runtime, owner_reader: -> { owner }, actor: 'Bob')
lease = context.capture
runtime.close
assert(!context.current?(lease) && program.managed_resources.size == 0, 'Zamknięcie runtime nie zakończyło wejścia')
puts 'PASS R3/R5/R6: dwa rzeczywiste Registry, idempotent close/reopen, oddzielny owner/aktor, zatrzask i context_unavailable'

require_relative '../support/tournament_coordination_fixture'
assert(G::EntryContext.instance_method(:initialize).parameters.any? { |_, name| name == :account_events }, 'R4: brak jawnego źródła zdarzeń konta')
[:account, :backend, :grant].each do |kind|
  sources = {account: TournamentEntryContextTest::Events.new('alice'),
    backend: TournamentEntryContextTest::Events.new('fixture:owner'), grant: TournamentEntryContextTest::Events.new('grant-1')}
  program = TournamentEntryContextTest::Program.new
  context = G::EntryContext.new(program: program, runtime: program.class.app_runtime,
    owner_reader: -> { sources[:account].snapshot[:value] }, actor: 'Bob', backend_identity: 'fixture:owner',
    account_events: sources[:account], backend_events: sources[:backend], grant_events: sources[:grant])
  lease = context.capture
  request = G::CoordinationRequest.build(TournamentCoordinationFixture.request, registry: GameRoomGames::CATALOG)
  full = context.coordination_context(request: request)
  assert(full.keys.sort == %w[account backend_identity runtime generation epoch cancelled grant_epoch].sort, 'Zły schemat CoordinationService')
  assert(full['generation'] == request.to_h['execution_generation'] && full['account'] == 'alice', 'Aktor/lokalny UUID udaje authority')
  target = context.target_context(scope: request.to_h['scope'])
  assert(target.keys.sort == %w[scope account runtime_id epoch cancelled].sort, 'Sklejono schemat MatchTargetGuard z CoordinationService')
  source = sources.fetch(kind)
  initial = source.snapshot[:value]
  source.emit('inna-wartosc')
  source.emit(initial)
  assert(context.capture['epoch'] == lease['epoch'] + 2, 'Producent nie dostarczył obu zdarzeń ABA')
  assert(!context.current?(lease) && context.coordination_context(request: request) == :context_unavailable, 'ABA ożywiło authority')
  context.close
  assert(sources.values.all? { |item| item.listeners.empty? }, 'Zamknięcie zatrzymało callbacki')
end
puts 'PASS R4/R5: emitowane account/backend/grant ABA, dwie epoki, odrębne schematy; authority tylko testowe, cleanup callbacków'

# Prawdziwy hostowy Runtime i Program, bez main/scen/urządzeń i bez plików aplikacji.
module Log
  def self.debug(_message); end
  def self.warning(_message); end
  def self.info(_message); end
end
require EltenTestHost.file('src/eapi/program.rb')
manifest = Struct.new(:id, :namespace_name, :execution).new('19d0c035-2e6d-4528-bfd9-f5ac2542dfe1', 'EntryLifecycleProbe', Programs::Execution::Spec.new({'backend' => 'runtime'}))
native = Programs::Runtime.new(entry_id: 'entry-probe', root: '', manifest: manifest)
klass = Programs.with_runtime(native) { Class.new(::Program) }
klass.instance_variable_set(:@app_runtime, native)
program = klass.new
context = G::EntryContext.new(program: program, runtime: native, owner_reader: -> { 'Alice' })
lease = context.capture
assert(context.current?(lease), 'Natywny runtime nie ma aktywnego lease')
Programs.unregister_runtime(native)
assert(!context.current?(lease) && program.managed_resources.size == 0, 'Natywny unregister nie zakończył lease')
replacement = Programs::Runtime.new(entry_id: 'entry-probe', root: '', manifest: manifest)
klass.instance_variable_set(:@app_runtime, replacement)
assert(!context.current?(lease), 'Nowy Runtime z tym samym entry_id ożywił lease')
fresh = G::EntryContext.new(program: program, runtime: replacement, owner_reader: -> { 'Alice' })
program.finalize(reason: :error)
assert(!fresh.current?(fresh.capture) && replacement.managed_resources.size == 0, 'Natywne Program.finalize pozostawiło lease')
Programs.unregister_runtime(replacement)
puts 'PASS R3 native: rzeczywiste Runtime.new/manage/unregister oraz Program.finalize; ta sama tożsamość aplikacji nie ożywia lease'
