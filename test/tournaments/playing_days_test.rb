require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/assertions'
require_relative '../../lib/tournaments/playing_days'
include GameRoomTest::Assertions
T=GameRoomTournaments
captured=[]
converter=->(date,time) do
  captured << [date,time]
  offset=date<'2026-10-25' ? 7200 : 3600
  T::LocalRegistrationTime.convert_utc(date,time)-offset
end
windows=T::PlayingDays.build(mode:'daily',first_date:'2026-10-24',last_date:'2026-10-26',opens:'19:00',closes:'21:00',converter:converter)
assert_equal(3,windows.size)
assert_equal(%w[17:00 18:00 18:00],windows.map{|window|window['start']})
assert_equal(%w[19:00 20:00 20:00],windows.map{|window|window['end']})
assert_equal(6,captured.size,'Daily schedule reused a fixed UTC offset across daylight saving')
single=T::PlayingDays.build(mode:'single',first_date:'2026-10-16',last_date:'2026-10-18',opens:'19:00',closes:'21:00',converter:T::LocalRegistrationTime.method(:convert_utc))
assert_equal(1,single.size)
assert_equal('2026-10-16',single.first['end_date'])
assert_equal(:invalid_playing_hours,assert_raises(T::Publication::Invalid){T::PlayingDays.build(mode:'single',first_date:'2026-10-16',last_date:'2026-10-16',opens:'21:00',closes:'19:00')}.code)
assert_raises(T::Publication::Invalid){T::PlayingDays.build(mode:'daily',first_date:'2026-10-18',last_date:'2026-10-16',opens:'19:00',closes:'21:00')}
assert_raises(T::Publication::Invalid){T::PlayingDays.build(mode:'daily',first_date:'2026-02-30',last_date:'2026-03-01',opens:'19:00',closes:'21:00')}
intervals=[16,17,18].map{|day|[Time.local(2026,10,day,19),Time.local(2026,10,day,21)]}
assert_equal('daily',T::PlayingDays.mode(intervals))
assert_equal('single',T::PlayingDays.mode(intervals.take(1)))
assert_equal('preserve',T::PlayingDays.mode([intervals.first,intervals.last]))
assert_equal('preserve',T::PlayingDays.mode([[Time.local(2026,10,16,19),Time.local(2026,10,18,21)]]))
puts 'PASS playing days: inclusive date range, one-day schedule, separate civil-time conversion across DST, invalid dates/hours and preservation of legacy irregular windows'
