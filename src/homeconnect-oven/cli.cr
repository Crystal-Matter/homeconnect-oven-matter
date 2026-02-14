class HomeconnectOven::CLI
  Log = ::Log.for("homeconnect_oven.cli")

  private struct Config
    property ip : String
    property psk64 : String
    property identity : String
    property cipher : String
    property device_xml_path : String
    property feature_xml_path : String
    property storage_file : String
    property poll_interval_seconds : Int32
    property? debug_frames : Bool
    property log_level : String

    def initialize
      @ip = ENV["HC_OVEN_IP"]? || DEFAULT_IP
      @psk64 = ENV["HC_PSK64"]? || ""
      @identity = ENV["HC_IDENTITY"]? || DEFAULT_IDENTITY
      @cipher = ENV["HC_CIPHER"]? || DEFAULT_CIPHER
      @device_xml_path = ENV["HC_DEVICE_XML"]? || DEFAULT_DEVICE_XML
      @feature_xml_path = ENV["HC_FEATURE_XML"]? || DEFAULT_FEATURE_XML
      @storage_file = ENV["MATTER_STORAGE_FILE"]? || DEFAULT_STORAGE_FILE
      @poll_interval_seconds = ENV["HC_POLL_INTERVAL"]?.try(&.to_i?) || 5
      @debug_frames = false
      @log_level = ENV["LOG_LEVEL"]? || "info"
    end
  end

  DEFAULT_IP           = "192.168.4.79"
  DEFAULT_IDENTITY     = "homeconnect"
  DEFAULT_CIPHER       = "PSK"
  DEFAULT_DEVICE_XML   = "./certs/383070390240000940_DeviceDescription.xml"
  DEFAULT_FEATURE_XML  = "./certs/383070390240000940_FeatureMapping.xml"
  DEFAULT_STORAGE_FILE = HomeconnectOven::Matter::STORAGE_FILE_DEFAULT

  def self.run : Nil
    config = Config.new

    OptionParser.parse do |opts|
      opts.banner = "Usage: homeconnect-oven-matter [options]"
      opts.on("--ip=IP", "Oven IP address (default #{config.ip})") { |value| config.ip = value }
      opts.on("--psk64=KEY", "HomeConnect PSK key (required)") { |value| config.psk64 = value }
      opts.on("--identity=ID", "PSK identity (default #{config.identity})") { |value| config.identity = value }
      opts.on("--cipher=CIPHER", "TLS1.2 PSK cipher (default #{config.cipher})") { |value| config.cipher = value }
      opts.on("--device-xml=PATH", "Path to DeviceDescription.xml") { |value| config.device_xml_path = value }
      opts.on("--feature-xml=PATH", "Path to FeatureMapping.xml") { |value| config.feature_xml_path = value }
      opts.on("--storage=PATH", "Matter persistence storage path (default #{config.storage_file})") { |value| config.storage_file = value }
      opts.on("--poll-interval=SECONDS", "Status poll interval in seconds (default #{config.poll_interval_seconds})") do |value|
        parsed = value.to_i?
        raise OptionParser::InvalidOption.new("--poll-interval must be a positive integer") unless parsed && parsed > 0
        config.poll_interval_seconds = parsed
      end
      opts.on("--debug-frames", "Enable HomeConnect websocket frame logging") { config.debug_frames = true }
      opts.on("--log-level=LEVEL", "Log level: debug|info|warn|error (default #{config.log_level})") { |value| config.log_level = value.downcase }
      opts.on("-h", "--help", "Show help") do
        puts opts
        exit 0
      end
    end

    if config.psk64.empty?
      STDERR.puts "--psk64 is required (or set HC_PSK64)"
      exit 2
    end

    configure_logging(config.log_level)
    Log.info do
      "starting service ip=#{config.ip} identity=#{config.identity} cipher=#{config.cipher} " \
      "poll_interval=#{config.poll_interval_seconds}s storage=#{config.storage_file} " \
      "device_xml=#{config.device_xml_path} feature_xml=#{config.feature_xml_path} " \
      "debug_frames=#{config.debug_frames?}"
    end

    controller = HomeconnectOven::Controller.new(
      ip: config.ip,
      psk64: config.psk64,
      identity: config.identity,
      cipher: config.cipher,
      device_xml_path: config.device_xml_path,
      feature_xml_path: config.feature_xml_path,
      debug_frames: config.debug_frames?
    )

    device = HomeconnectOven::Matter.new(
      controller: controller,
      storage_file: config.storage_file,
      poll_interval: config.poll_interval_seconds.seconds,
      port: 0
    )

    Process.on_terminate do
      device.shutdown!
    end

    device.start
    device.await_shutdown
  end

  private def self.configure_logging(log_level : String) : Nil
    severity = case log_level
               when "debug" then ::Log::Severity::Debug
               when "warn"  then ::Log::Severity::Warn
               when "error" then ::Log::Severity::Error
               else
                 ::Log::Severity::Info
               end

    backend = ::Log::IOBackend.new
    ::Log.setup(severity, backend)
  end
end
