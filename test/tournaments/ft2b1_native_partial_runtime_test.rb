# encoding: UTF-8
require_relative '../support/tournament_ft2b1_native_runtime'
include GameRoomTest::Assertions
T=GameRoomTournaments
[:exception,:throw].each do |mode|
  runtime=Programs::Runtime.allocate
  runtime.instance_variable_set(:@manifest,Struct.new(:id).new('ft2b1-partial-runtime'))
  Program.instance_variable_set(:@app_runtime,runtime)
  program=Program.allocate
  primary=Exception.new('Awaria po Runtime.manage')
  original=runtime.method(:manage)
  acquired=nil
  runtime.define_singleton_method(:manage) do |resource,**args|
    acquired=resource
    original.call(resource,**args)
    mode==:exception ? (raise primary) : (throw :cleanup,:escaped)
  end
  observed=nil
  result=catch(:cleanup) do
    begin
      Programs.with_runtime(runtime) { GameRoomTransport.new(program,clock: T::LocalFixedTeamNativeProvider::Clock.new,local_view: true) }
    rescue Exception => error
      observed=error
    end
    :returned
  end
  assert_equal(mode==:exception ? primary : nil,observed)
  assert_equal(mode==:exception ? :returned : :escaped,result)
  assert_equal(GameRoomBackground::Work,acquired.class)
  assert_equal(true,acquired.closed?)
  assert_equal(0,runtime.managed_resources.size)
  runtime.close_managed_resources
  program.finalize(reason: :error)
end
puts 'PASS pierwszy Runtime.manage: Exception/throw po przejęciu zasobu nie zostawiają częściowego Work'
