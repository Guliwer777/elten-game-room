# encoding: UTF-8
require_relative '../support/tournament_fixed_team_execution'
require_relative '../support/tournament_fixed_team_native_service'
require_relative '../../lib/tournaments/local_fixed_team_execution'
include TournamentFixedTeamExecutionSupport
class BoundarySecondaryFT2 < Exception; end
class BoundaryProviderFT2 < TournamentFixedTeamNativeService
  attr_accessor :callback
  attr_reader :receipt
  def committed(receipt:)
    @receipt = receipt
    callback.call if callback
  end
end
results = []
[:healthy_ambient, :postguard_throw_nil, :postguard_throw_cause, :postguard_exception, :close_context, :cleanup_throw, :cleanup_exception].each_with_index do |mode, index|
  context, record = execution_fixture(File.basename(ENV.fetch('ENTRY_EVIDENCE')) + "-#{index}")
  players = record['evidence']['plan']['matches'].first['players'].map { |p| p['username'] }
  players.each do |actor|
    execution_for(context, record, actor) do |facade|
      select_match(facade, record)
      assert_equal(:confirmed, facade.declare(availability: 'ready', expected_revision: 0)[:state])
    end
  end
  provider = BoundaryProviderFT2.new
  primary = IOError.new('Pierwotny błąd odpowiedzi')
  primary.set_backtrace(['pierwotne-io.rb:21'])
  cause = mode == :postguard_throw_cause ? ArgumentError.new('Pierwotna przyczyna') : nil
  armed = cleanup = false
  reader = -> do
    if armed
      raise BoundarySecondaryFT2, 'Błąd postguard' if mode == :postguard_exception
      throw :boundary_ft2, :nielokalny if mode.to_s.start_with?('postguard_throw')
    end
    if cleanup
      throw :boundary_ft2, :nielokalny if mode == :cleanup_throw
      raise BoundarySecondaryFT2, 'Błąd cleanup' if mode == :cleanup_exception
    end
    'WlascicielPlikow'
  end
  result = caught = service = journal = nil
  mutations_after = []
  trace = TracePoint.new(:call) do |point|
    next unless point.event == :call
    if point.defined_class == T::CoordinationService
      service = point.self
      cleanup = true if point.method_id == :cleanup_boundary && provider.receipt
    end
    journal = point.self if point.defined_class == T::CoordinationJournal
    if (armed || cleanup) && [T::LocalFixedTeamCoordinationPort, T::LocalFixedTeamReadinessPort].include?(point.defined_class) && %i[store reserve create_bind].include?(point.method_id)
      mutations_after << point.method_id
    end
  end
  outcome = catch(:boundary_ft2) do
    actor_backend(context, players.first, owner_reader: reader) do |backend, authority, directory, session|
      window = record['evidence']['plan']['matches'].first['windows'].first
      facade = T::LocalFixedTeamExecution.new(plan_backend: backend, plan_directory: directory,
        source_identity: context.provider.backend_identity, context: authority, registry: REGISTRY,
        clock: -> { window['opens'] + 1 }, policy_ref: 'jawna-polityka-proby-ft2a', expires_at: window['closes'] - 1)
      facade.native_provider = provider
      select_match(facade, record)
      provider.callback = -> do
        session.close if mode == :close_context
        if mode.to_s.start_with?('postguard')
          armed = true
          raise primary, cause: cause
        end
      end
      begin
        trace.enable(target_thread: nil)
        begin
          raise ArgumentError, 'Obsłużony ambient rescue'
        rescue ArgumentError
          result = facade.request_match
        end
      rescue Exception => error
        caught = error
      ensure
        trace.disable
      end
    end
    :normalny
  end
  path = File.join(context.directory, 'plany', 'fixed-teams-v1', 'execution-ft2-v1', 'state.json')
  state = JSON.parse(File.binread(path))
  locks = Dir.glob(File.join(File.dirname(path), '**', '*.lock')).to_h do |name|
    File.open(name, File::RDWR) { |f| [name, !!f.flock(File::LOCK_EX | File::LOCK_NB)] }
  end
  row = {mode: mode, result: result && result.merge(target: result[:target]&.to_h, binding: result[:binding]&.to_h), outcome: outcome,
    error: caught && {class: caught.class.name, same: caught.equal?(primary), cause: caught.cause&.class&.name,
      exact_cause: caught.cause.equal?(cause), backtrace: caught.backtrace}, state: state, locks: locks,
    journal_held: journal.instance_variable_get(:@held), journal_mutex: journal.instance_variable_get(:@mutex).locked?,
    service_mutex: service.instance_variable_get(:@mutex).locked?, mutations_after: mutations_after}
  results << row
  oracle_file("boundary-#{index}.json", row)
  assert(locks.values.all? && !row[:journal_held] && !row[:journal_mutex] && !row[:service_mutex], 'Zwolnienie własności po każdym wyniku')
  assert_equal([], mutations_after)
  assert_equal(1, state['native']['creates'].size)
  if mode == :healthy_ambient
    assert_equal(:bound, result[:state]); assert_equal(nil, caught)
  elsif mode.to_s.start_with?('postguard')
    assert(caught.equal?(primary) && caught.cause.equal?(cause), 'Exact błąd i przyczyna przez postguard')
    assert_equal(['pierwotne-io.rb:21'], caught.backtrace)
  elsif mode == :close_context
    assert_equal(:blocked, result[:state]); assert_equal(nil, caught)
  elsif mode == :cleanup_throw
    assert_equal(:nielokalny, outcome); assert_equal(nil, caught)
  else
    assert(caught.instance_of?(BoundarySecondaryFT2), 'Brak własnego primary nie ukrywa awarii cleanup')
  end
end
oracle_file('boundaries.json', results)
puts 'GREEN: zdrowe I/O pod ambient rescue, postguard i cleanup oraz zamknięcie rzeczywistego kontekstu'
