require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/ui'
require_relative '../support/tournament_public_ui'
require_relative '../../lib/tournaments/tournament_setup_editor'
require_relative '../../lib/tournaments/local_workspace'
GameRoomLocalization.boot(settings: {'interface_language' => 'en', 'known_languages' => ['en']})
Form.prepend(TournamentPublicUI::Script)
def loop_update; Thread.pass; end
include GameRoomTest::Assertions
U = TournamentPublicUI
T = GameRoomTournaments
[[ 'farkle', 3, false ], [ 'spades', 4, true ]].each do |id, count, compatible|
  messages, published = [], []
  editor = T::TournamentSetupEditor.new(program: Object.new, registry: GameRoomGames::CATALOG,
    configure: ->(_game, options) { id == 'spades' ? options.merge('team_size'=>2) : options }, alert: ->(message) { messages << message },
    clock: -> { Time.local(2026,10,11,15,0).to_i },
    publish: ->(**values) { published << values; {'status'=>'confirmed'} })
  U.script(lambda do |form|
    game=U.field(form,'Game')
    game.index=GameRoomGames::CATALOG.ids.index(id)
    game.trigger(:select)
  end,lambda do |form|
    U.field(form, 'Tournament name').text = 'Format compatibility'
    seats = U.field(form, 'Players per match')
    seats.index = seats.options.index(count.to_s)
    assert(seats.index, 'Unsupported test match size')
    U.field(form, 'Tournament format').index = 1
    form.accept_button.trigger(:press)
    if compatible
      assert_equal(1, published.size, messages.inspect)
      assert_equal([], messages)
      assert_equal('groups_knockout', published.first[:draft]['format'])
    else
      assert_equal([], published, 'Incompatible format was published')
      assert(messages.first.include?('Choose round robin'), messages.inspect)
      U.field(form, 'Tournament format').index = 0
      form.accept_button.trigger(:press)
      assert_equal(1, published.size, 'Corrected form could not publish')
      assert_equal('round_robin', published.first[:draft]['format'])
      assert_equal(3, published.first[:draft]['players_per_match'])
    end
  end) { editor.wait }
end
puts 'PASS incompatible multiplayer groups rejected before publication; correction and fixed pairs remain available'
