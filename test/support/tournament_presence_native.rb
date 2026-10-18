require_relative 'tournament_forfeit_native'

module TournamentPresenceNative
  module_function

  def runner(fixture, user, clock)
    runner_for(fixture.h, user).tap do |runner|
      runner.instance_variable_set(:@tournament_presence, fixture.services.fetch(user).method(:presence_context))
      runner.define_singleton_method(:tournament_observation_time) { clock.first }
      runner.instance_variable_get(:@sync).instance_variable_set(:@clock, -> { clock.first })
    end
  end

  def snapshot(h, user = 'Alice')
    h.as(user) { h.repositories.fetch(user).snapshot_for(h.session) }
  end

  def presence(h, user = 'Alice')
    snapshot(h, user).session.fetch('__tournament_presence')
  end

  def observer(fixture, name = 'Observer')
    h = fixture.h
    h.add_client(name)
    assert(h.join(name))
    h.as(name) { h.transports.fetch(name).set_observer(h.table, true, actor: name) }
    fixture.services[name] = fixture.make_service(name)
    h.as(name) { assert(fixture.services.fetch(name).attach_table(h.table)) }
    native = h.view('Alice')
    native.transfer_ownership(native.participants.find { |entry| entry.user == name })
    name
  end
end
