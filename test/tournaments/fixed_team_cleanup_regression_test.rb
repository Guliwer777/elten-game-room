# encoding: UTF-8
require_relative '../support/tournament_fixed_team_execution'
require_relative '../support/tournament_fixed_team_native_service'
require_relative '../../lib/tournaments/local_fixed_team_execution'
include TournamentFixedTeamExecutionSupport

class PrimaryCleanupFT2 < IOError; end
class SecondaryCleanupFT2 < Exception; end
class CleanupProviderFT2 < TournamentFixedTeamNativeService
  attr_accessor :on_commit
  attr_reader :receipt
  def committed(receipt:)
    @receipt = receipt
    on_commit.call if on_commit
  end
end

results = []
# Każda odmiana przechodzi publiczną request_match i prawdziwy dziennik.
[:commit, :write].product([false, true], [:pre_throw, :post_throw, :exception]).each_with_index do |(phase, has_cause, secondary), index|
  context, record = execution_fixture(File.basename(ENV.fetch('ENTRY_EVIDENCE')) + "-#{index}")
  players = record['evidence']['plan']['matches'].first['players'].map { |p| p['username'] }
  players.each do |actor|
    execution_for(context, record, actor) do |facade|
      select_match(facade, record)
      assert_equal(:confirmed, facade.declare(availability: 'ready', expected_revision: 0)[:state])
    end
  end
  cause = has_cause ? ArgumentError.new('Pierwotna przyczyna') : nil
  primary = PrimaryCleanupFT2.new("Kontrolowany błąd #{phase}")
  backtrace = ["pierwotny-#{index}.rb:17:in 'zapis'"]
  state = {cleanup: false, calls: 0, fire: false, failed: false}
  provider = CleanupProviderFT2.new
  provider.on_commit = -> { state[:failed] = true; primary.set_backtrace(backtrace); raise primary, cause: cause } if phase == :commit
  reader = -> do
    if state[:fire]
      state[:fire] = false
      state[:failed] = true
      primary.set_backtrace(backtrace); raise primary, cause: cause
    end
    if state[:cleanup]
      state[:calls] += 1
      throw :cleanup_regression, :utrata_primary if secondary == :pre_throw || (secondary == :post_throw && state[:calls] > 1)
      raise SecondaryCleanupFT2, 'Wtórny błąd czytnika' if secondary == :exception
    end
    'WlascicielPlikow'
  end
  caught = nil
  journal = service = temporary = nil
  mutations_after = []
  trace = TracePoint.new(:call, :line) do |point|
    if point.defined_class == T::CoordinationJournal
      journal = point.self
      if phase == :write && point.method_id == :write && point.event == :line && !state[:failed]
        file = point.binding.local_variable_get(:file) if point.binding.local_variable_defined?(:file)
        if file && !file.closed?
          temporary = file
          state[:fire] = true
        end
      end
    end
    service = point.self if point.defined_class == T::CoordinationService
    if point.defined_class == T::CoordinationService && point.method_id == :cleanup_boundary && point.event == :call && state[:failed]
      state[:cleanup] = true
    end
    if point.event == :call && state[:cleanup] && [T::LocalFixedTeamReadinessPort, T::LocalFixedTeamCoordinationPort].include?(point.defined_class) && [:store, :reserve, :create_bind].include?(point.method_id)
      mutations_after << point.method_id
    end
  end
  outcome = catch(:cleanup_regression) do
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
      rescue Exception => error
        caught = error
      ensure
        trace.disable
      end
    end
    :normalny_powrot
  end
  root = File.join(context.directory, 'plany', 'fixed-teams-v1', 'execution-ft2-v1')
  probes = Dir.glob(File.join(root, '**', '*.lock')).to_h do |path|
    File.open(path, File::RDWR) { |file| [path, !!file.flock(File::LOCK_EX | File::LOCK_NB)] }
  end
  disk = JSON.parse(File.binread(File.join(root, 'state.json')))
  row = {phase: phase, has_cause: has_cause, secondary: secondary, outcome: outcome,
    same_primary: caught.equal?(primary), same_cause: caught && caught.cause.equal?(cause),
    backtrace: caught&.backtrace, expected_backtrace: backtrace, probes: probes,
    temp_path: temporary&.path, temp_closed: temporary&.closed?, journal_held: journal.instance_variable_get(:@held),
    journal_mutex: journal.instance_variable_get(:@mutex).locked?, service_mutex: service.instance_variable_get(:@mutex).locked?,
    mutations_after: mutations_after, receipt: provider.receipt, state: disk}
  results << row
  oracle_file("cleanup-regression-#{index}.json", row)
end
oracle_file('cleanup-regressions.json', results)
results.each do |row|
  assert(row[:same_primary] && row[:same_cause] && row[:backtrace] == row[:expected_backtrace], 'RED_FT2A_CLEANUP: utracono exact primary/cause/backtrace')
  assert(row[:probes].values.all?, 'RED_FT2A_CLEANUP: własny lock nie został zwolniony')
  assert(!row[:journal_held] && !row[:journal_mutex] && !row[:service_mutex], 'Własność i mutex zawsze zwolnione')
  assert(row[:temp_closed], 'RED_FT2A_CLEANUP: temp pozostał otwarty') if row[:phase] == :write
  assert_equal([], row[:mutations_after])
  assert_equal(row[:phase] == :commit ? 1 : 0, row[:state]['native']['creates'].size)
end
puts 'GREEN: exact primary/cause/backtrace, własne lock/temp oraz zero kolejnych mutacji portu'
