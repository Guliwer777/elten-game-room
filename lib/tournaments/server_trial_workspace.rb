# encoding: UTF-8
require_relative 'server_workspace'
module GameRoomTournaments
  # Source-only developer adapter; the player installer does not load it.
  class ServerTrialWorkspace < ServerWorkspace
    APP_UUID='5e914c62-0fae-4fb1-a36c-544b299513ea'.freeze
    IDENTITY="elten-server-trial:#{APP_UUID}".freeze
    class Provider < ServerWorkspace::Provider
      def initialize;super(app_uuid:APP_UUID);end
    end
    def initialize(**options)
      super(**options,backend_uuid:APP_UUID,backend_identity:IDENTITY)
    end
    def experimental_ui?;true;end
    def mode_label
      super
    end
  end
end
