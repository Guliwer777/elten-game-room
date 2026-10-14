require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/native_room_harness'
require_relative '../../lib/tournaments/proposal_notice_inbox'
include GameRoomTest::Assertions
T = GameRoomTournaments
scope = {'account'=>'alice', 'account_epoch'=>'session-1', 'backend_identity'=>'trusted-test'}
notice = {'version'=>1, 'backend_identity'=>'trusted-test', 'publication_ref'=>{'author'=>'owner','publication_key'=>'fixture'},
  'schedule_id'=>'a'*64, 'match_id'=>'b'*64, 'leg'=>1, 'token'=>'c'*64, 'recipient'=>'alice'}
proof = {'status'=>'confirmed', 'metadata'=>notice, 'players'=>%w[alice bob], 'accepted'=>[], 'sender'=>'owner',
  'ready'=>%w[alice bob].to_h{|account|[account,{'state'=>'ready','revision'=>'ready-1'}]},
  'revision'=>'proposal-1', 'window'=>{'opens'=>100,'closes'=>200}}
now = 150
reads, writes = [], []
backend = Object.new
backend.define_singleton_method(:lookup_proposal){|notice:| reads << notice; proof}
backend.define_singleton_method(:respond_proposal){|**options| writes << options; :confirmed}
service = T::ProposalNotice.new(backend:backend,context:-> {scope},clock:-> {now})
shown = service.inspect(metadata:notice,sender:'owner')
assert(shown.frozen? && shown['metadata'].frozen?)
assert_equal(:confirmed,service.respond(metadata:notice,sender:'owner',displayed:shown,accept:true))
assert_equal('proposal-1',writes.first[:expected_revision])
proof['revision']='proposal-2'
assert_raises(T::ProposalNotice::Stale){service.respond(metadata:notice,sender:'owner',displayed:shown,accept:false)}
assert_equal(1,writes.size)
proof['revision']='proposal-1'
assert_raises(T::ProposalNotice::Stale){service.inspect(metadata:notice,sender:'intruder')}
proof['ready']['alice']['state']='withdrawn'
assert_raises(T::ProposalNotice::Stale){service.inspect(metadata:notice,sender:'owner')}
proof['ready']['alice']['state']='ready'
now=200
assert_raises(T::ProposalNotice::Stale){service.inspect(metadata:notice,sender:'owner')}
assert_equal(false,service.presentable?(shown))
now=150
other=notice.merge('recipient'=>'bob')
before=reads.size
assert_raises(T::ProposalNotice::Stale){service.inspect(metadata:other,sender:'owner')}
assert_equal(before,reads.size)
assert_raises(T::Publication::Invalid){service.inspect(metadata:notice.merge('endpoint'=>'http://invalid'),sender:'owner')}
scope['account_epoch']='session-2'
assert_raises(T::ProposalNotice::Stale){service.inspect(metadata:notice,sender:'owner')}
scope['account_epoch']='session-1'
assert_raises(T::ProposalNotice::Stale){service.inspect(metadata:notice,sender:'owner')}
fresh=T::ProposalNotice.new(backend:backend,context:-> {scope},clock:-> {now})
unavailable=T::ProposalNotice.new(backend:nil,context:-> {scope},clock:-> {now})
before=reads.size
assert_raises(T::ProposalNotice::Unavailable){unavailable.inspect(metadata:notice,sender:'owner')}
assert_equal(before,reads.size)

worker=Class.new do
  attr_reader :starts
  def initialize; @starts=0; end
  def start(&block); @starts+=1; @operation=block; true; end
  def busy?; !!@operation; end
  def take
    return unless @operation
    operation,@operation=@operation,nil
    begin; [operation.call,nil]; rescue StandardError=>error; [nil,error]; end
  end
  def close; @operation=nil; end
end.new
inbox=T::ProposalNoticeInbox.new(service:fresh,worker:worker)
assert(inbox.receive(id:1,metadata:notice,sender:'owner'))
assert_equal(false,inbox.receive(id:2,metadata:notice,sender:'owner'),'Duplicate delivery with another notification ID')
assert_equal([],inbox.tick)
assert_equal(1,inbox.tick.size)
10.times{assert_equal([],inbox.tick)}
assert_equal(1,worker.starts,'Idle ticks must not poll')
inbox.close
assert_equal(nil,inbox.verified(1))
assert_equal(false,inbox.receive(id:3,metadata:notice,sender:'owner'))
assert_equal(1,writes.size,'Receiving notices must not consent or create tables')
puts 'PASS tournament proposal notices: authenticated lookup, explicit readiness, fresh conditional consent, account epochs, expiry, forged/stale rejection, deduplication and no polling/automatic response'
