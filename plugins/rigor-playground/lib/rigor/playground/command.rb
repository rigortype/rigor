# frozen_string_literal: true

require "rigor/playground/app"

module Rigor
  module CLI
    class PlaygroundCommand
      DEFAULT_PORT = 9393

      def initialize(argv, out, err)
        @argv = argv
        @out  = out
        @err  = err
        @port = DEFAULT_PORT
        @open_browser = true
      end

      def run
        parse_opts
        start_server
        0
      rescue StandardError => e
        @err.puts "rigor playground: #{e.message}"
        1
      end

      private

      def parse_opts
        @argv.each do |arg|
          case arg
          when /\A--port=(\d+)\z/ then @port = Regexp.last_match(1).to_i
          when "--no-open"        then @open_browser = false
          end
        end
      end

      def start_server
        require "rack"
        require "puma"
        require "puma/configuration"
        require "puma/launcher"

        app = Rigor::Playground::App.new
        @out.puts "Rigor playground running at http://localhost:#{@port}"
        open_browser if @open_browser

        conf = Puma::Configuration.new do |c|
          c.bind "tcp://127.0.0.1:#{@port}"
          c.app app
          c.quiet
        end
        launcher = Puma::Launcher.new(conf)
        launcher.run
      end

      def open_browser
        url = "http://localhost:#{@port}"
        case RbConfig::CONFIG["host_os"]
        when /darwin/ then system("open", url, exception: false)
        when /linux/  then system("xdg-open", url, exception: false)
        when /mswin|mingw/ then system("start", url, exception: false)
        end
      end
    end
  end
end
