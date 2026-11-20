# frozen_string_literal: true

require "net/http"
require "uri"

module Nightshift
  # Machine-level concerns for long unattended runs: keep the model server alive, notify.
  module Machine
    module_function

    # true if +url+ answers 2xx (or no URL is configured).
    def healthy?(url, timeout: 10)
      return true if url.to_s.empty?

      uri = URI(url)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                     open_timeout: timeout, read_timeout: timeout) do |http|
        http.get(uri.request_uri)
      end
      response.code.start_with?("2")
    rescue StandardError
      false
    end

    # Run a user-supplied notifier, e.g. ["curl", "-s", "-d", "{body}", "https://ntfy.sh/<topic>"].
    def notify(cmd, title, body)
      return if Array(cmd).empty?

      argv = cmd.map { |part| part.gsub("{title}", title).gsub("{body}", body) }
      Exec.run(argv, cwd: Dir.pwd, timeout_s: 60, stdout: File::NULL, stderr: File::NULL)
    rescue StandardError
      nil
    end

    # Watches an OpenAI-compatible model server and restarts it if it dies overnight.
    class Server
      def initialize(cfg, log)
        @url = cfg.fetch("health_url", "")
        @start_cmd = Array(cfg["start_cmd"])
        @grace_s = Float(cfg.fetch("down_grace_min", 10)) * 60
        @every_s = Float(cfg.fetch("check_every_s", 15))
        @log = log
        @waiter = nil # thread waiting on the server process we started
      end

      # true once the server is healthy; starts it if configured; false after the grace period.
      def ensure_up
        return true if Machine.healthy?(@url)

        @log.call("server", msg: "model server not healthy at #{@url}")
        start if !@start_cmd.empty? && !@waiter&.alive?
        deadline = Util.monotonic + @grace_s
        while Util.monotonic < deadline
          sleep @every_s
          if Machine.healthy?(@url)
            @log.call("server", msg: "model server healthy again")
            return true
          end
        end
        false
      end

      private

      def start
        @log.call("server", msg: "starting model server: #{@start_cmd.join(' ')}")
        exe = Exec.resolve(@start_cmd.first)
        group = WINDOWS ? { new_pgroup: true } : { pgroup: true }
        pid = Process.spawn([exe, exe], *@start_cmd.drop(1), out: File::NULL, err: File::NULL, **group)
        @waiter = Process.detach(pid)
      end
    end
  end
end
