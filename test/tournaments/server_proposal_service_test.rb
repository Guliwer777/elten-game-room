require 'tmpdir'
require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/native_room_harness'
require_relative '../support/readiness_plan_table'
require_relative '../../lib/tournaments/server_proposal_service'
include GameRoomTest::Assertions
T=GameRoomTournaments
Dir.mktmpdir('pilot-proposal-',ENV.fetch('TMPDIR')) do |directory|
  actor,now='Alice',Time.utc(2026,10,13,12).to_i
  table=ReadinessPlanTableSupport::Table.new(user:-> {actor},clock:-> {now})
  candidate={'publication_ref'=>{'author'=>'alice','publication_key'=>'fixture'},'schedule_id'=>'a'*64,
    'publication_digest'=>'b'*64,'roster_generation'=>'c'*64,'state'=>'observed_candidate','finality'=>'unknown',
    'start_allowed'=>false,'dispatch_allowed'=>false,'finalize_allowed'=>false,'roster'=>%w[alice bob],
    'timezone'=>'UTC','windows'=>[{'date'=>'2026-10-13','start'=>'11:00','end_date'=>'2026-10-13','end'=>'13:00'}],
    'matches'=>[{'match_id'=>'d'*64,'leg'=>1,'players'=>%w[alice bob]},{'match_id'=>'e'*64,'leg'=>2,'players'=>%w[bob alice]}]}
  source=-> {{'candidate'=>candidate,'tournament_id'=>7}}
  journals={}
  make=-> {
    journal=T::OperationJournal.new(directory:File.join(directory,actor,'proposal'),owner:actor.downcase,backend_identity:'pilot')
    journals[actor]=journal
    ready_journal=T::OperationJournal.new(directory:File.join(directory,actor,'ready'),owner:actor.downcase,backend_identity:'ready')
    ready=T::ServerReadinessService.new(table:table,journal:ready_journal,user:-> {actor},source:source,clock:-> {now})
    service=T::ServerProposalService.new(table:table,journal:journal,user:-> {actor},source:source,readiness:ready,clock:-> {now})
    [ready,service]
  }
  ready,service=make.call
  match={match_id:'d'*64,leg:1}
  assert_equal('missing',service.snapshot(**match)['state'])
  assert_equal(0,table.insert_count)
  ready.set_available(available:true,intent_id:'alice-ready')
  actor='Bob'
  ready,service=make.call
  ready.set_available(available:true,intent_id:'bob-ready')
  actor='Alice'
  ready,service=make.call
  proposed=service.propose(**match,intent_id:'proposal-one')
  assert_equal('awaiting_consent',proposed['state'])
  token=proposed['token']
  before=table.insert_count
  assert_raises(T::Publication::Invalid){service.respond(**match,token:'f'*64,accept:true,intent_id:'stale')}
  assert_equal(before,table.insert_count)
  assert_equal(['alice'],proposed['accepted'],'Inviting did not record the initiator consent')
  actor='Bob'
  _ready,service=make.call
  observed_partial=[]
  table.on_insert=->(row) do
    if row['part_index']==0
      snapshot=service.snapshot(**match)
      observed_partial<<snapshot
      assert_equal('awaiting_consent',snapshot['state'])
      assert_equal(['alice'],snapshot['accepted'],'Partial response granted consent')
    end
  end
  result=service.respond(**match,token:token,accept:true,intent_id:'bob-accept')
  table.on_insert=nil
  assert_equal(1,observed_partial.size)
  assert_equal('consented',result['state'])
  assert_equal(false,result['start_allowed'],'Observed consent fabricated a global execution grant')
  # A newer incomplete decline must not expose the older accepted response.
  table.on_insert=->(row) do
    if row['part_index']==0
      snapshot=service.snapshot(**match)
      assert_equal('awaiting_consent',snapshot['state'])
      assert_equal(['alice'],snapshot['accepted'],'Fell back to acceptance before a partial decline')
    end
  end
  assert_equal('declined',service.respond(**match,token:token,accept:false,intent_id:'bob-decline-after-accept')['state'])
  table.on_insert=nil
  actor='Alice'
  ready,service=make.call
  rematch={match_id:'e'*64,leg:2}
  assert_equal('missing',service.snapshot(**rematch)['state'],'First leg consent leaked into return match')
  actor='Bob'
  ready,service=make.call
  token=service.propose(**rematch,intent_id:'return-one')['token']
  actor='Alice'
  ready,service=make.call
  service.respond(**rematch,token:token,accept:true,intent_id:'alice-return')
  actor='Bob'
  _ready,service=make.call
  assert_equal('declined',service.respond(**rematch,token:token,accept:false,intent_id:'not-now')['state'])
  assert_equal(2,candidate['matches'].size,'Not now added a fixture')
  actor='Bob'
  ready,service=make.call
  token=service.propose(**rematch,intent_id:'return-two')['token']
  # Tournament-wide availability does not change explicit match consent.
  ready.set_available(available:true,intent_id:'renewed')
  assert_equal('awaiting_consent',service.snapshot(**rematch)['state'])
  ready.set_available(available:false,intent_id:'withdrawn')
  ready.set_available(available:true,intent_id:'enabled-again')
  assert_equal('awaiting_consent',service.snapshot(**rematch)['state'],'Global readiness must not cancel an explicit invitation')
  assert_equal('declined',service.respond(**rematch,token:token,accept:false,intent_id:'cancel-return')['state'])
  token=service.propose(**rematch,intent_id:'return-three')['token']
  actor='Alice'
  ready,service=make.call
  table.on_insert=->(row){raise IOError,'Lost final acknowledgement' if row['part_index']==1}
  assert_raises(IOError){service.respond(**rematch,token:token,accept:true,intent_id:'lost-accept')}
  table.on_insert=nil
  before=table.insert_count
  record=journals['Alice'].list.find{|row|row['intent_id']=='pilot:lost-accept'}
  _ready,cold=make.call
  assert_equal('confirmed',cold.reconcile(record['id'])['status'])
  assert_equal(before,table.insert_count)
  assert_equal(%w[alice bob],cold.snapshot(**rematch)['accepted'].sort)
  now+=300
  assert_equal('expired',cold.snapshot(**rematch)['state'])
  candidate['roster_generation']='9'*64
  assert_raises(T::Publication::Invalid){cold.snapshot(**rematch)}
  actor='Bob'
  assert_raises(T::ServerPlanArchive::ContextChanged){cold.snapshot(**rematch)}
  actor='Alice'
  assert_raises(T::ServerPlanArchive::ContextChanged){cold.snapshot(**rematch)}
end
puts 'PASS server pilot proposals: authenticated invitation/player writes, explicit all-party consent, separate return leg and Not now, no execution grant, readiness independence, stale token rejection, lost reply/cold readback without resend, generation/account guards'
