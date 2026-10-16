if ARGV[1]
  package=ARGV.delete_at(1)
  ARGV.unshift(package)
  require_relative 'binary_rules_load'
  ARGV.shift
end
require_relative 'proposal_notice_storage'
require_relative '../../lib/tournaments/proposal_notice_journal'
require_relative '../../lib/tournaments/proposal_notice_publisher'
directory=ARGV.fetch(0)
T=GameRoomTournaments
scope={'account'=>'owner','account_epoch'=>'epoch-1','backend_identity'=>'trial'}
notice={'version'=>1,'backend_identity'=>'trial','publication_ref'=>{'author'=>'owner','publication_key'=>'fixture'},
  'schedule_id'=>'a'*64,'match_id'=>'b'*64,'leg'=>1,'token'=>'c'*64,'recipient'=>'alice'}
proof={'status'=>'confirmed','metadata'=>notice,'players'=>%w[alice bob],'accepted'=>[],'sender'=>'owner',
  'revision'=>'proposal-1','window'=>{'opens'=>100,'closes'=>200}}
backend=Object.new
backend.define_singleton_method(:lookup_proposal){|notice:|proof}
service=T::ProposalNotice.new(backend:backend,context:-> {scope},clock:-> {150})
program=ProposalNoticeStorageSupport::Program.new(directory)
journal=T::ProposalNoticeJournal.new(program:program,path:'deliveries.json')
publisher=T::ProposalNoticePublisher.new(service:service,sender:-> {'owner'},transaction:journal.method(:update),
  send:->(_notice,_closes){File.open(File.join(directory,'sent.txt'),'a'){|file|file.puts(Process.pid)};true})
raise 'Delivery did not reconcile' unless [:sent,:confirmation_pending].include?(publisher.deliver(metadata:notice))
