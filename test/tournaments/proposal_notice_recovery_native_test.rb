require_relative '../support/tournament_individual_ui'
require_relative '../../lib/tournaments/proposal_notice_dialog'
include GameRoomTest::Assertions
T=GameRoomTournaments
fixture=TournamentIndividualUI.fixture
GameRoomLocalization.boot(settings:{'interface_language'=>'en','known_languages'=>['en']})
metadata={'stage'=>'consent','leg'=>1,'recipient'=>'alice'}
proof={'players'=>%w[alice bob],'accepted'=>[]}
begin
  [T::ServerParticipantLease::Busy.new('busy'),T::ServerPlanArchive::Unconfirmed.new('lost reply'),
    T::OperationJournal::Conflict.new(:ambiguous_operation),IOError.new('offline')].each do |failure|
    [:inspect,:respond].each do |stage|
      driver=TournamentNativeDriver.new
      service=Object.new
      service.define_singleton_method(:inspect){|**_|raise failure if stage==:inspect;proof}
      service.define_singleton_method(:respond){|**_|raise failure}
      dialog=T::ProposalNoticeDialog.new(program:fixture[:program],service:service,
        metadata:metadata,sender:'owner',work:->(&operation){operation.call})
      notices=[]
      dialog.define_singleton_method(:alert){|message|notices << message}
      dialog.send(:build_form)
      dialog.instance_variable_get(:@form).fields[1].trigger(:press) if stage==:respond
      assert_equal(true,dialog.instance_variable_get(:@finished))
      assert_equal(1,notices.length)
      expected=failure.is_a?(T::ServerParticipantLease::Busy) ? 'Leave your current table' : 'Server write not confirmed'
      assert(notices.first.include?(expected),'Wrong recovery guidance')
      driver.finish
    end
  end
  service=Object.new
  service.define_singleton_method(:inspect){|**_|raise NoMethodError,'programming fault'}
  dialog=T::ProposalNoticeDialog.new(program:fixture[:program],service:service,
    metadata:metadata,sender:'owner',work:->(&operation){operation.call})
  assert_raises(NoMethodError){dialog.send(:build_form)}
ensure
  fixture[:program].finalize
  fixture[:program].class.app_runtime.close
end
puts 'PASS real proposal recovery: busy, uncertain write, journal conflict, IO failure and visible programming error'
