require 'tmpdir'
require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/tournament_public_ui'
require_relative '../support/proposal_notice_storage'
require_relative '../../lib/tournaments/tournament_start_publisher'
require_relative '../../lib/tournaments/proposal_notice_journal'
include GameRoomTest::Assertions
T=GameRoomTournaments
u=TournamentPublicUI
starts=Time.utc(2026,10,15,18).to_i
now=starts-1
row=u.publication(11).merge('__insertion_user'=>'Alice','timezone'=>'UTC')
people=%w[alice bob]
complete=true
scope={'account'=>'alice','account_epoch'=>'epoch-one','backend_identity'=>'trusted-trial'}
source=->(reference){raise 'Wrong reader reference' unless reference=={'author'=>'alice','publication_key'=>row['publication_key']};
  {'complete'=>complete,'publication'=>row,'participants'=>people}}
make=-> {T::TournamentStartNotice.new(source:source,context:-> {scope},clock:-> {now},registry:GameRoomGames::CATALOG)}
service=make.call
reference={'author'=>'Alice','publication_key'=>row['publication_key']}
assert_raises(T::ProposalNotice::Stale){service.notices(publication_ref:reference)}
now=starts
notices=service.notices(publication_ref:reference)
assert_equal(%w[alice bob],notices.map{|notice|notice['recipient']})
notice=notices.last
assert_equal(row['title'],service.inspect(metadata:notice,sender:'Alice',delivery:true)['title'])
Dir.mktmpdir('start-notice-',ENV.fetch('TMPDIR')) do |directory|
  program=ProposalNoticeStorageSupport::Program.new(directory)
  journal=-> {T::ProposalNoticeJournal.new(program:program,path:'starts.json')}
  sent=[]
  sender=-> {scope['account']}
  deliver=->(_metadata,_expires){sent<<:attempt;raise IOError,'Notification acknowledgement lost'}
  publisher=T::TournamentStartPublisher.new(service:service,sender:sender,transaction:journal.call.method(:update),send:deliver)
  assert_raises(IOError){publisher.deliver(metadata:notice)}
  cold=T::TournamentStartPublisher.new(service:make.call,sender:sender,transaction:journal.call.method(:update),send:->(*){sent<<:duplicate;true})
  assert_equal(:confirmation_pending,cold.deliver(metadata:notice))
  assert_equal([:attempt],sent)
  alice_notice=notices.first
  assert_equal(:sent,cold.deliver(metadata:alice_notice))
  assert_equal(:sent,cold.deliver(metadata:alice_notice))
  assert_equal([:attempt,:duplicate],sent,'Confirmed start sent again')
end
scope={'account'=>'bob','account_epoch'=>'bob-epoch','backend_identity'=>'trusted-trial'}
recipient=make.call
assert_equal('chess',recipient.inspect(metadata:notice,sender:'Alice')['game'])
assert_raises(T::ProposalNotice::Stale){recipient.inspect(metadata:notice,sender:'Mallory')}
people=['alice']
assert_raises(T::ProposalNotice::Stale){recipient.inspect(metadata:notice,sender:'Alice')}
people=%w[alice bob]
complete=false
assert_raises(T::ProposalNotice::Stale){recipient.inspect(metadata:notice,sender:'Alice')}
complete=true
now=starts+T::TournamentStartNotice::READING_GRACE
assert_raises(T::ProposalNotice::Stale){recipient.inspect(metadata:notice,sender:'Alice')}
now=starts
scope=scope.merge('account_epoch'=>'changed-epoch')
assert_raises(T::ProposalNotice::Stale){recipient.inspect(metadata:notice,sender:'Alice')}
scope=scope.merge('account_epoch'=>'bob-epoch')
assert_raises(T::ProposalNotice::Stale){recipient.inspect(metadata:notice,sender:'Alice')}
puts 'PASS tournament start notices: actual game/title from authenticated snapshot, registered recipients only, start/expiry windows, sender/epoch/complete-source guards, local durable once-only attempts and cold lost-reply protection'
