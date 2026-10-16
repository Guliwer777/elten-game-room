# encoding: UTF-8
require_relative '../support/tournament_ft2b1_native_runtime'
include GameRoomTest::Assertions
[:exception,:throw].each do |mode|
  runtime,program,transaction,transport=TournamentFT2B1NativeRuntime.fixture
  begin
    store=transport.instance_variable_get(:@live_store)
    work=store.instance_variable_get(:@discovery_work)
    original=work.method(:close)
    primary=Exception.new('Awaria cleanup Work')
    work.define_singleton_method(:close) do
      original.call
      mode==:exception ? (raise primary) : (throw :cleanup,:escaped)
    end
    observed=nil
    result=catch(:cleanup) do
      begin
        transport.close_local_view
      rescue Exception => error
        observed=error
      end
      :returned
    end
    assert_equal(mode==:exception ? primary : nil,observed)
    assert_equal(mode==:exception ? :returned : :escaped,result)
    assert_equal(0,runtime.managed_resources.size,'Wtórny cleanup zatrzymał release Programu')
    assert_equal(nil,store.instance_variable_get(:@changed),'Pozostawiono callback zamkniętego Store')
    assert_equal(nil,store.instance_variable_get(:@presence_changed))
  ensure
    transaction.close
    runtime.close_managed_resources
    program.finalize(reason: :error)
    Programs.unregister_runtime(runtime)
  end
end
puts 'PASS close Work Exception/throw nie pomija release i wyzerowania callbacków'
