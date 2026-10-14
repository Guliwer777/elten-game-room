require_relative '../../lib/tournaments/tournament_lifecycle'
T = GameRoomTournaments::TournamentLifecycle
first = Time.utc(2026, 10, 15, 12).to_i
last = Time.utc(2026, 10, 15, 14).to_i
row = {'timezone' => 'UTC', 'registration_opens_at' => first-7200, 'registration_closes_at' => first-3600,
  'schedule_json' => JSON.generate({'windows' => [{'date'=>'2026-10-15','start'=>'12:00','end_date'=>'2026-10-15','end'=>'14:00'}]})}
checks = [[first-7201,:soon],[first-7200,:registration],[first-3600,:waiting],[first,:running],[last-1,:running],[last,:ended]]
checks.each { |at, state| raise "Wrong boundary #{state}" unless T.classify(row, now: at) == {state:state, archived:false} }
raise 'Ended tournament archived' unless T.classify(row,now:last+5*86400)=={state: :ended,archived:false}
raise 'Guessed unknown zone' unless T.classify(row.merge('timezone'=>'Europe/Warsaw'), now:last+5*86400) == {state: :unknown, archived: false}
raise 'Incorrect end sorting time' unless T.ending_at(row)==last
completed=row.merge('sporting_completed'=>true,'sporting_completed_at'=>first+120)
raise 'Early completion stayed running' unless T.classify(completed,now:first+121)=={state: :completed,archived:false}
raise 'Early completion sorted by planned end' unless T.ending_at(completed)==first+120
raise 'Completed tournament kept future timers' unless T.next_change(completed,now:first+121).nil?
puts 'PASS tournament lifecycle: exact registration/start/end boundaries, ended retained without archive, sortable end timestamp'
