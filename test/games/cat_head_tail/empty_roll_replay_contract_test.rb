require_relative '../../support/cat_head_tail'

game = GameRoomGames::CatHeadTail.new
repository = CatHeadTailRepository.new(%w[Alice Bob])
session = {'options' => JSON.generate(game.default_options)}
empty = game.replay(session, [], repository)
['', nil, '|', '8', '8|', '8|sideways', '9', 'x', '3|plus'].each do |value|
  bad = cht_event(1, 'Alice', 'roll', value)
  after = game.replay(session, [bad], repository)
  assert(after.to_h == empty.to_h, "invalid historical roll #{value.inspect} changed Cat, head, tail")
  good = cht_event(2, 'Alice', 'roll', '3')
  assert(game.replay(session, [bad, good], repository).to_h ==
    game.replay(session, [good], repository).to_h, 'invalid roll blocked the next valid roll')
end
puts 'Cat, head, tail: missing/malformed historical rolls are inert; the next valid roll is preserved'
