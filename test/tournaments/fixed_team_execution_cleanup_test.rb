# encoding: UTF-8
require_relative '../support/tournament_fixed_team_execution'
require_relative '../support/tournament_fixed_team_native_service'
require_relative '../../lib/tournaments/local_fixed_team_execution'
include TournamentFixedTeamExecutionSupport
class AwariaPoCommitFT2A < TournamentFixedTeamNativeService
  attr_reader :primary, :receipt
  def initialize
    @primary = IOError.new('Pierwotna kontrolowana awaria odpowiedzi FT2A')
  end
  def committed(receipt:)
    @receipt = receipt
    raise @primary, cause: nil
  end
end
context, record = execution_fixture(File.basename(ENV.fetch('ENTRY_EVIDENCE')))
players = record['evidence']['plan']['matches'].first['players'].map { |person| person['username'] }
players.each do |actor|
  execution_for(context, record, actor) do |facade|
    select_match(facade, record)
    assert_equal(:confirmed, facade.declare(availability: 'ready', expected_revision: 0)[:state])
  end
end
provider = AwariaPoCommitFT2A.new
cleanup = false
visited = []
trace = TracePoint.new(:call) do |point|
  if point.defined_class == T::CoordinationService && point.method_id == :cleanup_boundary && provider.receipt
    cleanup = true
    visited << {path: point.path, line: point.lineno, method: point.method_id}
  end
end
reader = -> do
  throw :wyjscie_cleanup_ft2a, :utracony_primary if cleanup
  'WlascicielPlikow'
end
caught = nil
outcome = catch(:wyjscie_cleanup_ft2a) do
  actor_backend(context, players.first, owner_reader: reader) do |backend, authority, directory|
    window = record['evidence']['plan']['matches'].first['windows'].first
    facade = T::LocalFixedTeamExecution.new(plan_backend: backend, plan_directory: directory,
      source_identity: context.provider.backend_identity, context: authority, registry: REGISTRY,
      clock: -> { window['opens'] + 1 }, policy_ref: 'jawna-polityka-proby-ft2a', expires_at: window['closes'] - 1)
    facade.native_provider = provider
    select_match(facade, record)
    begin
      trace.enable(target_thread: nil)
      facade.request_match
    rescue IOError => error
      caught = error
    ensure
      trace.disable
    end
  end
  :normalny_powrot
end
root = File.join(context.directory, 'plany', 'fixed-teams-v1', 'execution-ft2-v1')
state = JSON.parse(File.binread(File.join(root, 'state.json')))
assert_equal(1, state['native']['creates'].size, 'Potwierdzony efekt natywny PRZED sprzątaniem')
locks = ObjectSpace.each_object(File).select { |file| !file.closed? && file.path.start_with?(root) && file.path.end_with?('.lock') }
probe = locks.map do |file|
  File.open(file.path, File::RDWR) do |other|
    acquired = other.flock(File::LOCK_EX | File::LOCK_NB)
    {'path' => file.path, 'locked_after_attempt' => !acquired}
  end
end
oracle_file('readonly-cleanup-blocker.json', {outcome: outcome, caught_same_primary: caught.equal?(provider.primary),
  primary: {class: provider.primary.class.name, message: provider.primary.message, cause: provider.primary.cause,
    backtrace: provider.primary.backtrace}, visited: visited, locks: probe, receipt: provider.receipt, state: state})
assert(caught.equal?(provider.primary), 'RED_FT2A_READONLY: CoordinationService cleanup zastąpił pierwotny błąd po commit przez throw')
assert_equal([], probe.select { |item| item['locked_after_attempt'] }, 'Własna blokada dziennika musi być zwolniona po każdej próbie')
puts 'GREEN: pierwotny błąd i zwolnienie własnej blokady po nielokalnym cleanup'
