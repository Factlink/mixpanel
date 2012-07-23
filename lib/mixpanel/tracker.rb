require "open-uri"
require 'base64'
require 'json'
require 'thread'
require 'mixpanel/tracker/middleware'

module Mixpanel
  class Tracker
    def initialize(token, env, async = false, url = 'http://api.mixpanel.com/')
      @token = token
      @env = env
      @async = async
      @url = url
      clear_queue
    end

    def append_event(event, properties = {})
      append_api('track', event, properties)
    end

    def append_person_event(properties = {})
      properties = parse_special_person_properties properties

      append_api('people.set', properties)
    end

    def set_person_event(distinct_id, properties = {})
      engage_event distinct_id, :set, properties
    end

    def increment_person_event(distinct_id, properties = {})
      engage_event distinct_id, :add, properties
    end

    def append_identify(id)
      append_api('identify', id)
    end

    def append_person_increment_event(property, increment=1)
      append_api('people.increment', property, increment)
    end

    def append_api(type, *args)
      queue << [type, args.map {|arg| arg.to_json}]
    end

    def track_event(event, properties = {})
      options = { :time => Time.now.utc.to_i, :ip => ip }
      options.merge!( :token => @token ) if @token
      options.merge!(properties)
      params = build_event(event, options)

      parse_response request(:track, params)
    end

    def ip
      if @env.has_key?("HTTP_X_FORWARDED_FOR")
        @env["HTTP_X_FORWARDED_FOR"].split(",").last
      elsif @env.has_key?("REMOTE_ADDR")
        @env["REMOTE_ADDR"]
      else
        ""
      end
    end

    def queue
      @env["mixpanel_events"]
    end

    def clear_queue
      @env["mixpanel_events"] = []
    end

    class <<self
      WORKER_MUTEX = Mutex.new

      def worker
        WORKER_MUTEX.synchronize do
          @worker || (@worker = IO.popen(self.cmd, 'w'))
        end
      end

      def dispose_worker(w)
        WORKER_MUTEX.synchronize do
          if(@worker == w)
            @worker = nil
            w.close
          end
        end
      end

      def cmd
        @cmd || begin
          require 'escape'
          require 'rbconfig'
          interpreter = File.join(*RbConfig::CONFIG.values_at("bindir", "ruby_install_name")) + RbConfig::CONFIG["EXEEXT"]
          subprocess  = File.join(File.dirname(__FILE__), 'tracker/subprocess.rb')
          @cmd = Escape.shell_command([interpreter, subprocess])
        end
      end
    end

    private

    def engage_event(distinct_id, type, properties = {})
      properties = parse_special_person_properties properties

      options = { :"$distinct_id" => distinct_id, :"$#{type}" => properties }
      options.merge!( :token => @token ) if @token

      parse_response request(:engage, options)
    end

    def parse_response(response)
      response == "1" ? true : false
    end

    def request(type, params)
      data = Base64.encode64(JSON.generate(params)).gsub(/\n/,'')
      url = "#{@url}#{type}/?data=#{data}"

      if(@async)
        w = Tracker.worker
        begin
          url << "\n"
          w.write(url)
        rescue Errno::EPIPE => e
          Tracker.dispose_worker(w)
        end
      else
        open(url).read
      end
    end

    def build_event(event, properties)
      {:event => event, :properties => properties}
    end

    def parse_special_person_properties(properties)
      # evaluate symbols and rewrite
      special_properties = %w{email created first_name last_name last_login username country_code}

      properties = properties.map {|p| p.to_sym}

      special_properties.each do |key|
        symbolized_key = key.to_sym
        if properties.has_key?(symbolized_key)
          properties["$#{key}"] = properties[symbolized_key]
          properties.delete(symbolized_key)
        end
      end
      properties
    end
  end
end
