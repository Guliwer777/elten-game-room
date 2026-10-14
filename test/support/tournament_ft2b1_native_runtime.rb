# encoding: UTF-8
require_relative 'tournament_ft2b1_native_support'
require EltenTestHost.file('src/eapi/program.rb')
module Log
  def self.debug(_value); end
  def self.error(_value); end
end
module TournamentFT2B1NativeRuntime
  module_function
  def fixture
    runtime=Programs::Runtime.allocate
    runtime.instance_variable_set(:@manifest,Struct.new(:id,:namespace_name).new('ft2b1-native-lifecycle','FT2B1NativeLifecycle'))
    runtime.instance_variable_set(:@entry_id,'ft2b1-native-lifecycle')
    runtime.instance_variable_set(:@root,File.join(ENV.fetch('FT2_SCRATCH'),'native-runtime'))
    backend=Programs::Execution::RuntimeBackend.new(runtime)
    runtime.instance_variable_set(:@execution,backend)
    runtime.instance_variable_set(:@namespace,backend.namespace)
    Programs.register_runtime(runtime)
    Program.instance_variable_set(:@app_runtime,runtime)
    program=Program.allocate
    transaction=GameRoomTournaments::LocalFixedTeamNativeProvider.new.open(state: {'creates'=>[],'cores'=>[]},owner: 'Ala')
    endpoint=transaction.program.live_sessions
    program.define_singleton_method(:live_sessions) { endpoint }
    transport=Programs.with_runtime(runtime) { GameRoomTransport.new(program,**transaction.transport_options) }
    [runtime,program,transaction,transport]
  end
end
