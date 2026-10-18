require_relative '../support/assertions'
require_relative '../../lib/tournaments/game_result'
include GameRoomTest::Assertions

planned = [
  {'account'=>'alice', 'team'=>'red'}, {'account'=>'bob', 'team'=>'red'},
  {'account'=>'carol', 'team'=>'blue'}, {'account'=>'dave', 'team'=>'blue'}
]
native = {'team:1'=>%w[CAROL Dave], 'team:0'=>%w[Alice BOB]}
before = Marshal.dump([planned, native])
assert_equal({'team:1'=>'blue', 'team:0'=>'red'},
  GameRoomTournaments::GameResult.unit_mapping(units: native, players: planned))
assert_equal(before, Marshal.dump([planned, native]), 'Mapping modified the original fixture or native roster')

[
  {'one'=>%w[Alice], 'two'=>%w[Carol Dave]},
  {'one'=>%w[Alice Bob], 'two'=>%w[Carol Dave Eve]},
  {'one'=>%w[Alice Carol], 'two'=>%w[Bob Dave]},
  {'one'=>%w[Alice Alice Bob], 'two'=>%w[Carol Dave]},
  {'one'=>%w[Alice Bob], 'two'=>%w[Carol Dave], 'three'=>%w[Alice Bob]},
  {'one'=>%w[Alice Bob]},
  {'one'=>%w[Alice Bob], 'two'=>[]}
].each do |units|
  error = assert_raises(GameRoomTournaments::Publication::Invalid) do
    GameRoomTournaments::GameResult.unit_mapping(units: units, players: planned)
  end
  assert_equal(:invalid_game_result, error.code)
end

individuals = planned.map { |person| person.merge('team'=>nil) }
assert_equal({'Alice'=>'alice', 'Bob'=>'bob', 'Carol'=>'carol', 'Dave'=>'dave'},
  GameRoomTournaments::GameResult.unit_mapping(
    units: %w[Alice Bob Carol Dave].to_h { |name| [name, [name]] }, players: individuals))
puts 'PASS one complete native roster per planned unit: case-insensitive identities, individual units, no partial/merged/duplicated teams or input mutation'
