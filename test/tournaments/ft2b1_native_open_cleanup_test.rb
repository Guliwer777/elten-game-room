# encoding: UTF-8
require_relative '../support/tournament_ft2b1_native_support'
include GameRoomTest::Assertions
T=GameRoomTournaments
factory=T::LocalFixedTeamNativeProvider::Transaction::Program
original=factory.method(:new)
primary=RuntimeError.new('Awaria budowy uchwytu Program')
factory.define_singleton_method(:new) { |*_| raise primary }
created=nil
observer=TracePoint.new(:return) do |event|
  created=event.self if event.defined_class==T::LocalFixedTeamNativeEndpoint && event.method_id==:initialize
end
observer.enable(target_thread: nil)
begin
  failure=nil
  begin
    T::LocalFixedTeamNativeProvider.new.open(state: {'creates'=>[],'cores'=>[]},owner: 'Ala')
  rescue Exception => error
    failure=error
  end
  assert_equal(primary.object_id,failure&.object_id)
  assert_equal(T::LocalFixedTeamNativeEndpoint,created.class)
  assert_equal(true,created.closed?,'Nie zwolniono endpointu po nieudanym open')
  assert_equal(nil,created.instance_variable_get(:@state))
  puts 'PASS częściowe open zamyka pierwszy endpoint i zachowuje primary'
ensure
  observer.disable
  factory.define_singleton_method(:new,original)
  created&.close_view
end
