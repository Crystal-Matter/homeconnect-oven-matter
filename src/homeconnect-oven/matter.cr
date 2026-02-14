class HomeconnectOven::Matter < ::Matter::Device::Base
  Log = ::Log.for("homeconnect_oven.matter")

  DEVICE_NAME = "HomeConnect Oven"

  STORAGE_FILE_DEFAULT = "data/homeconnect_oven_matter_storage.json"

  VENDOR_ID      = ::Matter::SetupPayload.test_vendor_id
  PRODUCT_ID     =     0x0F01_u16
  DISCRIMINATOR  =     0x0F01_u16
  SETUP_PIN_CODE = 20_202_021_u32

  ENDPOINT_MICROWAVE    = 1_u16
  ENDPOINT_PREHEAT      = 2_u16
  ENDPOINT_CAVITY_TEMP  = 3_u16
  ENDPOINT_DOOR_STATE   = 4_u16
  ENDPOINT_OPERATION    = 5_u16
  ENDPOINT_POWER        = 6_u16
  ENDPOINT_PAUSE_RESUME = 7_u16

  LEVEL_MIN =   1_u8
  LEVEL_MAX = 254_u8

  DEFAULT_MICROWAVE_SECONDS =  60
  DEFAULT_PREHEAT_CELSIUS   = 180
  DEFAULT_POLL_INTERVAL     = 5.seconds
  CONNECT_RETRY_DELAY       = 5.seconds

  @controller : HomeconnectOven::Controller::Control
  @storage_file : String
  @poll_interval : Time::Span
  @running : Atomic(Bool) = Atomic(Bool).new(false)
  @controller_connected : Atomic(Bool) = Atomic(Bool).new(false)
  @suppress_callbacks : Atomic(Bool) = Atomic(Bool).new(false)
  @snapshot : HomeconnectOven::Controller::Snapshot? = nil
  @snapshot_lock : Mutex = Mutex.new
  @microwave_seconds_target : Int32 = DEFAULT_MICROWAVE_SECONDS
  @preheat_celsius_target : Int32 = DEFAULT_PREHEAT_CELSIUS

  @microwave_on_off : ::Matter::Cluster::OnOffCluster? = nil
  @microwave_level : ::Matter::Cluster::LevelControlCluster? = nil
  @preheat_on_off : ::Matter::Cluster::OnOffCluster? = nil
  @preheat_level : ::Matter::Cluster::LevelControlCluster? = nil
  @cavity_temp : ::Matter::Cluster::TemperatureMeasurementCluster? = nil
  @door_contact : ::Matter::Cluster::BooleanStateCluster? = nil
  @operation_contact : ::Matter::Cluster::BooleanStateCluster? = nil
  @power_button : ::Matter::Cluster::OnOffCluster? = nil
  @pause_resume_button : ::Matter::Cluster::OnOffCluster? = nil

  def initialize(
    @controller : HomeconnectOven::Controller::Control,
    @storage_file : String = STORAGE_FILE_DEFAULT,
    @poll_interval : Time::Span = DEFAULT_POLL_INTERVAL,
    ip_addresses : Array(Socket::IPAddress)? = nil,
    port : Int32 = 0,
  )
    super(ip_addresses: ip_addresses, port: port)
  end

  def device_name : String
    DEVICE_NAME
  end

  def vendor_id : UInt16
    VENDOR_ID
  end

  def product_id : UInt16
    PRODUCT_ID
  end

  def discriminator : UInt16
    DISCRIMINATOR
  end

  def setup_pin : UInt32
    SETUP_PIN_CODE
  end

  def primary_device_type_id : UInt16
    ::Matter::DeviceTypes::CONTROL_BRIDGE
  end

  def vendor_name : String
    "HomeConnect Local"
  end

  def product_name : String
    DEVICE_NAME
  end

  def microwave_on_off_cluster : ::Matter::Cluster::OnOffCluster
    @microwave_on_off.as(::Matter::Cluster::OnOffCluster)
  end

  def microwave_level_cluster : ::Matter::Cluster::LevelControlCluster
    @microwave_level.as(::Matter::Cluster::LevelControlCluster)
  end

  def preheat_level_cluster : ::Matter::Cluster::LevelControlCluster
    @preheat_level.as(::Matter::Cluster::LevelControlCluster)
  end

  def preheat_on_off_cluster : ::Matter::Cluster::OnOffCluster
    @preheat_on_off.as(::Matter::Cluster::OnOffCluster)
  end

  def cavity_temperature_cluster : ::Matter::Cluster::TemperatureMeasurementCluster
    @cavity_temp.as(::Matter::Cluster::TemperatureMeasurementCluster)
  end

  def door_contact_cluster : ::Matter::Cluster::BooleanStateCluster
    @door_contact.as(::Matter::Cluster::BooleanStateCluster)
  end

  def operation_contact_cluster : ::Matter::Cluster::BooleanStateCluster
    @operation_contact.as(::Matter::Cluster::BooleanStateCluster)
  end

  def power_button_cluster : ::Matter::Cluster::OnOffCluster
    @power_button.as(::Matter::Cluster::OnOffCluster)
  end

  def pause_resume_button_cluster : ::Matter::Cluster::OnOffCluster
    @pause_resume_button.as(::Matter::Cluster::OnOffCluster)
  end

  def sync_status_from_oven(refresh : Bool = true, raise_on_error : Bool = false) : Nil
    started_at = Time.instant
    Log.debug { "sync status start refresh=#{refresh}" }
    previous_snapshot = current_snapshot
    snapshot = @controller.status_snapshot(refresh: refresh)
    set_snapshot(snapshot)
    operation_just_closed = operation_became_inactive?(previous_snapshot, snapshot)

    with_suppressed_callbacks do
      if temp = snapshot.cavity_temperature_celsius
        cavity_temperature_cluster.update_temperature((temp * 100).to_i16)
      else
        cavity_temperature_cluster.update_temperature(nil)
      end

      # BooleanState contact sensors represent open=true, closed=false.
      # Invert oven booleans so HomeKit UI matches expected labels.
      door_contact_cluster.update_state(!snapshot.door_open?)
      operation_contact_cluster.update_state(!snapshot.operation_active?)
      power_button_cluster.on = snapshot.power_on?
      pause_resume_button_cluster.on = snapshot.operation_running?
      reset_action_controls_for_inactive_operation if operation_just_closed
    end

    elapsed_ms = (Time.instant - started_at).total_milliseconds.round(1)
    Log.debug do
      "sync status complete in #{elapsed_ms}ms " \
      "door_open=#{snapshot.door_open?} op_state=#{snapshot.operation_state.inspect} " \
      "temp_c=#{snapshot.cavity_temperature_celsius.inspect}"
    end
  rescue ex
    if raise_on_error
      raise ex
    else
      Log.warn(exception: ex) { "status sync failed" }
    end
  end

  protected def build_storage_manager : ::Matter::Storage::Manager
    directory = File.dirname(@storage_file)
    FileUtils.mkdir_p(directory) unless directory.empty?
    ::Matter::Storage::Manager.new(::Matter::Storage::JsonFileBackend.new(@storage_file))
  end

  protected def endpoint_device_types : Hash(UInt16, UInt32)
    {
      ENDPOINT_MICROWAVE    => ::Matter::DeviceTypes::DIMMABLE_LIGHT.to_u32,
      ENDPOINT_PREHEAT      => ::Matter::DeviceTypes::DIMMABLE_LIGHT.to_u32,
      ENDPOINT_CAVITY_TEMP  => ::Matter::DeviceTypes::TEMPERATURE_SENSOR.to_u32,
      ENDPOINT_DOOR_STATE   => ::Matter::DeviceTypes::CONTACT_SENSOR.to_u32,
      ENDPOINT_OPERATION    => ::Matter::DeviceTypes::CONTACT_SENSOR.to_u32,
      ENDPOINT_POWER        => ::Matter::DeviceTypes::ON_OFF_LIGHT_SWITCH.to_u32,
      ENDPOINT_PAUSE_RESUME => ::Matter::DeviceTypes::ON_OFF_LIGHT_SWITCH.to_u32,
    } of UInt16 => UInt32
  end

  protected def device_clusters : Array(::Matter::Cluster::Base)
    clusters = [] of ::Matter::Cluster::Base

    microwave_endpoint = ::Matter::DataType::EndpointNumber.new(ENDPOINT_MICROWAVE)
    @microwave_on_off = ::Matter::Cluster::OnOffCluster.new(
      microwave_endpoint,
      feature_map: ::Matter::Cluster::OnOffCluster::Feature::Lighting
    )
    @microwave_level = ::Matter::Cluster::LevelControlCluster.new(
      microwave_endpoint,
      current_level: percent_to_level(DEFAULT_MICROWAVE_SECONDS),
      min_level: LEVEL_MIN,
      max_level: LEVEL_MAX,
      feature_map: ::Matter::Cluster::LevelControlCluster::Feature::OnOff |
                   ::Matter::Cluster::LevelControlCluster::Feature::Lighting
    )
    microwave_on_off_cluster.on_state_changed { |state| handle_microwave_on_off(state) }
    microwave_level_cluster.on_level_changed { |_old_level, new_level| handle_microwave_level_change(new_level) }
    clusters.concat(
      [
        microwave_on_off_cluster.as(::Matter::Cluster::Base),
        microwave_level_cluster.as(::Matter::Cluster::Base),
        identify_cluster(microwave_endpoint).as(::Matter::Cluster::Base),
        label_cluster(microwave_endpoint, "Microwave Timer").as(::Matter::Cluster::Base),
      ]
    )

    preheat_endpoint = ::Matter::DataType::EndpointNumber.new(ENDPOINT_PREHEAT)
    @preheat_on_off = ::Matter::Cluster::OnOffCluster.new(
      preheat_endpoint,
      feature_map: ::Matter::Cluster::OnOffCluster::Feature::Lighting
    )
    @preheat_level = ::Matter::Cluster::LevelControlCluster.new(
      preheat_endpoint,
      current_level: percent_to_level((DEFAULT_PREHEAT_CELSIUS - 100).clamp(0, 100)),
      min_level: LEVEL_MIN,
      max_level: LEVEL_MAX,
      feature_map: ::Matter::Cluster::LevelControlCluster::Feature::OnOff |
                   ::Matter::Cluster::LevelControlCluster::Feature::Lighting
    )
    preheat_on_off_cluster.on_state_changed { |state| handle_preheat_on_off(state) }
    preheat_level_cluster.on_level_changed { |_old_level, new_level| handle_preheat_level_change(new_level) }
    clusters.concat(
      [
        preheat_on_off_cluster.as(::Matter::Cluster::Base),
        preheat_level_cluster.as(::Matter::Cluster::Base),
        identify_cluster(preheat_endpoint).as(::Matter::Cluster::Base),
        label_cluster(preheat_endpoint, "Preheat Temperature").as(::Matter::Cluster::Base),
      ]
    )

    cavity_endpoint = ::Matter::DataType::EndpointNumber.new(ENDPOINT_CAVITY_TEMP)
    @cavity_temp = ::Matter::Cluster::TemperatureMeasurementCluster.new(
      cavity_endpoint,
      measured_value: nil,
      min_measured_value: 0_i16,
      max_measured_value: 30_000_i16,
      tolerance: 50_u16
    )
    clusters.concat(
      [
        cavity_temperature_cluster.as(::Matter::Cluster::Base),
        identify_cluster(cavity_endpoint).as(::Matter::Cluster::Base),
        label_cluster(cavity_endpoint, "Cavity Temperature").as(::Matter::Cluster::Base),
      ]
    )

    door_endpoint = ::Matter::DataType::EndpointNumber.new(ENDPOINT_DOOR_STATE)
    @door_contact = ::Matter::Cluster::BooleanStateCluster.new(door_endpoint, state_value: false)
    clusters.concat(
      [
        door_contact_cluster.as(::Matter::Cluster::Base),
        identify_cluster(door_endpoint).as(::Matter::Cluster::Base),
        label_cluster(door_endpoint, "Door State").as(::Matter::Cluster::Base),
      ]
    )

    operation_endpoint = ::Matter::DataType::EndpointNumber.new(ENDPOINT_OPERATION)
    @operation_contact = ::Matter::Cluster::BooleanStateCluster.new(operation_endpoint, state_value: false)
    clusters.concat(
      [
        operation_contact_cluster.as(::Matter::Cluster::Base),
        identify_cluster(operation_endpoint).as(::Matter::Cluster::Base),
        label_cluster(operation_endpoint, "Operation State").as(::Matter::Cluster::Base),
      ]
    )

    power_endpoint = ::Matter::DataType::EndpointNumber.new(ENDPOINT_POWER)
    @power_button = ::Matter::Cluster::OnOffCluster.new(power_endpoint)
    power_button_cluster.on_state_changed { |state| handle_power_button(state) }
    clusters.concat(
      [
        power_button_cluster.as(::Matter::Cluster::Base),
        identify_cluster(power_endpoint).as(::Matter::Cluster::Base),
        label_cluster(power_endpoint, "Power").as(::Matter::Cluster::Base),
      ]
    )

    pause_endpoint = ::Matter::DataType::EndpointNumber.new(ENDPOINT_PAUSE_RESUME)
    @pause_resume_button = ::Matter::Cluster::OnOffCluster.new(pause_endpoint)
    pause_resume_button_cluster.on_state_changed { |state| handle_pause_resume_button(state) }
    clusters.concat(
      [
        pause_resume_button_cluster.as(::Matter::Cluster::Base),
        identify_cluster(pause_endpoint).as(::Matter::Cluster::Base),
        label_cluster(pause_endpoint, "Pause / Resume").as(::Matter::Cluster::Base),
      ]
    )

    clusters
  end

  protected def before_start : Nil
    started_at = Time.instant
    interfaces = ip_addresses.map { |ip| "#{ip.address}(#{ip.family == Socket::Family::INET ? "v4" : "v6"})" }.join(", ")
    Log.info { "before_start: mdns interfaces=#{interfaces}" }
    Log.info { "before_start: deferring oven connection until device start" }
    elapsed_ms = (Time.instant - started_at).total_milliseconds.round(1)
    Log.info { "before_start complete in #{elapsed_ms}ms; Matter UDP port=#{port}" }
    Log.info { "using ephemeral Matter UDP port #{port}" }
  end

  protected def started_commissioning_mode : Nil
    Log.info { "device entered commissioning mode" }
    puts "Starting in Commissioning Mode"
    puts "The device is ready to be paired with a Matter controller."
    puts ""
    puts "mDNS Advertisement Active:"
    puts "  Service: _matterc._udp.local"
    puts "  Instance: #{responder.commissioning_instance_name || "<pending>"}"
    puts "  Hostname: #{hostname}"
    puts "  Port: #{port}"
    puts "  Discriminator: #{discriminator}"
    puts ""

    print_qr_code

    manual_code = setup_code
    puts "QR payload: #{qr_code_payload}"
    puts "Setup PIN: #{setup_pin}"
    puts "Manual pairing code: #{manual_code}"
    puts "chip-tool pairing command:"
    puts "  chip-tool pairing code 1 #{manual_code}"
    puts ""
  end

  protected def started_operational_mode : Nil
    Log.info { "device entered operational mode fabrics=#{fabric_table.size}" }
    puts "Starting in Operational Mode"
    puts "The device is commissioned and ready for use."
    puts ""

    fabric_table.all_fabrics.each do |fabric|
      puts "Operational Advertisement (Fabric #{fabric.fabric_index}):"
      puts "  Service: _matter._tcp.local"
      puts "  Fabric ID: 0x#{fabric.fabric_id.to_s(16).upcase}"
      puts "  Node ID: 0x#{fabric.node_id.to_s(16).upcase}"
      puts ""
    end
  end

  protected def on_started : Nil
    Log.info { "on_started: starting polling loop interval=#{@poll_interval.total_seconds}s" }
    @running.set(true)
    spawn { poll_loop }
  end

  protected def on_shutdown : Nil
    Log.info { "on_shutdown: stopping polling loop and closing controller" }
    @running.set(false)
    if @controller_connected.get
      @controller.close
      @controller_connected.set(false)
    end
    Log.info { "on_shutdown complete" }
  rescue ex
    Log.warn(exception: ex) { "controller close failed" }
  end

  private def poll_loop : Nil
    Log.info { "poll loop started" }
    waiting_for_commissioning = false

    while @running.get
      begin
        if fabric_table.empty?
          unless waiting_for_commissioning
            Log.info { "poll loop: waiting for commissioning before oven sync/connect" }
            waiting_for_commissioning = true
          end

          if @controller_connected.get
            begin
              @controller.close
            rescue
            end
            @controller_connected.set(false)
          end

          sleep @poll_interval
          next
        end

        if waiting_for_commissioning
          Log.info { "poll loop: commissioning complete; enabling oven sync/connect" }
          waiting_for_commissioning = false
        end

        unless @controller_connected.get
          Log.info { "poll loop: connecting to oven" }
          @controller.connect
          @controller_connected.set(true)
          Log.info { "poll loop: oven connected" }
        end

        Log.debug { "poll tick: syncing status from oven" }
        sync_status_from_oven(refresh: true, raise_on_error: true)
        sleep @poll_interval
      rescue ex
        Log.warn(exception: ex) { "poll loop: oven sync/connect failed; retrying in #{CONNECT_RETRY_DELAY.total_seconds}s" }
        if @controller_connected.get
          begin
            @controller.close
          rescue
          end
          @controller_connected.set(false)
        end
        sleep CONNECT_RETRY_DELAY
      end
    end
    Log.info { "poll loop exited" }
  end

  protected def default_ip_addresses : Array(Socket::IPAddress)
    ips = [] of Socket::IPAddress

    begin
      socket = UDPSocket.new(:inet6)
      socket.connect("2606:4700:4700::1111", 53)
      addr = socket.local_address
      socket.close
      ips << Socket::IPAddress.new(addr.address, 0)
    rescue
    end

    begin
      socket = UDPSocket.new(:inet)
      socket.connect("8.8.8.8", 80)
      addr = socket.local_address
      socket.close
      ips << Socket::IPAddress.new(addr.address, 0)
    rescue
    end

    ips << Socket::IPAddress.new("127.0.0.1", 0) if ips.empty?
    ips
  end

  private def handle_microwave_on_off(state : Bool) : Nil
    return if @suppress_callbacks.get
    return @controller.stop unless state

    if level_to_percent(microwave_level_cluster.current_level) <= 0
      # Treat 0% (level 1) as an inactive command slot so the user can re-arm later.
      with_suppressed_callbacks { microwave_on_off_cluster.on = false }
      return
    end
    seconds = @microwave_seconds_target
    @controller.microwave(seconds)
  rescue ex
    Log.warn(exception: ex) { "microwave action failed" }
  end

  private def handle_microwave_level_change(level : UInt8) : Nil
    return if @suppress_callbacks.get

    percent = level_to_percent(level)
    if percent <= 0
      @microwave_seconds_target = 1
      return
    end

    seconds = percent.clamp(1, 100)
    @microwave_seconds_target = seconds
    return unless microwave_on_off_cluster.on?

    @controller.microwave(seconds)
  rescue ex
    Log.warn(exception: ex) { "microwave level action failed" }
  end

  private def handle_preheat_level_change(level : UInt8) : Nil
    return if @suppress_callbacks.get

    percent = level_to_percent(level)
    if percent <= 0
      @preheat_celsius_target = 100
      with_suppressed_callbacks { preheat_on_off_cluster.on = false } if preheat_on_off_cluster.on?
      return
    end

    temperature = 100 + percent
    @preheat_celsius_target = temperature
    return unless preheat_on_off_cluster.on?

    @controller.preheat(temperature)
  rescue ex
    Log.warn(exception: ex) { "preheat action failed" }
  end

  private def handle_preheat_on_off(state : Bool) : Nil
    return if @suppress_callbacks.get
    return @controller.stop unless state

    if level_to_percent(preheat_level_cluster.current_level) <= 0
      with_suppressed_callbacks { preheat_on_off_cluster.on = false }
      return
    end

    @controller.preheat(@preheat_celsius_target)
  rescue ex
    Log.warn(exception: ex) { "preheat on/off action failed" }
  end

  private def handle_power_button(state : Bool) : Nil
    return if @suppress_callbacks.get

    @controller.power(state)
  rescue ex
    Log.warn(exception: ex) { "power action failed" }
  end

  private def handle_pause_resume_button(state : Bool) : Nil
    return if @suppress_callbacks.get

    snapshot = current_snapshot
    return unless snapshot

    if state
      @controller.resume if snapshot.operation_paused?
    elsif snapshot.operation_running?
      @controller.pause
    end
  rescue ex
    Log.warn(exception: ex) { "pause/resume action failed" }
  end

  private def with_suppressed_callbacks(& : -> Nil) : Nil
    @suppress_callbacks.set(true)
    yield
  ensure
    @suppress_callbacks.set(false)
  end

  private def set_snapshot(snapshot : HomeconnectOven::Controller::Snapshot) : Nil
    @snapshot_lock.synchronize do
      @snapshot = snapshot
    end
  end

  private def current_snapshot : HomeconnectOven::Controller::Snapshot?
    @snapshot_lock.synchronize do
      @snapshot
    end
  end

  private def operation_became_inactive?(
    previous_snapshot : HomeconnectOven::Controller::Snapshot?,
    current_snapshot : HomeconnectOven::Controller::Snapshot,
  ) : Bool
    return !current_snapshot.operation_active? unless previous_snapshot
    previous_snapshot.operation_active? && !current_snapshot.operation_active?
  end

  private def reset_action_controls_for_inactive_operation : Nil
    @microwave_seconds_target = 1
    @preheat_celsius_target = 100
    microwave_on_off_cluster.on = false
    preheat_on_off_cluster.on = false
    microwave_level_cluster.level = LEVEL_MIN
    preheat_level_cluster.level = LEVEL_MIN
  end

  private def identify_cluster(endpoint : ::Matter::DataType::EndpointNumber) : ::Matter::Cluster::IdentifyCluster
    ::Matter::Cluster::IdentifyCluster.new(
      endpoint,
      identify_type: ::Matter::Cluster::IdentifyCluster::IdentifyType::VisibleLight
    )
  end

  private def label_cluster(endpoint : ::Matter::DataType::EndpointNumber, label : String) : ::Matter::Cluster::FixedLabelCluster
    ::Matter::Cluster::FixedLabelCluster.new(
      endpoint,
      [::Matter::Cluster::LabelStruct.new("name", label)]
    )
  end

  private def setup_code : String
    ::Matter::SetupPayload.generate_manual_code(discriminator, setup_pin)
  end

  private def qr_code_payload : String
    ::Matter::SetupPayload::QRCode.generate_qr_code(
      discriminator: discriminator,
      pin: setup_pin,
      vendor_id: vendor_id,
      product_id: product_id,
      flow: ::Matter::SetupPayload::QRCode::CommissionFlow::Standard,
      capabilities: ::Matter::SetupPayload::QRCode::DiscoveryCapability::BLE
    )
  end

  private def print_qr_code : Nil
    payload = qr_code_payload
    qr = Goban::QR.encode_string(payload, Goban::ECC::Level::Low)
    puts "Scan this QR code with your Matter controller app:"
    puts ""
    qr.print_to_console
    puts ""
  rescue ex
    puts "Failed to generate QR code: #{ex.message}"
  end

  private def level_to_percent(level : UInt8) : Int32
    clamped_level = level.clamp(LEVEL_MIN, LEVEL_MAX).to_i
    level_span = LEVEL_MAX.to_i - LEVEL_MIN.to_i
    offset = clamped_level - LEVEL_MIN.to_i
    ((offset * 100) + (level_span // 2)) // level_span
  end

  private def percent_to_level(percent : Int32) : UInt8
    clamped_percent = percent.clamp(0, 100)
    level_span = LEVEL_MAX.to_i - LEVEL_MIN.to_i
    (LEVEL_MIN.to_i + (((clamped_percent * level_span) + 50) // 100)).to_u8
  end
end
