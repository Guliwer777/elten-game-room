require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/tournament_public_ui'
require_relative '../../lib/tournaments/tournament_retention'
include GameRoomTest::Assertions
T=GameRoomTournaments
D=86_400

def row(start:0,opening:100)
  publication=TournamentPublicUI.publication(11,**{'windows'=>[],'starts_at'=>0,'deadline_at'=>0})
  schedule=JSON.parse(publication.fetch('schedule_json')).merge('starts_at'=>start)
  publication.merge('__insertion_time'=>100,'registration_opens_at'=>opening,'registration_closes_at'=>0,
    'schedule_json'=>JSON.generate(schedule))
end
def history(publication=row,events:[])
  {publication:publication,events:events}
end
def status(value,now,**options)
  T::TournamentRetention.evaluate(value,now:now,**options)
end

assert(!status(history,100+14*D-1)[:expired])
assert(status(history,100+14*D)[:expired])
renewed=history(events:[{time:100+13*D,id:1}])
assert_equal(100+27*D,status(renewed,100+14*D)[:expires_at])
assert(status(renewed,100+27*D)[:expired])
late=history(events:[{time:100+14*D,id:1,publication:row(start:100+14*D)}])
assert(status(late,100+15*D)[:expired],'Late start resurrected an expired tournament')
scheduled=history(row(start:100+60*D))
assert(!status(scheduled,100+59*D)[:expired],'Future scheduled start was expired early')
assert_equal(100+90*D,status(scheduled,100+60*D)[:expires_at])
assert(status(scheduled,100+90*D)[:expired])
assert(!status(history(row(opening:100+60*D)),100+59*D)[:expired])

started=history(row(start:100))
assert(status(started,100+30*D)[:expired])
assert(!status(started,100+30*D,progress:[100+29*D])[:expired])
assert_equal(100+59*D,status(started,100+30*D,progress:[100+29*D])[:expires_at])
assert(status(started,100+61*D,progress:[100+29*D,100+60*D])[:expired],'Post-expiry result revived the tournament')
assert(status(started,100+31*D,completed_at:100+30*D)[:expired])
assert_equal({expired:false,completed:true,expires_at:nil},status(started,100+999*D,completed_at:100+29*D))
assert(status(started,100+31*D,progress:[100+90*D])[:expired],'Future timestamp renewed the tournament')

original=row
join=TournamentPublicUI.registration(7,time:100+13*D)
duplicate=join.merge('__id'=>8,'__insertion_time'=>100+26*D)
unauthorized=join.merge('__id'=>9,'__insertion_user'=>'Intruder','kind'=>'amendment')
model=T::RegistrationProjection.build(announcements:[original],registrations:[join,duplicate,unauthorized],registry:GameRoomGames::CATALOG,complete:true)
assert_equal([100+13*D],model.retention_history(11)[:events].map{|event|event[:time]},'Duplicates or invalid records renewed activity')
assert(status(model.retention_history(11),100+27*D)[:expired])
retained=model.with_retained_announcements([])
assert(retained.instance_of?(T::RegistrationProjection) && retained.frozen?)
assert_equal([],retained.to_h['announcements'])
assert_equal([],retained.to_h['members'])
assert_equal(model.to_h['diagnostics'],retained.to_h['diagnostics'])
assert_equal(1,model.to_h['announcements'].size,'Retention mutated the original projection')
puts 'PASS retention: 14/30 days, boundary, renewal, no resurrection, future schedule, completed results, duplicate/unauthorized evidence and immutable projections'
