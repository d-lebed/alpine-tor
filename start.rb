#!/usr/bin/env ruby
require 'erb'
require 'socksify/http'
require 'logger'

$logger = Logger.new(STDOUT, ENV['DEBUG'] ? Logger::DEBUG : Logger::INFO)

module Service
  class Base
    attr_reader :port

    def initialize(port)
      @port = port
    end

    def service_name
      self.class.name.downcase.split('::').last
    end

    def start
      ensure_directories
      $logger.info "starting #{service_name} on port #{port}"
    end

    def ensure_directories
      %w{lib run log}.each do |dir|
        path = "/var/#{dir}/#{service_name}"
        Dir.mkdir(path) unless Dir.exists?(path)
      end
    end

    def data_directory
      "/var/lib/#{service_name}"
    end

    def pid_file
      "/var/run/#{service_name}/#{port}.pid"
    end

    def executable
      self.class.which(service_name)
    end

    def stop
      $logger.info "stopping #{service_name} on port #{port}"
      if File.exists?(pid_file)
        pid = File.read(pid_file).strip
        begin
          self.class.kill(pid.to_i)
        rescue => e
          $logger.warn "couldn't kill #{service_name} on port #{port}: #{e.message}"
        end
      else
        $logger.info "#{service_name} on port #{port} was not running"
      end
    end

    def self.kill(pid, signal='SIGINT')
      Process.kill(signal, pid)
    end

    def self.fire_and_forget(*args)
      $logger.debug "running: #{args.join(' ')}"
      pid = Process.fork
      if pid.nil? then
        # In child
        exec args.join(" ")
      else
        # In parent
        Process.detach(pid)
      end
    end

    def self.which(executable)
      path = `which #{executable}`.strip
      if path == ""
        return nil
      else
        return path
      end
    end
  end


  class Tor < Base
    attr_reader :new_circuit_period
    attr_reader :max_circuit_dirtiness
    attr_reader :circuit_build_timeout
    attr_reader :bridges

    def initialize(port)
      @config_erb_path = "/usr/local/etc/torrc.erb"
      @port = port
      @new_circuit_period = ENV['new_circuit_period'] || 120
      @max_circuit_dirtiness = ENV['max_circuit_dirtiness'] || 600
      @circuit_build_timeout = ENV['circuit_build_timeout'] || 60
      @bridges = ENV.has_key?('tor_bridges') ? ENV['tor_bridges'].split(';') : []
    end

    def data_directory
      "#{super}/#{port}"
    end

    def config_path
      "#{data_directory}-torrc"
    end

    def start
      super
      compile_config
      self.class.fire_and_forget(executable,
                                 "-f #{config_path}",
                                 "| logger -t 'tor#{port}' 2>&1")
    end

    private
    def compile_config
      File.write(config_path, ERB.new(File.read(@config_erb_path)).result(binding))
    end
  end

  class Proxy
    attr_reader :id
    attr_reader :tor

    def initialize(id)
      @id = id
      @tor = Tor.new(tor_port)
    end

    def start
      $logger.info "starting proxy id #{id}"
      @tor.start
    end

    def stop
      $logger.info "stopping proxy id #{id}"
      @tor.stop
    end

    def restart
      #stop
      sleep 5
      $logger.info "@todo new circle"
      #start
    end

    def tor_port
      10000 + id
    end

    alias_method :port, :tor_port

    def test_url
      ENV['test_url'] || 'http://google.com'
    end

    def test_status
      ENV['test_status'] || '302'
    end

    def working?
      uri = URI.parse(test_url)
      $logger.info uri
      Net::HTTP.SOCKSProxy('127.0.0.1', port).start(uri.host, uri.port) do |http|
        http.get(uri.path).code==test_status
      end
    end
    #rescue
    #  $logger.info "Err working? "
    #  false
    #end
  end

  class Haproxy < Base
    attr_reader :backends
    attr_reader :stats
    attr_reader :login
    attr_reader :pass

    def initialize()
      @config_erb_path = "/usr/local/etc/haproxy.cfg.erb"
      @config_path = "/usr/local/etc/haproxy.cfg"
      @backends = []
      @stats = ENV['haproxy_stats'] || 2090
      @login = ENV['haproxy_login'] || 'admin'
      @pass = ENV['haproxy_pass'] || 'admin'
      @port = ENV['haproxy_port'] || 5566
    end

    def start
      super
      compile_config
      self.class.fire_and_forget(executable,
                                 "-f #{@config_path}",
                                 "| logger 2>&1")
    end

    def soft_reload
      self.class.fire_and_forget(executable,
                                 "-f #{@config_path}",
                                 "-p #{pid_file}",
                                 "-sf #{File.read(pid_file)}",
                                 "| logger 2>&1")
    end

    def add_backend(backend)
      @backends << {:name => 'tor', :addr => '127.0.0.1', :port => backend.port}
    end

    private
    def compile_config
      File.write(@config_path, ERB.new(File.read(@config_erb_path)).result(binding))
    end
  end

  class Privoxy < Base
    attr_reader :haproxy
    attr_reader :permit
    attr_reader :deny

    def initialize()
      @config_erb_path = "/usr/local/etc/privoxy.cfg.erb"
      @config_path = "/usr/local/etc/privoxy.cfg"
      @port = ENV['privoxy_port'] || 8118
      @haproxy = ENV['haproxy_port'] || 5566
      @permit = ENV['privoxy_permit'] || ""
      @pdeny = ENV['privoxy_deny'] || ""

      @onions = {
        "8408" => "hydramarketsnjmd",
        "8418" => "hydraruzxpnew4af",
        "8428" => "hydra2exghh3rnmc",
        "8438" => "hydra3rudf3j4hww",
        "8448" => "hydra4jpwhfx4mst",
        "8458" => "hydra5etioavaz7p",
        "8468" => "hydra6c2bnrd6phf"
      }
    end

    def start
      super
      compile_config
      self.class.fire_and_forget(executable, "--no-daemon", "#{@config_path}")

      @onions.each do |k,v|
        self.class.fire_and_forget("socat -d tcp4-LISTEN:#{k},reuseaddr,fork,keepalive,bind=0.0.0.0 SOCKS4A:127.0.0.1:#{v}.onion:80,socksport=5566")
      end

      ##self.class.fire_and_forget("curl -v -x 'http://127.0.0.1:8448' -v -O https://1.1.1.1")
    end

    private
    def compile_config
      File.write(@config_path, ERB.new(File.read(@config_erb_path)).result(binding))
    end
  end

end


haproxy = Service::Haproxy.new
proxies = []

tor_instances = ENV['tors'] || 20
tor_instances.to_i.times.each do |id|
  proxy = Service::Proxy.new(id)
  haproxy.add_backend(proxy)
  proxy.start
  proxies << proxy
end

haproxy.start

if ENV['privoxy']
  privoxy = Service::Privoxy.new
  privoxy.start
end

first_wait = ENV['first_wait'] || 60
sleep first_wait

loop do
  begin
    sleep 60
  rescue Exception => e
    puts "E"
  end

  #$logger.info "testing proxies looop"
  #proxies.each do |proxy|

    #SOME_ONION_URI = URI.parse(test_url)
    #query = Net::HTTP::Get.new(test_url)
    #query["Host"]            = test_url
    #query["User-Agent"]      = "Mozilla/5.0 (Windows NT 6.1; rv:52.0) Gecko/20100101 Firefox/52.0"
    #query["Accept"]          = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
    #query["Accept-Language"] = "en-US,en;q=0.5"
    #sleep 5

    #response = Net::HTTP.SOCKSProxy('127.0.0.1', 9050).start(SOME_ONION_URI.host, SOME_ONION_URI.port) do |http|
    #  http.request(query)
    #end

    #$logger.info "sleeping for #{tor_instances} seconds"
    #sleep Integer(tor_instances)
    #sleep 60
  #end


end
