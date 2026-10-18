require_relative '../support/temporary_directory'
require 'tmpdir'
require_relative '../support/native_room_harness'
require_relative '../support/readiness_plan_table'
require_relative '../../lib/tournaments/server_proposal_service'
include GameRoomTest::Assertions
T=GameRoomTournaments

GameRoomTest::TemporaryDirectory.create('proposal-expiry-') do |directory|
  actor,now='alice',Time.utc(2026,10,14,12).to_i
  table=ReadinessPlanTableSupport::Table.new(user:-> {actor},clock:-> {now})
  candidate={'publication_ref'=>{'author'=>'alice','publication_key'=>'fixture'},'schedule_id'=>'a'*64,
    'publication_digest'=>'b'*64,'roster_generation'=>'c'*64,'state'=>'observed_candidate','finality'=>'unknown',
    'start_allowed'=>false,'dispatch_allowed'=>false,'finalize_allowed'=>false,'roster'=>%w[alice bob],
    'timezone'=>'UTC','windows'=>[{'date'=>'2026-10-14','start'=>'12:00','end_date'=>'2026-10-14','end'=>'13:00'}],
    'matches'=>[{'match_id'=>'d'*64,'leg'=>1,'players'=>%w[alice bob]}]}
  make=-> {
    journal=T::OperationJournal.new(directory:File.join(directory,actor,'proposal'),owner:actor,backend_identity:'proposal')
    ready_journal=T::OperationJournal.new(directory:File.join(directory,actor,'ready'),owner:actor,backend_identity:'readiness')
    source=-> {{'candidate'=>candidate,'tournament_id'=>7}}
    ready=T::ServerReadinessService.new(table:table,journal:ready_journal,user:-> {actor},source:source,clock:-> {now})
    proposal=T::ServerProposalService.new(table:table,journal:journal,user:-> {actor},source:source,readiness:ready,clock:-> {now})
    [ready,proposal]
  }
  renew=-> {
    %w[alice bob].each do |account|
      actor=account
      make.call.first.set_available(available:true,intent_id:SecureRandom.uuid)
    end
    actor='alice'
  }
  match={match_id:'d'*64,leg:1}
  renew.call
  now+=27
  _,service=make.call
  first=service.propose(**match,intent_id:'first')
  token=first['token']
  deadline=first.dig('window','closes')
  assert_equal(300,deadline-now,'Invitation reused the remaining 33 seconds of presence')
  assert_equal(['alice'],first['accepted'])
  renew.call
  4.times do
    now+=30
    renew.call
    _,service=make.call
    observed=service.snapshot(**match)
    assert_equal('awaiting_consent',observed['state'])
    assert_equal(['alice'],observed['accepted'])
    assert_equal(token,observed['token'])
    assert_equal(deadline,observed.dig('window','closes'),'Heartbeat extended the consent deadline')
  end
  actor='bob'
  _,service=make.call
  observed=service.respond(**match,token:token,accept:true,intent_id:'bob-accept')
  assert_equal('consented',observed['state'],'Human-paced acceptance failed after the original presence TTL')
  now+=30
  renew.call
  now=deadline
  renew.call
  _,service=make.call
  expired=service.snapshot(**match)
  assert_equal('expired',expired['state'])
  assert_equal('timeout',expired['expiry_reason'])
  assert_equal(%w[alice bob],expired['accepted'],'Expiry erased the displayed response history')
  before=table.insert_count
  assert_raises(T::Publication::Invalid){service.respond(**match,token:token,accept:true,intent_id:'late')}
  assert_equal(before,table.insert_count)

  actor='bob'
  _,service=make.call
  token=service.propose(**match,intent_id:'guest-invites')['token']
  assert_equal(['bob'],service.snapshot(**match)['accepted'])
  now+=61
  _,service=make.call
  assert_equal('awaiting_consent',service.snapshot(**match)['state'],'Invitation depended on readiness heartbeat')
  actor='alice'
  _,service=make.call
  assert_equal('consented',service.respond(**match,token:token,accept:true,intent_id:'host-accepts')['state'])
  assert_equal('declined',service.respond(**match,token:token,accept:false,intent_id:'cancel')['state'])

  now=Time.utc(2026,10,14,12,59,30).to_i
  renew.call
  _,service=make.call
  ending=service.propose(**match,intent_id:'end-of-window')
  assert_equal(30,ending.dig('window','closes')-now,'Consent crossed the tournament play window')
end
puts 'PASS proposal expiry: independent 300 seconds, uninterrupted renewal, delayed consent, fixed deadline, retained responses, explicit cancellation and no presence dependency and play-window boundary'
