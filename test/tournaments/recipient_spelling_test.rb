require_relative '../support/temporary_directory'
require_relative '../support/tournament_public_ui'
require_relative '../../lib/tournaments/tournament_start_runtime'
include GameRoomTest::Assertions
T = GameRoomTournaments
module Session
  def self.name; 'Alice'; end
end

class RecipientSpellingProgram
  include GameRoomTournaments::TournamentStartRuntime
  attr_reader :sent
  def initialize(directory); @directory, @sent = directory, []; end
  def data_path(path); File.join(@directory, path); end
  def update_json(path, default:)
    target = data_path(path)
    value = File.exist?(target) ? JSON.parse(File.read(target)) : default
    yield value
    File.write(target, JSON.generate(value))
  end
  def send_notification(user, **arguments); @sent << [user, arguments]; true; end
end

now = Time.utc(2026, 10, 15, 18, 0, 1).to_i
publication = TournamentPublicUI.publication(11).merge('__insertion_user'=>'Alice')
registrations = [TournamentPublicUI.registration(1,user:'Alice'), TournamentPublicUI.registration(2,user:'Peterman')]
projection = T::RegistrationProjection.build(announcements:[publication], registrations:registrations,
  registry:GameRoomGames::CATALOG, complete:true)
members = projection.to_h.fetch('members')
names = T::RegistrationProjection.usernames(members)
assert_equal({'alice'=>'Alice','peterman'=>'Peterman'}, names)
unicode_name = "İ" * 64
unicode_names = T::RegistrationProjection.usernames([{'account'=>unicode_name.downcase,'username'=>unicode_name}])
assert_equal(unicode_name,T::RegistrationProjection.delivery_name(unicode_names,unicode_name.downcase),
  'Case expansion applied the raw-name length limit to a canonical account key')
before = Marshal.dump(projection.to_h)
reference = {'author'=>'alice','publication_key'=>publication['publication_key']}
scope = {'account'=>'alice','account_epoch'=>'one','backend_identity'=>'spelling-test'}
start = T::TournamentStartNotice.new(source:->(_) {
  {'complete'=>true,'publication'=>publication,'participants'=>names.keys,'usernames'=>names}
}, context:-> {scope}, clock:-> {now}, registry:GameRoomGames::CATALOG)
registration = T::TournamentEventNotice.new(kind:'registration',source:->(_) {
  {'publication'=>publication.merge('registration_closes_at'=>now+60),
   'people'=>['alice'],'members'=>members.take(1),'usernames'=>names.slice('alice')}
}, context:-> {scope}, clock:-> {now}, registry:GameRoomGames::CATALOG)

GameRoomTest::TemporaryDirectory.create('recipient-spelling-') do |directory|
  program = RecipientSpellingProgram.new(directory)
  program.instance_variable_set(:@tournament_event_services, {'registration'=>registration})
  program.instance_variable_set(:@tournament_start_service, start)
  assert_equal([:sent], program.send_tournament_event(kind:'registration',publication_ref:reference,recipient:'Peterman'))
  assert_equal('Peterman', program.sent.first.first)
  assert_equal('peterman', program.sent.first.last[:metadata]['recipient'])
  metadata_before = start.notices(publication_ref:reference)
  assert_equal({'alice'=>:sent,'peterman'=>:sent}, program.send_tournament_start_notices(publication_ref:reference))
  assert_equal(%w[Peterman Alice Peterman], program.sent.map(&:first))
  assert_equal(metadata_before, program.sent.drop(1).map { |row| row.last[:metadata] }, 'Wire format/identity changed with spelling')
  program.send_tournament_start_notices(publication_ref:reference)
  assert_equal(3, program.sent.size, 'Name preservation resent an old event')
end
assert_equal(before, Marshal.dump(projection.to_h), 'Addressing modified the original registrations')
assert_equal(:missing_participant_name, assert_raises(T::Publication::Invalid) {
  T::RegistrationProjection.delivery_name({'peterman'=>'OtherPerson'}, 'peterman')
}.code)
puts 'PASS recipient spelling: authenticated registration names, real event/start send hooks, unchanged wire metadata and deduplication, no directory lookup'
