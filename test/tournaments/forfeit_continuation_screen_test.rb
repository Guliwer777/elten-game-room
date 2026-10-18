require_relative '../support/tournament_native'
require_relative '../support/tournament_entry_context'
require_relative '../../lib/tournaments/server_forfeit_screen'
require_relative '../../lib/tournaments/interrupted_outcome'
T = GameRoomTournaments
GameRoomLocalization.boot(settings: {'interface_language'=>'en', 'known_languages'=>['en']})
preview = T::InterruptedOutcome.build(units: %w[alice bob carol], loser: 'bob', started: true,
  checkpoint: {'status'=>'none'}, continuation: {'status'=>'continue'}, event_count: 1)

[false, true].each do |confirm|
  program = TournamentEntryContextTest::Program.new
  driver = TournamentNativeDriver.new
  driver.step('Forfeit consequences') do |form|
    text = form.fields.first.text
    assert(text.include?('Bob is eliminated by forfeit. The remaining participants continue playing.'),
      'The native dialog did not explain continuation')
    assert(!text.include?('tournament points:'), 'The continuation preview invented a terminal ranking')
    target = form.fields.grep(Button).find { |button| button.label == (confirm ? 'Confirm forfeit' : 'Cancel') }
    assert(target, 'The native continuation dialog has no confirmation/cancellation control')
    target.press
  end
  result = T::ServerForfeitScreen::Confirmation.new(program: program, preview: preview, names: {'bob'=>'Bob'}).run
  assert(result == (confirm ? true : nil), 'The native choice returned the wrong confirmation')
  driver.finish
ensure
  program&.finalize
  program&.class&.app_runtime&.close
end
puts 'PASS native continuation confirmation: exact consequence, no fictional points, Cancel and Confirm'
