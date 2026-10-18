require_relative '../support/saved_game_preparation_contract'

app, broker, saved = SavedPreparationContract.fixture
app.notification_failure = 'Carol'
first = app.send(:create_saved_game_table, saved)
retained = app.lobby.current_table_for('Alice')
assert(first.nil? && retained && app.errors.any? { |error| error.message == 'Invitation not confirmed' },
  'Incomplete invitations were reported as completed preparation')
assert(app.notices.grep(Array).map(&:first) == ['Bob'], 'Fault did not preserve the first confirmed invitation')
assert(app.lobby.snapshot_for(retained).observer?('Alice'), 'Invitation failure changed the confirmed archive owner role')
native_before = SavedPreparationContract.core_state(broker, retained)

# Expire the shared duplicate guard deliberately. The preparation itself still
# knows that Bob was sent an invitation and must not send him another one.
InvitationRepository::SENT_LOCK.synchronize { InvitationRepository::SENT.clear }
recovered = app.send(:create_saved_game_table, saved)
assert(recovered && recovered['__id'] == retained['__id'], 'Invitation retry switched native rooms')
assert(app.notices.grep(Array).map(&:first) == %w[Bob Carol] &&
  app.notification_attempts == %w[Bob Carol Carol], 'Retry repeated a confirmed invitation or skipped the unfinished recipient')
assert(SavedPreparationContract.core_state(broker, retained) == native_before,
  'Invitation retry rewrote a previously accepted room role')
assert(app.activation_calls == [retained['__id']], 'Invitation retry reactivated a completed stage')
SavedPreparationContract.unchanged_archive(app, saved)
app.lobby.close_table(recovered)

# The managed operation can be cancelled after delivery has returned to its
# worker but before that result reaches the caller. Record confirmation inside
# the worker so that an explicit retry still skips this recipient.
app, broker, saved = SavedPreparationContract.fixture
app.drop_confirmed_invitation_result = true
assert(app.send(:create_saved_game_table, saved).nil?, 'Cancelled task returned a completed table')
assert(app.notices.grep(Array).map(&:first) == ['Bob'], 'Cancellation did not follow the first confirmed delivery')
InvitationRepository::SENT_LOCK.synchronize { InvitationRepository::SENT.clear }
recovered = app.send(:create_saved_game_table, saved)
assert(recovered && app.notices.grep(Array).map(&:first) == %w[Bob Carol] &&
  app.notification_attempts == %w[Bob Carol], 'Cancellation repeated delivery after its confirmation')
SavedPreparationContract.unchanged_archive(app, saved)
app.lobby.close_table(recovered)

puts 'Saved continuation invitation retry preserves confirmed recipients independently of the short duplicate cache OK'
