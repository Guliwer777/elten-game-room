# encoding: UTF-8
require_relative '../support/tournament_ft2b1_ui_probe'
include GameRoomTest::Assertions
def self.assert(value, message = 'Asercja częściowego connection U'); super(value, message); end
U = TournamentFT2B1UI
F = U::F
T = F::T
fixture = F.fixture(File.join(ENV.fetch('FT2_SCRATCH'), 'shared', File.basename(ENV.fetch('ENTRY_EVIDENCE'))))
results = []
begin
  [:exception, :throw].each do |mode|
    session = T::LocalReadinessSession.new
    session.choose_actor('Ala')
    entry = T::EntryContext.new(program: fixture[:program], runtime: fixture[:program].class.app_runtime,
      owner_reader: -> { F::OWNER }, account_events: session.actor_events)
    workspace = T::LocalWorkspace.new(**F.args(fixture).reject { |k, _| k == :confirm }, actor: 'Ala')
    primary = NoMethodError.new('Pierwotna konstrukcja backendu')
    primary.set_backtrace(['connection_u.rb:18'])
    cause = ArgumentError.new('Przyczyna backendu')
    secondary = Exception.new('Wtórny cleanup connection')
    original = T::LocalFixedTeamPlanBackend.method(:new)
    context_method = session.method(:context)
    reached = 0
    session.define_singleton_method(:context) do |**options|
      value = context_method.call(**options)
      close = value.method(:close)
      value.define_singleton_method(:close) do |**args|
        close.call(**args)
        reached += 1
        mode == :throw ? (throw :u_connection_cleanup, :swallowed) : (raise secondary, cause: nil)
      end
      value
    end
    T::LocalFixedTeamPlanBackend.define_singleton_method(:new) { |**_| raise primary, cause: cause }
    observed = nil
    begin
      catch(:u_connection_cleanup) do
        begin
          workspace.fixed_team_connection(context: entry, lease: entry.capture, session: session)
        rescue Exception => error
          observed = error
        end
      end
      assert(observed.equal?(primary), 'Connection zgubił primary przy wtórnym cleanup')
      assert(observed.cause.equal?(cause))
      assert_equal(['connection_u.rb:18'], observed.backtrace)
      assert_equal(1, reached)
      results << {mode: mode, backtrace: observed.backtrace, reached: reached}
    ensure
      T::LocalFixedTeamPlanBackend.define_singleton_method(:new, original)
      entry.close; session.close
    end
    assert_equal([0, 0], [fixture[:program].managed_resources.size, fixture[:program].class.app_runtime.managed_resources.size])
    assert_equal([0, 0], [session.actor_events.listener_count, session.backend_events.listener_count])
  end
  U.evidence('connection-construction', results)
  puts 'PASS częściowe connection: prawdziwy cleanup Authority/Registry, primary/cause/backtrace przy wtórnym Exception oraz throw'
ensure
  fixture[:program].finalize; fixture[:program].class.app_runtime.close
end
