require_relative '../support/tournament_local_workspace'
require_relative '../../lib/tournaments/server_coordination'
include GameRoomTest::Assertions
T=GameRoomTournaments

class CoordinationInlineWorker
  def start
    @done=[yield,nil]
  rescue StandardError=>error
    @done=[nil,error]
  end
  def take; result=@done; @done=nil; result; end
  def busy?; false; end
  def close; end
end

now=100
bad={'author'=>'owner','publication_key'=>'incomplete'}
good={'author'=>'owner','publication_key'=>'ready'}
seen=[]
failure=T::Publication::Invalid.new(:incomplete_pairs)
workspace=Object.new
workspace.define_singleton_method(:read_operation){|&block|block.call}
coordinator=T::ServerCoordination.new(workspace:workspace,user:-> {'owner'},clock:-> {now},
  worker:CoordinationInlineWorker.new,wake:->(*){})
coordinator.define_singleton_method(:coordinate_current) do |reference,**|
  seen<<reference
  raise failure if reference==bad && failure
  {}
end

coordinator.changed(bad)
coordinator.changed(good)
coordinator.tick
coordinator.tick
assert_equal([bad,good],seen,'Incomplete pairs delayed another tournament')
assert_equal(failure,coordinator.last_error,'Validation failure was hidden')
coordinator.tick
assert_equal(nil,coordinator.last_error)

# Transport failures retain the shared backoff: the next tournament uses
# the same connection and must not evade rate limits.
failure=IOError.new('connection unavailable')
seen.clear
coordinator.changed(bad)
coordinator.changed(good)
coordinator.tick
coordinator.tick
assert_equal([bad],seen)
now+=29
coordinator.tick
assert_equal([bad],seen)
now+=1
failure=nil
coordinator.tick
assert_equal([bad,bad],seen,'The failed one-shot task was discarded instead of retried')
coordinator.tick
assert_equal([bad,bad,good],seen)
coordinator.tick
assert_equal(nil,coordinator.last_error)

# Programming errors remain observable and are not automatically retried.
failure=NoMethodError.new('broken fixture')
seen.clear
coordinator.changed(bad)
coordinator.changed(good)
coordinator.tick
coordinator.tick
assert_equal(failure,coordinator.last_error)
assert_equal([bad,good],seen)
coordinator.tick
coordinator.tick
assert_equal([bad,good],seen)
coordinator.close

# A failed startup listing has no availability timer or later incoming event
# to recover it. It must retain its own bounded retry as well.
attempts=0
seen.clear
coordinator=T::ServerCoordination.new(workspace:workspace,user:-> {'owner'},clock:-> {now},
  worker:CoordinationInlineWorker.new,wake:->(*){})
coordinator.define_singleton_method(:directory) do
  attempts+=1
  raise IOError,'startup connection unavailable' if attempts<=2
  {'deadlines'=>[[good,now]]}
end
coordinator.define_singleton_method(:coordinate_current) do |reference,**|
  seen<<reference
  {}
end
coordinator.bootstrap
coordinator.tick
coordinator.tick
assert_equal(1,attempts)
now+=30
coordinator.tick
coordinator.tick
assert_equal(2,attempts)
now+=59
coordinator.tick
assert_equal(2,attempts,'Repeated failure did not increase the backoff')
now+=1
coordinator.tick
coordinator.tick
assert_equal(3,attempts)
assert_equal([good],seen,'Successful startup retry did not restore scheduled work')
coordinator.tick
assert_equal(nil,coordinator.last_error)
coordinator.close
now+=600
coordinator.tick
assert_equal(3,attempts,'Closed coordinator restarted work')

# Only a meaningful result changes the match form's local revision. Empty
# work / unchanged heartbeats must not cause extra UI reads or retain views.
visible={'overview'=>{'candidate'=>{'schedule_id'=>'b'*64},'results'=>{'results'=>[]}}}
coordinator=T::ServerCoordination.new(workspace:workspace,user:-> {'owner'},clock:-> {now},
  worker:CoordinationInlineWorker.new,wake:->(*){})
coordinator.define_singleton_method(:coordinate_current){|*,**|visible}
refresh=->(reference){coordinator.changed(reference);2.times{coordinator.tick}}
refresh.call(good)
first=coordinator.view_revision(good)
assert(first.is_a?(Integer),'No visible-state revision')
assert_equal(visible['overview'],coordinator.view_snapshot(good))
coordinator.changed(good)
assert_equal(nil,coordinator.view_snapshot(good),'Pending fresh state exposed a stale overview')
coordinator.tick
assert_equal(nil,coordinator.view_snapshot(good),'Active work exposed a stale overview')
coordinator.tick
refresh.call(good)
assert_equal(first,coordinator.view_revision(good),'Unchanged state woke the form')
visible['overview']['results']['results']<<{'winner'=>'owner'}
refresh.call(good)
assert(coordinator.view_revision(good)>first,'A new result did not wake the form')
visible={}
second=coordinator.view_revision(good)
refresh.call(good)
assert_equal(second,coordinator.view_revision(good),'Empty work changed the view')
visible={'completed'=>true}
refresh.call(good)
assert(coordinator.view_revision(good)>second,'Completion did not wake the form')
T::ServerCoordination::LIMIT.times do |index|
  refresh.call({'author'=>'owner','publication_key'=>"bounded-#{index}"})
end
assert_equal(nil,coordinator.view_revision(good),'Old view cache was not bounded')
coordinator.close
assert_equal({},coordinator.instance_variable_get(:@view_revisions))
assert_equal({},coordinator.instance_variable_get(:@view_values))

puts 'PASS tournament isolation: invalid/programming failures stay visible; one-shot and startup network failures retry with bounded backoff'
