require_relative '../support/saved_game_preparation_contract'

[:before, :after].each do |timing|
  [false, true].each do |private_table|
    app, broker, saved = SavedPreparationContract.fixture(private_table: private_table)
    writes = SavedPreparationContract.role_failure(app, timing)
    first = app.send(:create_saved_game_table, saved)
    retained = app.lobby.current_table_for('Alice')
    assert(first.nil? && retained, "Unconfirmed role preparation did not leave a recoverable native room (#{timing}, private=#{private_table}, errors=#{app.errors.map(&:message).inspect}, notices=#{app.notices.inspect})")
    assert(app.notices.grep(Array).empty?, 'Players were invited before the archive owner role was confirmed')
    first_role = app.lobby.snapshot_for(retained, force: true).observer?('Alice')
    assert(first_role == (timing == :after), 'Fault was injected on the wrong side of the native role write')
    recovered = app.send(:create_saved_game_table, saved)
    assert(recovered && recovered['__id'] == retained['__id'], 'Retry created or returned a different continuation')
    assert(app.lobby.snapshot_for(recovered, force: true).observer?('Alice'),
      'Explicit retry skipped the unfinished native observer-role preparation')
    assert(writes.length == (timing == :before ? 2 : 1), 'Retry repeated an already accepted role write')
    assert(app.activation_calls == [retained['__id']], 'Retry repeated a confirmed transport activation')
    assert(app.notices.grep(Array).map(&:first) == %w[Bob Carol], 'Retry did not invite each original player once')
    snapshot = SavedPreparationContract.core_state(broker, recovered)
    assert(app.send(:create_saved_game_table, saved)['__id'] == recovered['__id'], 'Completed table was not reusable')
    assert(SavedPreparationContract.core_state(broker, recovered) == snapshot &&
      app.notices.grep(Array).map(&:first) == %w[Bob Carol], 'Completed retry rewrote native state or resent invitations')
    SavedPreparationContract.unchanged_archive(app, saved)
    app.lobby.close_table(recovered)
  end
end

app, broker, saved = SavedPreparationContract.fixture
app.activation_failure = :before
assert(app.send(:create_saved_game_table, saved).nil?, 'Activation failure was not surfaced')
retained = app.lobby.current_table_for('Alice')
assert(retained && app.notices.grep(Array).empty?, 'Activation failure invited players or discarded the native room')
recovered = app.send(:create_saved_game_table, saved)
assert(recovered && app.activation_calls == [retained['__id'], retained['__id']],
  'Retry did not repeat only the unconfirmed activation')
assert(app.lobby.snapshot_for(recovered).observer?('Alice') && app.notices.grep(Array).map(&:first) == %w[Bob Carol],
  'Activation retry did not finish the role and invitations')
SavedPreparationContract.unchanged_archive(app, saved)
app.lobby.close_table(recovered)

puts 'Saved continuation role preparation: before/after ACK, private/public rooms, activation failure and completed retry OK'
