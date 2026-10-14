# encoding: UTF-8
require_relative '../support/tournament_ft2b1_native_support'
require 'weakref'
include GameRoomTest::Assertions
T=GameRoomTournaments
def native_callback_probe(endpoint)
  payload=Object.new
  handle=endpoint.on_error { |_error| payload }
  [handle,WeakRef.new(payload)]
end
transaction=T::LocalFixedTeamNativeProvider.new.open(state: {'creates'=>[],'cores'=>[]},owner: 'Ala')
endpoint=transaction.program.live_sessions
handle,reference=native_callback_probe(endpoint)
3.times { GC.start(full_mark: true,immediate_sweep: true) }
assert_equal(true,!!reference.weakref_alive?,'Aktywny callback musi zachować swój payload')
transaction.close
3.times { GC.start(full_mark: true,immediate_sweep: true) }
assert_equal(false,!!reference.weakref_alive?,'Zamknięty uchwyt utrzymuje closure')
assert_equal(nil,handle.call(IOError.new('Spóźniony błąd')))
assert_equal(nil,handle.callback)
assert_equal([],endpoint.instance_variable_get(:@callbacks))
puts 'PASS aktywny callback zachowuje payload, zamknięty zwalnia closure mimo zachowanego uchwytu'
