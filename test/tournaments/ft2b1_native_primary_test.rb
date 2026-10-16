# encoding: UTF-8
require_relative '../support/tournament_ft2b1_execution'
require EltenTestHost.file('src/eapi/server_clock.rb')
include GameRoomTest::Assertions
T = GameRoomTournaments
class FT2B1NativeFaultProvider < T::LocalFixedTeamNativeProvider
  attr_reader :transaction, :views
  def initialize(primary, secondary)
    @primary, @secondary, @views = primary, secondary, []
  end
  def open(**args)
    @transaction = super
    endpoint = @transaction.program.live_sessions
    primary, secondary, views = @primary, @secondary, @views
    original = endpoint.method(:create)
    endpoint.define_singleton_method(:create) do |**input|
      view = original.call(**input)
      views << view
      view.define_singleton_method(:stack_push) { |*_, **_| raise primary, cause: primary.cause }
      close = view.method(:close)
      view.define_singleton_method(:close) do
        close.call
        secondary.call
      end
      view
    end
    @transaction
  end
end
fixture = TournamentFT2B1.fixture(File.join(ENV.fetch('FT2_SCRATCH'), 'shared', File.basename(ENV.fetch('ENTRY_EVIDENCE'))))
begin
  TournamentFT2B1.with_execution(fixture, 'Ala') do |execution|
    TournamentFT2B1.select_execution(execution, fixture[:record])
    native, request = execution.selection.values_at(:native, :request)
    [:fatal, :throw].each do |mode|
      cause = RuntimeError.new('Przyczyna pierwotna')
      primary = begin; raise IOError.new('Pierwotny błąd stack'), cause: cause; rescue IOError => e; e; end
      original_trace = primary.backtrace.dup
      secondary = -> { mode == :fatal ? (raise Exception, 'Wtórny cleanup') : (throw :cleanup, :escaped) }
      provider = FT2B1NativeFaultProvider.new(primary, secondary)
      adapter = T::FixedTeamNativeTargetAdapter.new(provider: provider, registry: TournamentFT2B1::REGISTRY)
      observed = nil
      outcome = catch(:cleanup) do
        begin
          adapter.create(state: {'creates' => [], 'cores' => []}, native: native, request: request.to_h, actor: 'ala')
        rescue Exception => error
          observed = error
        end
        :returned
      end
      assert_equal(primary.object_id, observed&.object_id, "Utrata primary przy #{mode}: #{observed.inspect}, #{outcome}")
      assert_equal(cause.object_id, observed.cause.object_id)
      assert_equal(original_trace, observed.backtrace)
      assert_equal(true, provider.transaction.program.live_sessions.closed?)
      assert_equal(true, provider.views.all?(&:closed?))
    end
  end
  puts 'PASS primary/cause/backtrace po awarii stack i wtórnym Exception/throw cleanup'
ensure
  fixture[:program].finalize
  fixture[:program].class.app_runtime.close
end
