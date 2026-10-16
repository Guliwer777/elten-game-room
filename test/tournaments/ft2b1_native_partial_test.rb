# encoding: UTF-8
require_relative '../support/tournament_ft2b1_native_support'
require EltenTestHost.file('src/eapi/program.rb')
module Log
  def self.debug(_value); end
  def self.error(_value); end
end
include GameRoomTest::Assertions
T=GameRoomTournaments
FT2B1NativeProgram = Program
runtime=Programs::Runtime.allocate
runtime.instance_variable_set(:@manifest,Struct.new(:id).new('ft2b1-native-resources'))
FT2B1NativeProgram.instance_variable_set(:@app_runtime,runtime)
program=FT2B1NativeProgram.allocate
transaction=T::LocalFixedTeamNativeProvider.new.open(state: {'creates'=>[],'cores'=>[]},owner: 'Ala')
endpoint=transaction.program.live_sessions
program.define_singleton_method(:live_sessions) { endpoint }
original=FT2B1NativeProgram.method(:manage)
primary=RuntimeError.new('Awaria po rzeczywistym przejęciu Work')
FT2B1NativeProgram.define_singleton_method(:manage) do |resource,**args|
  original.call(resource,**args)
  raise primary
end
begin
  observed=nil
  begin
    Programs.with_runtime(runtime) { GameRoomTransport.new(program,clock: T::LocalFixedTeamNativeProvider::Clock.new,local_view: true) }
  rescue Exception => error
    observed=error
  end
  assert_equal(primary.object_id,observed&.object_id)
  assert_equal(0,runtime.managed_resources.size,'Częściowa konstrukcja pozostawia rzeczywisty Work w Runtime')
  puts 'PASS częściowe przejęcie Program.manage zwalnia Work i zachowuje primary'
ensure
  transaction.close
  runtime.close_managed_resources
  program.finalize(reason: :error)
end
