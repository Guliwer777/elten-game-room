require_relative '../support/settings_widget'
assert(!EltenGameRoom.respond_to?(:tournament_pending_invitations),'A tournament-specific invitation inbox is active')
assert(!EltenGameRoom.respond_to?(:tournament_proposals_tick),'A tournament proposal timer is active')
assert(!EltenGameRoom.new.respond_to?(:accept_tournament_invitation),'A removed tournament acceptance path is active')
assert(EltenGameRoom.respond_to?(:tournament_starts_tick),'Tournament start notifications lost their lifecycle')
puts 'PASS only the ordinary invitation inbox remains; tournament start notifications retain their runtime'
