# encoding: UTF-8
require_relative 'tournament_ft2b1_native_fixture'
require_relative 'tournament_ft2b1_execution'
module TournamentFT2B1Native
  extend GameRoomTest::Assertions
  F = TournamentFT2B1
  T = GameRoomTournaments
  module_function
  def bytes(directory)
    Dir.glob(File.join(directory, '**', '*')).select { |p| File.file?(p) && !p.end_with?('.lock') }.to_h { |p| [p, File.binread(p)] }
  end
  def fixture(name, template: [0, 1, 0, 1])
    TournamentFT2B1NativeFixture.fixture(File.join(ENV.fetch('FT2_SCRATCH'), 'shared', File.basename(ENV.fetch('ENTRY_EVIDENCE')), name), template: template)
  end
  def ready(fixture, index)
    match = fixture[:record]['evidence']['plan']['matches'].fetch(index)
    match['players'].each do |person|
      F.with_execution(fixture, person['username']) do |execution|
        F.select_execution(execution, fixture[:record], index)
        assert_equal(:confirmed, execution.declare(availability: 'ready', expected_revision: 0)[:state])
      end
    end
  end
  def execute(fixture, index = 0, provider: :production)
    match = fixture[:record]['evidence']['plan']['matches'].fetch(index)
    F.with_execution(fixture, match['players'].first['username'], provider: provider, expires_at: match['windows'].first['closes'] - 60) do |execution|
      F.select_execution(execution, fixture[:record], index)
      yield execution
    end
  end
  def observed
    calls=[]
    trace=TracePoint.new(:call) do |event|
      if [T::LocalFixedTeamCoordinationPort, T::LocalFixedTeamNativeEndpoint, GameRoomTransport].include?(event.defined_class) &&
          [:reserve, :create_bind, :create, :create_room].include?(event.method_id)
        calls << [event.defined_class.to_s, event.method_id]
      end
    end
    trace.enable(target_thread: nil)
    value=yield
    [value,calls]
  ensure
    trace&.disable
  end
  def close(fixture)
    fixture[:program].finalize
    fixture[:program].class.app_runtime.close
  end
  class Provider < T::LocalFixedTeamNativeProvider
    attr_accessor :advertised_limits, :version
    attr_reader :opens
    def initialize
      @advertised_limits=super_limits
      @version=1
      @opens=0
    end
    def super_limits; T::LocalFixedTeamNativeProvider.instance_method(:limits).bind_call(self); end
    def limits; @advertised_limits; end
    def local_transaction_version; @version; end
    def open(**args); @opens+=1; super; end
  end
end
