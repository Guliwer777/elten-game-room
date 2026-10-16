require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/tournament_public_ui'
require_relative '../../lib/tournaments/public_text'
include GameRoomTest::Assertions
GameRoomLocalization.boot(settings: {'interface_language' => 'en', 'known_languages' => ['en']})
snapshot = TournamentPublicUI.snapshot
row = snapshot['announcements'].first
row = row.merge('registration_opens_at' => Time.utc(2026, 10, 10, 23, 30).to_i,
  'registration_closes_at' => Time.utc(2026, 10, 11, 1, 30).to_i)
[['+02:00', '2026-10-11 01:30:00 +02:00', '2026-10-11 03:30:00 +02:00'],
 ['-05:00', '2026-10-10 18:30:00 -05:00', '2026-10-10 20:30:00 -05:00']].each do |offset, opens, closes|
  view = GameRoomTournaments::PublicText.new(registry: GameRoomGames::CATALOG, mode_label: 'Local test', actor: 'Alpha',
    local_time: ->(seconds) { Time.at(seconds).getlocal(offset) }).description(row, snapshot)
  assert(view.include?(opens) && view.include?(closes), view)
  assert(!view.include?('Registration opens (UTC)'), view)
end
puts 'PASS registration display: same instants, different player offsets and calendar dates'

utc = row.merge('timezone' => 'UTC', 'schedule_json' => JSON.generate({'windows' => [
  {'date' => '2026-10-10', 'start' => '23:30', 'end_date' => '2026-10-11', 'end' => '01:30'}]}))
original = utc['schedule_json'].dup
[['+02:00', '2026-10-11 01:30 +02:00 to 2026-10-11 03:30 +02:00'],
 ['-05:00', '2026-10-10 18:30 -05:00 to 2026-10-10 20:30 -05:00']].each do |offset, expected|
  view = GameRoomTournaments::PublicText.new(registry: GameRoomGames::CATALOG, mode_label: 'Local test', actor: 'Alpha',
    local_time: ->(seconds) { Time.at(seconds).getlocal(offset) }).description(utc, snapshot)
  assert(view.include?(expected), view)
  assert(!view.include?('no time zone conversion'), view)
end
assert_equal(original, utc['schedule_json'])
puts 'PASS UTC playing windows: viewer-local dates and offsets without changing publication'
