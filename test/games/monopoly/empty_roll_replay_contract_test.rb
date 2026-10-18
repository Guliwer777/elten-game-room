require_relative '../../support/cat_head_tail'
require_relative '../../../games/monopoly'

game = GameRoomGames::Monopoly.new
repository = CatHeadTailRepository.new(%w[Alice Bob])
session = {'options' => JSON.generate(game.default_options)}
empty = game.replay(session, [], repository)
['', nil, '1', ',', '1,', '1,2', '1,2,', 'x,2,1', '7,2,1', '1,2,bad'].each do |value|
  bad = cht_event(1, 'Alice', 'roll', value)
  after = game.replay(session, [bad], repository)
  assert(after.to_h == empty.to_h, "invalid historical roll #{value.inspect} changed Monopoly")
  good = cht_event(2, 'Alice', 'roll', '1,2,1')
  assert(game.replay(session, [bad, good], repository).to_h ==
    game.replay(session, [good], repository).to_h, 'invalid roll blocked the next valid roll')
end
puts 'Monopoly: missing/malformed historical rolls are inert; the next valid roll is preserved'
