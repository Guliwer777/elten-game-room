# encoding: UTF-8
require_relative '../support/tournament_ft2b1_native_runtime'
require 'weakref'
include GameRoomTest::Assertions
T=GameRoomTournaments
runtime,program,transaction,transport=TournamentFT2B1NativeRuntime.fixture
arguments={name: 'FT2A',game: 'spades',owner: 'Ala',game_options: '{}',private_table: true,capacity: 4,bot_count: 0}
begin
  table=transport.create_room(**arguments)
  endpoint=transaction.program.live_sessions
  view=endpoint.sessions.first
  before=transaction.dump
  # FT2B-1 nie dostarcza zaproszeń ani Start; zwykły transport nie może ich dopisać.
  %i[join invite start_game].each { |name| assert_equal(false,endpoint.respond_to?(name)) }
  %w[game_started room_updated member_joined invitation].each do |kind|
    failure=nil
    begin
      view.stack_push({'version'=>2,'kind'=>kind,'actor'=>'Ala','data'=>{}},message_id: kind)
    rescue T::CoordinationContract::Blocked => error
      failure=error.code
    end
    assert_equal(:local_create_only,failure,kind)
    assert_equal(before,transaction.dump)
  end
  callbacks=endpoint.instance_variable_get(:@callbacks).dup
  assert_equal(true,callbacks.size.positive?)
  started=Queue.new
  continue=Queue.new
  outcome=Queue.new
  work=Programs.with_runtime(runtime) { GameRoomBackground::Work.new(runtime: runtime) }
  program.manage(transaction)
  program.manage(work)
  work.start do
    started << true
    continue.pop
    begin
      view.stack_push(before['cores'].first['entries'].first['packet'],message_id: 'late-worker')
    rescue T::CoordinationContract::Blocked => error
      outcome << error.code
    end
  end
  Timeout.timeout(3) { started.pop }
  # Rzeczywisty Program kończy tylko własne zasoby, bez GUI (reason:error).
  program.finalize(reason: :error)
  transport.close_local_view
  continue << true
  wait_background_work(work)
  assert_equal(:local_view_closed,Timeout.timeout(3) { outcome.pop })
  assert_equal([],endpoint.instance_variable_get(:@callbacks))
  assert_equal(nil,endpoint.instance_variable_get(:@state))
  assert_equal(true,view.closed?)
  invitation=Struct.new(:metadata,:invitation_metadata).new(before['cores'].first['metadata'],{'purpose'=>'game_invitation','invitation_id'=>123})
  callbacks.first.call(invitation)
  callbacks.last.call(IOError.new('Spóźniony callback'))
  store=transport.instance_variable_get(:@live_store)
  assert_equal({},store.instance_variable_get(:@pending_invitations),'Spóźniony callback zapisuje zaproszenie po close')
  assert_equal({},before['cores'].first['invitations'])
  assert_equal(false,before['cores'].first['closed'])
  assert_equal(1,before['cores'].first['entries'].size)
  runtime.close_managed_resources
  assert_equal(0,runtime.managed_resources.size)
  assert_equal(0,program.managed_resources.size)
  assert_equal(table['__live_session_id'],before['cores'].first['id'])
  puts 'PASS Program/Runtime/realny worker/callback po close; brak zaproszeń/start i zmian trwałego core'
ensure
  continue << true if continue
  transaction.close
  runtime.close_managed_resources
  Programs.unregister_runtime(runtime)
end
