require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/native_room_harness'
require_relative '../../lib/tournaments/proposal_notice_publisher'
include GameRoomTest::Assertions
T=GameRoomTournaments
scope={'account'=>'owner','account_epoch'=>'epoch-1','backend_identity'=>'trial'}
notice={'version'=>1,'backend_identity'=>'trial','publication_ref'=>{'author'=>'owner','publication_key'=>'fixture'},
  'schedule_id'=>'a'*64,'match_id'=>'b'*64,'leg'=>2,'token'=>'c'*64,'recipient'=>'alice'}
proof={'status'=>'confirmed','metadata'=>notice,'players'=>%w[alice bob],'accepted'=>[],'sender'=>'owner',
  'ready'=>%w[alice bob].to_h{|name|[name,{'state'=>'ready','revision'=>'ready-1'}]},'revision'=>'proposal-1','window'=>{'opens'=>100,'closes'=>200}}
backend=Object.new
backend.define_singleton_method(:lookup_proposal){|notice:|proof}
service=T::ProposalNotice.new(backend:backend,context:-> {scope},clock:-> {150})
state={'version'=>1,'operations'=>{}}
transaction=->(&block) do
  copy=Marshal.load(Marshal.dump(state))
  block.call(copy)
  state=copy
end
sends=[]
lost=true
send_notice=->(value,expiry){sends << [value,expiry]; raise IOError,'Notification acknowledged too late' if lost; true}
factory=-> {T::ProposalNoticePublisher.new(service:service,sender:-> {'owner'},transaction:transaction,send:send_notice)}
assert_raises(IOError){factory.call.deliver(metadata:notice)}
assert_equal('attempted',state['operations'].values.first['state'])
lost=false
assert_equal(:confirmation_pending,factory.call.deliver(metadata:notice),'Cold reconstruction must not resend')
assert_equal(1,sends.size)
second=notice.merge('token'=>'d'*64)
proof['metadata']=second
assert_equal(:sent,factory.call.deliver(metadata:second))
assert_equal(:sent,factory.call.deliver(metadata:second))
assert_equal(2,sends.size)
assert_equal(200,sends.last[1])
corrupt={'version'=>1,'operations'=>{'bad-key'=>{}}}
bad=->(&block){block.call(corrupt)}
assert_raises(T::Publication::Invalid){T::ProposalNoticePublisher.new(service:service,sender:-> {'owner'},transaction:bad,send:send_notice).deliver(metadata:second)}
assert_equal(2,sends.size)
assert_equal('bad-key',corrupt['operations'].keys.first)
scope['account_epoch']='epoch-2'
assert_raises(T::ProposalNotice::Stale){factory.call.deliver(metadata:second)}
assert_equal(2,sends.size)
puts 'PASS notification publisher: one durable attempt, lost acknowledgement/cold restart without resend, new token, confirmed duplicate, corrupt state and changed account blocked'
