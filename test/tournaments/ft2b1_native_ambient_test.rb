# encoding: UTF-8
require_relative '../support/tournament_ft2b1_native_support'
include GameRoomTest::Assertions
N=TournamentFT2B1Native
T=N::T
fixture=N.fixture('primary')
begin
  N.execute(fixture) do |execution|
    native=execution.selection[:native]
    request=execution.selection[:request].to_h
    [nil,RuntimeError.new('Bezpośrednia przyczyna')].each do |cause|
      [:exception,:throw].each do |cleanup|
        provider=N::Provider.new
        open=provider.method(:open)
        primary=begin; raise IOError.new('Awaria dump'), cause: cause; rescue IOError => e; e; end
        backtrace=primary.backtrace.dup
        current=nil
        provider.define_singleton_method(:open) do |**args|
          current=open.call(**args)
          current.define_singleton_method(:dump) { raise primary, cause: primary.cause }
          close=current.method(:close)
          current.define_singleton_method(:close) do
            close.call
            cleanup==:exception ? (raise Exception,'Wtórny close') : (throw :cleanup,:escaped)
          end
          current
        end
        adapter=T::FixedTeamNativeTargetAdapter.new(provider: provider,registry: N::F::REGISTRY)
        observed=nil
        begin
          raise 'Wcześniej obsłużony ambient'
        rescue RuntimeError
          catch(:cleanup) do
            begin
              adapter.create(state: {'creates'=>[],'cores'=>[]},native: native,request: request,actor: request['players'].first['account'])
            rescue Exception => error
              observed=error
            end
          end
        end
        assert_equal(primary.object_id,observed&.object_id)
        assert_equal(cause,observed.cause)
        assert_equal(backtrace,observed.backtrace)
        assert_equal(true,current.program.live_sessions.closed?)
      end
    end
    # W zdrowym wywołaniu nie wolno wskrzesić ambient $!.
    begin
      raise 'Obsłużony ambient bez primary'
    rescue RuntimeError
      adapter=T::FixedTeamNativeTargetAdapter.new(provider: T::LocalFixedTeamNativeProvider.new,registry: N::F::REGISTRY)
      readback,state=adapter.create(state: {'creates'=>[],'cores'=>[]},native: native,request: request,actor: request['players'].first['account'])
      assert_equal('private',readback['visibility'])
      assert_equal(1,state['creates'].size)
    end
  end
  puts 'PASS native primary nil/cause, Exception/throw i ambient rescue; zdrowy ambient nie wraca jako błąd'
ensure
  N.close(fixture)
end
