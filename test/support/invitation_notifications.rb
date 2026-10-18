require_relative "../../lib/invitation_notifications"

def assert(condition, message)
  raise message if !condition
end

Notification = Struct.new(:id, :app_uuid, :revoked, :payload, :type, :metadata, keyword_init: true)

class FakeNotificationGateway
  attr_reader :listed, :revoked, :revoked_many

  def initialize(notifications)
    @notifications = notifications
    @listed = []
    @revoked = []
    @revoked_many = []
  end

  def list(client, all:, app_uuids:)
    @listed << [client, all, app_uuids]
    @notifications
  end

  def revoke(client, id)
    @revoked << [client, id]
    true
  end

  def revoke_many(client, ids)
    @revoked_many << [client, ids]
    true
  end
end

require_relative "ui"

class Program
  def self.server_app(**_options); end
  def self.server_app_uuid; "468f59c5-c9d7-47cd-80f1-1a6fbfd1aa80"; end
end

module Session
  def self.name
    "Alice"
  end
end

require_relative "../../__app"

# Notification entry runs after the host has published its startup preferences.
EltenGameRoom.remember_settings(EltenGameRoom::DEFAULT_SETTINGS)
