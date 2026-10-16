require_relative '../support/tournament_individual_ui'
require_relative '../../lib/tournaments/server_proposal_screen'
include GameRoomTest::Assertions
T=GameRoomTournaments

class ProposalRefreshWorker
  attr_reader :starts
  def initialize; @starts=0; end
  def start(&block); @starts+=1; @pending=block; true; end
  def busy?; !!(@pending || @done); end
  def complete(value,error=nil); @pending=nil; @done=[value,error]; end
  def take; result=@done; @done=nil; result; end
  def close; @pending=@done=nil; end
end

%w[en pl cs es ru].each do |language|
  fixture=TournamentIndividualUI.fixture
  GameRoomLocalization.boot(settings:{'interface_language'=>language,'known_languages'=>[language]})
  translate=->(value){GameRoomContent.utf8(GameRoomLocalization.translate(value))}
  now,revision=100,1
  fixture[:program].class.define_singleton_method(:tournament_view_revision){|_|revision}
  workspace=Object.new
  workspace.define_singleton_method(:actor){'Alice'}
  value={'state'=>'awaiting_consent','token'=>'a'*64,'players'=>%w[alice bob],'accepted'=>['alice'],
    'declined'=>[],'window'=>{'opens'=>100,'closes'=>280},'table_available'=>false}
  reads=0
  workspace.define_singleton_method(:shared_proposal) do |**|
    reads+=1
    value
  end
  workspace.define_singleton_method(:proposal_view_on_worker){|**|raise 'Unexpected real worker read'}
  owner=T::Dialogs::Owner.new(-> {TournamentIndividualUI::F::OWNER},->(message){raise message})
  screen=T::ServerProposalScreen.new(program:fixture[:program],workspace:workspace,owner:owner,
    publication:{'__insertion_user'=>'Alice','publication_key'=>'fixture'},
    match:{'match_id'=>'b'*64,'leg'=>1,'players'=>%w[alice bob]},clock:-> {now})
  driver=TournamentNativeDriver.new
  driver.step(translate.call('Tournament match'),[27]) do |form|
    screen.instance_variable_get(:@refresh_work).close
    worker=ProposalRefreshWorker.new
    screen.instance_variable_set(:@refresh_work,worker)
    form.index=0
    form.fields[0].index=5
    form.fields[0].check=5
    revision=2
    screen.send(:update_invitation)
    assert_equal(1,worker.starts)
    accepted=value.merge('state'=>'consented','accepted'=>%w[alice bob])
    worker.complete(accepted)
    screen.send(:update_invitation)
    assert_equal(%w[alice bob],screen.instance_variable_get(:@observed)['accepted'])
    assert(form.fields[0].text.include?(translate.call('All players accepted. Opening the match table.')),'Remote acceptance not shown')
    assert_equal(0,form.index,'Automatic refresh moved form focus')
    assert_equal(5,form.fields[0].index,'Automatic refresh moved the reading cursor')
    20.times{screen.send(:update_invitation)}
    assert_equal(1,worker.starts,'Unchanged state caused polling')
    now=280
    screen.send(:update_invitation)
    assert(form.fields[0].text.include?(translate.call('This invitation expired. Choose Play to send a new one.')),'Deadline not shown')
    assert(form.fields[0].text.include?('alice — bob'),'Deadline hid recorded replies')
    assert_equal('expired',screen.instance_variable_get(:@observed)['state'])
    assert_equal(1,reads,'Deadline expiry accessed the network')
    revision=3
    screen.send(:update_invitation)
    value=accepted.merge('state'=>'declined','declined'=>['alice'])
    screen.send(:perform,'read')
    worker.complete(accepted)
    screen.send(:update_invitation)
    assert_equal('declined',screen.instance_variable_get(:@observed)['state'],'Late background read replaced a newer action')
    value=value.merge('state'=>'missing','accepted'=>[])
    screen.send(:perform,'read')
    assert(!form.fields[0].text.include?(translate.call('Accepted: %{players}').split('%').first),'Empty acceptance label remains')
    revision=4
    screen.send(:update_invitation)
    worker.complete(nil,T::TablesGateway::Error.new('Read unavailable'))
    original_warning=Log.method(:warning)
    warnings=[]
    begin
      Log.define_singleton_method(:warning){|message|warnings<<message}
      screen.send(:update_invitation)
    ensure
      Log.define_singleton_method(:warning,original_warning)
    end
    assert_equal(1,warnings.size)
    assert(warnings.first.include?('Read unavailable'),'Expected read failure was not logged')
    assert_equal(nil,screen.instance_variable_get(:@observed),'Failed refresh retained actionable consent')
    assert(form.fields[0].text.include?(translate.call('The invitation could not be checked. Refresh before trying again.')),'Refresh error was not explained')
    revision=5
    screen.send(:update_invitation)
    worker.complete(nil,NoMethodError.new('Programming error'))
    assert_raises(NoMethodError){screen.send(:update_invitation)}
    cached=value.merge('state'=>'declined','declined'=>['bob'])
    fixture[:program].class.define_singleton_method(:tournament_proposal_snapshot) do |reference,**match|
      assert_equal({'author'=>'alice','publication_key'=>'fixture'},reference)
      assert_equal({match_id:'b'*64,leg:1},match)
      cached
    end
    before=worker.starts
    revision=6
    screen.send(:update_invitation)
    assert_equal(cached,screen.instance_variable_get(:@observed),'Coordinator presentation was not reused')
    assert_equal(before,worker.starts,'Presentation reread a just-delivered invitation')
    before_reads=reads
    screen.send(:perform,'read')
    assert_equal(before_reads+1,reads,'Explicit Refresh used a cached view')
    cached=nil
    revision=7
    screen.send(:update_invitation)
    assert_equal(before+1,worker.starts,'Unavailable coordinator view did not fall back to a fresh read')
  end
  begin
    screen.run
    driver.finish
    assert_equal(0,fixture[:program].class.app_runtime.managed_resources.size)
  ensure
    fixture[:program].class.singleton_class.remove_method(:tournament_view_revision)
    fixture[:program].class.singleton_class.remove_method(:tournament_proposal_snapshot) if fixture[:program].class.respond_to?(:tournament_proposal_snapshot)
    fixture[:program].finalize
    fixture[:program].class.app_runtime.close
  end
end
puts 'PASS native proposal refresh EN/PL/CS/ES/RU: changed-state reads, stable focus/cursor, local deadline, retained replies, no polling, stale-read rejection and cleanup'
