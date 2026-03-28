class HomeconnectOven::Controller
  Log = ::Log.for("homeconnect_oven.controller")

  STATUS_OPERATION_STATE = "BSH.Common.Status.OperationState"
  STATUS_DOOR_STATE      = "BSH.Common.Status.DoorState"
  STATUS_CAVITY_TEMP     = "Cooking.Oven.Status.Cavity.001.CurrentTemperature"
  SETTING_POWER          = "BSH.Common.Setting.PowerState"

  MICROWAVE_PROGRAM           = "Cooking.Oven.Program.Microwave.Max"
  PREHEAT_PROGRAM             = "Cooking.Oven.Program.HeatingMode.PreHeating"
  OPTION_DURATION             = "BSH.Common.Option.Duration"
  OPTION_SETPOINT_TEMPERATURE = "Cooking.Oven.Option.SetpointTemperature"
  COMMAND_PAUSE               = "BSH.Common.Command.PauseProgram"
  COMMAND_RESUME              = "BSH.Common.Command.ResumeProgram"
  COMMAND_STOP                = "BSH.Common.Command.AbortProgram"

  struct Snapshot
    INACTIVE_TOKENS = {
      "inactive",
      "ready",
      "finished",
      "standby",
      "off",
    }

    ACTIVE_TOKENS = {
      "run",
      "heat",
      "progress",
      "active",
    }

    getter operation_state : String
    getter door_state : String
    getter cavity_temperature_celsius : Int32?
    getter? door_open : Bool
    getter? power_on : Bool

    def initialize(
      @operation_state : String,
      @door_state : String,
      @cavity_temperature_celsius : Int32?,
      @door_open : Bool,
      @power_on : Bool,
    )
    end

    def operation_paused? : Bool
      label = @operation_state.downcase
      label.includes?("pause")
    end

    def operation_running? : Bool
      return false if operation_paused?

      label = @operation_state.downcase
      return false if label.empty?
      return false if includes_any?(label, INACTIVE_TOKENS)

      includes_any?(label, ACTIVE_TOKENS)
    end

    def operation_active? : Bool
      operation_running? || operation_paused?
    end

    private def includes_any?(value : String, tokens : Enumerable(String)) : Bool
      tokens.any? { |token| value.includes?(token) }
    end
  end

  module Control
    abstract def connect : Nil
    abstract def close : Nil
    abstract def status_snapshot(refresh : Bool = true) : Snapshot
    abstract def microwave(seconds : Int32) : Nil
    abstract def preheat(celsius : Int32) : Nil
    abstract def pause : Nil
    abstract def resume : Nil
    abstract def stop : Nil
    abstract def power(target_on : Bool) : Nil
  end

  include Control

  @description : HomeconnectLocal::DeviceDescription
  @client : HomeconnectLocal::Client
  @name_to_desc : Hash(String, HomeconnectLocal::EntityDesc)
  @entities_by_uid : Hash(Int32, HomeconnectLocal::Entity)
  @values_by_uid : Hash(Int32, JSON::Any)
  @mutex : Mutex = Mutex.new
  @connected : Bool = false

  def initialize(
    ip : String,
    psk64 : String,
    identity : String,
    cipher : String,
    device_xml_path : String,
    feature_xml_path : String,
    debug_frames : Bool = false,
  )
    device_xml = File.read(device_xml_path)
    feature_xml = File.read(feature_xml_path)
    @description = HomeconnectLocal::Parser.parse_device_description(device_xml, feature_xml)

    @client = HomeconnectLocal::Client.new(
      host: ip,
      psk64: psk64,
      mode: HomeconnectLocal::TransportMode::TLS_PSK,
      psk_identity: identity,
      tls_cipher: cipher,
      app_name: "homeconnect-oven-matter"
    )
    @client.debug_frames = debug_frames
    @client.keepalive_status_from_description = @description

    @name_to_desc = {} of String => HomeconnectLocal::EntityDesc
    @entities_by_uid = {} of Int32 => HomeconnectLocal::Entity
    @values_by_uid = {} of Int32 => JSON::Any

    register_all_entities
  end

  def connect : Nil
    @mutex.synchronize do
      return if @connected

      started_at = Time.instant
      Log.info { "connecting to oven websocket host=#{@client.host}" }
      @client.connect
      Log.info { "connected websocket host=#{@client.host}; loading description changes" }
      refresh_description_changes
      Log.info { "description changes loaded; loading mandatory values" }
      refresh_values
      @connected = true
      elapsed_ms = (Time.instant - started_at).total_milliseconds.round(1)
      Log.info { "oven client ready in #{elapsed_ms}ms" }
    end
  end

  def close : Nil
    @mutex.synchronize do
      return unless @connected

      Log.info { "closing oven websocket host=#{@client.host}" }
      @client.close
      @connected = false
      Log.info { "oven websocket closed" }
    end
  end

  def status_snapshot(refresh : Bool = true) : Snapshot
    @mutex.synchronize do
      ensure_connected!
      Log.debug { "status snapshot requested refresh=#{refresh}" }
      refresh_values if refresh

      operation_state = status_label_or_raw(STATUS_OPERATION_STATE)
      door_state = status_label_or_raw(STATUS_DOOR_STATE)
      cavity_temp = any_to_i32(value_for(STATUS_CAVITY_TEMP))
      power_on = power_on?

      Log.debug do
        "status snapshot operation=#{operation_state.inspect} door=#{door_state.inspect} " \
        "temp_c=#{cavity_temp.inspect} power_on=#{power_on}"
      end

      Snapshot.new(
        operation_state: operation_state,
        door_state: door_state,
        cavity_temperature_celsius: cavity_temp,
        door_open: infer_door_open(door_state),
        power_on: power_on
      )
    end
  end

  def microwave(seconds : Int32) : Nil
    state = status_snapshot
    @mutex.synchronize do
      ensure_connected!
      stop_internal if state.operation_active?
      duration = seconds.clamp(1, 300)
      Log.info { "microwave command duration_seconds=#{duration}" }
      options = {
        option_for(OPTION_DURATION).uid => JSON::Any.new(duration.to_i64),
      }
      program_for(MICROWAVE_PROGRAM).start(options, override_options: true)
    end
  end

  def preheat(celsius : Int32) : Nil
    state = status_snapshot
    @mutex.synchronize do
      ensure_connected!
      stop_internal if state.operation_active?
      temperature = celsius.clamp(1, 275)
      Log.info { "preheat command target_celsius=#{temperature}" }
      options = {
        option_for(OPTION_SETPOINT_TEMPERATURE).uid => JSON::Any.new(temperature.to_i64),
        option_for(OPTION_DURATION).uid             => JSON::Any.new(3600_i64),
      }
      program_for(PREHEAT_PROGRAM).start(options, override_options: true)
    end
  end

  def pause : Nil
    @mutex.synchronize do
      ensure_connected!
      Log.info { "pause command" }
      command_for(COMMAND_PAUSE).value_raw = JSON::Any.new(true)
    end
  end

  def resume : Nil
    @mutex.synchronize do
      ensure_connected!
      Log.info { "resume command" }
      command_for(COMMAND_RESUME).value_raw = JSON::Any.new(true)
    end
  end

  def stop : Nil
    @mutex.synchronize do
      ensure_connected!
      stop_internal
    end
  end

  private def stop_internal : Nil
    Log.info { "stop command" }
    command_for(COMMAND_STOP).value_raw = JSON::Any.new(true)
  end

  def power(target_on : Bool) : Nil
    @mutex.synchronize do
      ensure_connected!
      setting_desc = desc_for(SETTING_POWER)
      enum_map = setting_desc.enum_map || raise "Missing enum map for #{SETTING_POWER}"
      on_code = enum_code_for(enum_map, "On") || raise "Missing enum value 'On' for #{SETTING_POWER}"
      off_code = enum_code_for(enum_map, "Standby") || enum_map.keys.find { |k| k != on_code } || raise "No non-On value for #{SETTING_POWER}"

      current_code = any_to_i32(@values_by_uid[setting_desc.uid]?)
      current_on = current_code == on_code
      return if current_on == target_on

      target_code = target_on ? on_code : off_code
      Log.info { "power command target_on=#{target_on} target_code=#{target_code}" }
      setting_for(SETTING_POWER).value_raw = JSON::Any.new(target_code.to_i64)
      @values_by_uid[setting_desc.uid] = JSON::Any.new(target_code.to_i64)
    end
  end

  private def register_all_entities : Nil
    all = @description.status + @description.setting + @description.event + @description.command + @description.option + @description.program
    all.each do |desc|
      @name_to_desc[desc.name] = desc
      @entities_by_uid[desc.uid] = HomeconnectLocal::Entity.new(desc, @client)
    end

    if active_program = @description.active_program
      @name_to_desc[active_program.name] = active_program
      @entities_by_uid[active_program.uid] = HomeconnectLocal::Entity.new(active_program, @client)
    end

    if selected_program = @description.selected_program
      @name_to_desc[selected_program.name] = selected_program
      @entities_by_uid[selected_program.uid] = HomeconnectLocal::Entity.new(selected_program, @client)
    end
  end

  private def refresh_values : Nil
    started_at = Time.instant
    Log.debug { "requesting /ro/allMandatoryValues" }
    response = @client.send_sync(HomeconnectLocal::Message.new(resource: "/ro/allMandatoryValues", action: HomeconnectLocal::Action::GET))
    apply_payload(response.data)
    elapsed_ms = (Time.instant - started_at).total_milliseconds.round(1)
    Log.debug { "received /ro/allMandatoryValues entries=#{response.data.size} in #{elapsed_ms}ms" }
  end

  private def refresh_description_changes : Nil
    started_at = Time.instant
    Log.debug { "requesting /ro/allDescriptionChanges" }
    response = @client.send_sync(HomeconnectLocal::Message.new(resource: "/ro/allDescriptionChanges", action: HomeconnectLocal::Action::GET))
    apply_payload(response.data)
    elapsed_ms = (Time.instant - started_at).total_milliseconds.round(1)
    Log.debug { "received /ro/allDescriptionChanges entries=#{response.data.size} in #{elapsed_ms}ms" }
  end

  private def apply_payload(data : Array(JSON::Any)) : Nil
    data.each do |entry_any|
      entry = entry_any.as_h?
      next unless entry

      uid = any_to_i32(entry["uid"]?)
      next unless uid

      @entities_by_uid[uid]?.try(&.update_from_hash(entry))
      if value = entry["value"]?
        @values_by_uid[uid] = value
      end
    end
  end

  private def ensure_connected! : Nil
    raise HomeconnectLocal::NotConnected.new("Oven client is not connected") unless @connected
  end

  private def value_for(name : String) : JSON::Any?
    desc = desc_for(name)
    @values_by_uid[desc.uid]?
  end

  private def status_label_or_raw(name : String) : String
    desc = desc_for(name)
    raw = @values_by_uid[desc.uid]?
    return "" unless raw

    if enum_map = desc.enum_map
      if int_value = any_to_i32(raw)
        return enum_map[int_value]? || int_value.to_s
      end
    end

    any_to_string(raw)
  end

  private def power_on? : Bool
    setting_desc = desc_for(SETTING_POWER)
    enum_map = setting_desc.enum_map
    return false unless enum_map

    raw = @values_by_uid[setting_desc.uid]?
    code = any_to_i32(raw)
    return false unless code

    on_code = enum_code_for(enum_map, "On")
    return false unless on_code

    code == on_code
  end

  private def infer_door_open(door_state : String) : Bool
    normalized = door_state.downcase
    return true if normalized.includes?("open")
    return false if normalized.includes?("closed")
    false
  end

  private def desc_for(name : String) : HomeconnectLocal::EntityDesc
    @name_to_desc[name]? || raise "Entity not found in XML: #{name}"
  end

  private def program_for(name : String) : HomeconnectLocal::Program
    HomeconnectLocal::Program.new(desc_for(name), @client)
  end

  private def command_for(name : String) : HomeconnectLocal::Entity
    entity_for(name)
  end

  private def setting_for(name : String) : HomeconnectLocal::Entity
    entity_for(name)
  end

  private def option_for(name : String) : HomeconnectLocal::EntityDesc
    desc_for(name)
  end

  private def entity_for(name : String) : HomeconnectLocal::Entity
    desc = desc_for(name)
    @entities_by_uid[desc.uid]? || raise "Entity missing for #{name}"
  end

  private def enum_code_for(enum_map : Hash(Int32, String), label : String) : Int32?
    enum_map.find { |_, value| value.downcase == label.downcase }.try(&.[0])
  end

  private def any_to_i32(any : JSON::Any?) : Int32?
    return nil unless any

    case raw = any.raw
    when Int32
      raw
    when Int64
      return nil if raw < Int32::MIN || raw > Int32::MAX
      raw.to_i32
    when Float64
      value = raw.to_i64
      return nil if value < Int32::MIN || value > Int32::MAX
      value.to_i32
    when String
      raw.to_i32?
    else
      nil
    end
  end

  private def any_to_string(any : JSON::Any?) : String
    return "" unless any

    case raw = any.raw
    when String
      raw
    when Bool
      raw.to_s
    when Int32
      raw.to_s
    when Int64
      raw.to_s
    when Float64
      raw.to_s
    else
      any.to_json
    end
  end
end
