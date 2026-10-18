require_relative '../support/tournament_individual_execution'
include TournamentIndividualExecutionSupport

with_fixture(game:'tic_tac_toe',names:%w[Alpha Beta]) do |fixture|
  accepted=start_individual_match(fixture)
  with_individual_execution(fixture,accepted,'Alpha') do |execution|
    vault=execution.private_choices
    id=vault.session_id
    trace=T::PrivateActionTrace.new(vault)
    old=trace.prepare(session_id:id,round_id:'confirmed',user:'Alpha',payload:{'value'=>'old local choice'})
    newest=vault.prepare(session_id:id,round_id:'confirmed',user:'Alpha',payload:{'value'=>'new uncertain choice'})
    assert_equal(old,trace.reveal(session_id:id,round_id:'confirmed',user:'Alpha',commitment:old.commitment))
    assert_equal(false,trace.discard(session_id:id,round_id:'confirmed',user:'Alpha'))
    calls=Marshal.load(Marshal.dump(trace.calls))
    snapshot=-> { Dir.glob(File.join(fixture.directory,'**','*.json')).sort.to_h { |path| [path,File.binread(path)] } }
    before=snapshot.call
    target={session_id:id,receipts:[['confirmed','alpha',old.commitment]]}
    target_copy=Marshal.load(Marshal.dump(target))
    # Maintenance is the actual shared cleanup hook, not an action planner.
    state={}
    HiddenSubmissions::Cleanup.start(state,'__id'=>id)
    HiddenSubmissions::Cleanup.confirm(state,'confirmed','Alpha'=>old.commitment)
    model=GameRoomGames::Replay.new(state:state)
    cleaner=Object.new.extend(HiddenSubmissions::Cleanup)
    3.times { cleaner.cleanup_session_answers(model,session_id:id,actors:['Alpha'],hidden_submissions:trace) }
    assert_equal(false,trace.discard_confirmed(**target))
    assert_equal(false,trace.discard_confirmed(session_id:id+1,receipts:[['confirmed','Beta',newest.commitment]]))
    assert_equal(target_copy,target,'Cleanup changed its supplied receipt')
    assert_equal(calls,trace.calls,'Cleanup entered the recorded private action trace')
    assert_equal(before,snapshot.call,'Local archive or public execution bytes changed')
    cold=execution.private_choices
    assert_equal(old,cold.reveal(session_id:id,round_id:'confirmed',user:'Alpha',commitment:old.commitment))
    assert_equal(newest,cold.reveal(session_id:id,round_id:'confirmed',user:'Alpha'))

    storage=vault.instance_variable_get(:@vault).instance_variable_get(:@storage)
    readonly=T::LocalPrivateChoices::ReadOnlyVault.new(storage.read,actor:'alpha',session_id:id)
    replay=T::PrivateActionTrace.new(readonly,calls:calls)
    3.times { cleaner.cleanup_session_answers(model,session_id:id,actors:['Alpha'],hidden_submissions:replay) }
    assert(!replay.consumed?,'Maintenance consumed an action input before replay')
    assert_equal(old,replay.prepare(session_id:id,round_id:'confirmed',user:'Alpha',payload:{'value'=>'old local choice'}))
    assert_equal(false,replay.discard_confirmed(**target))
    assert_equal(old,replay.reveal(session_id:id,round_id:'confirmed',user:'Alpha',commitment:old.commitment))
    assert_equal(false,replay.discard(session_id:id,round_id:'confirmed',user:'Alpha'))
    assert(replay.consumed?,'Original action trace did not consume exactly its calls')
    assert_equal([],replay.calls,'Read-only replay recorded additional calls')
    assert_raises(HiddenSubmissions::StorageError) { replay.reveal(session_id:id,round_id:'confirmed',user:'Alpha') }
    assert_raises(HiddenSubmissions::StorageError) { readonly.reveal(session_id:id,round_id:'confirmed',user:'Beta') }
    assert_equal(before,snapshot.call,'Read-only replay changed archive or public receipts')
  end
end
puts 'PASS independent local adapter: original/current cold envelopes retained; shared cleanup makes no writes, records or consumed inputs; exact historical calls and scope refusal preserved'
