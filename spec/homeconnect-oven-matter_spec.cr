require "./spec_helper"

private class FakeOvenControl
  include HomeconnectOven::Controller::Control

  getter microwave_calls : Array(Int32) = [] of Int32
  getter preheat_calls : Array(Int32) = [] of Int32
  getter power_calls : Array(Bool) = [] of Bool
  getter pause_calls : Int32 = 0
  getter resume_calls : Int32 = 0
  getter stop_calls : Int32 = 0

  property snapshot : HomeconnectOven::Controller::Snapshot = HomeconnectOven::Controller::Snapshot.new(
    operation_state: "Ready",
    door_state: "Closed",
    cavity_temperature_celsius: 25,
    door_open: false,
    power_on: false
  )

  def connect : Nil
  end

  def close : Nil
  end

  def status_snapshot(refresh : Bool = true) : HomeconnectOven::Controller::Snapshot
    @snapshot
  end

  def microwave(seconds : Int32) : Nil
    @microwave_calls << seconds
  end

  def preheat(celsius : Int32) : Nil
    @preheat_calls << celsius
  end

  def pause : Nil
    @pause_calls += 1
  end

  def resume : Nil
    @resume_calls += 1
  end

  def stop : Nil
    @stop_calls += 1
  end

  def power(target_on : Bool) : Nil
    @power_calls << target_on
  end
end

private def build_device(control : FakeOvenControl, storage_file : String) : HomeconnectOven::Matter
  File.delete?(storage_file)
  HomeconnectOven::Matter.new(control, storage_file: storage_file, poll_interval: 60.seconds, port: 0)
end

describe HomeconnectOven::Matter do
  it "maps microwave endpoint commands to microwave/stop actions" do
    control = FakeOvenControl.new
    device = build_device(control, "/tmp/spec_microwave_storage.json")

    device.microwave_level_cluster.level = 254_u8
    device.microwave_on_off_cluster.on = true
    device.microwave_on_off_cluster.on = false

    control.microwave_calls.should_not be_empty
    control.microwave_calls.last.should eq(100)
    control.stop_calls.should eq(1)
  end

  it "maps preheat slider levels into the requested temperature range" do
    control = FakeOvenControl.new
    device = build_device(control, "/tmp/spec_preheat_storage.json")

    device.preheat_on_off_cluster.on = true
    device.preheat_level_cluster.level = 130_u8
    device.preheat_level_cluster.level = 254_u8

    control.preheat_calls.first.should eq(180)
    control.preheat_calls[1].should be > 100
    control.preheat_calls.last.should eq(200)
  end

  it "updates sensor/button clusters from status snapshots without feedback loops" do
    control = FakeOvenControl.new
    control.snapshot = HomeconnectOven::Controller::Snapshot.new(
      operation_state: "Run",
      door_state: "Open",
      cavity_temperature_celsius: 182,
      door_open: true,
      power_on: true
    )

    device = build_device(control, "/tmp/spec_sync_storage.json")
    device.sync_status_from_oven(refresh: false)

    device.door_contact_cluster.state_value?.should be_false
    device.operation_contact_cluster.state_value?.should be_false
    device.power_button_cluster.on?.should be_true
    device.pause_resume_button_cluster.on?.should be_true
    device.cavity_temperature_cluster.measured_value.should eq(18_200_i16)

    control.power_calls.should be_empty
    control.pause_calls.should eq(0)
    control.resume_calls.should eq(0)
  end

  it "drives pause/resume endpoint based on operation state" do
    control = FakeOvenControl.new
    device = build_device(control, "/tmp/spec_pause_storage.json")

    control.snapshot = HomeconnectOven::Controller::Snapshot.new(
      operation_state: "Pause",
      door_state: "Closed",
      cavity_temperature_celsius: 100,
      door_open: false,
      power_on: true
    )
    device.sync_status_from_oven(refresh: false)
    device.pause_resume_button_cluster.on = true

    control.snapshot = HomeconnectOven::Controller::Snapshot.new(
      operation_state: "Run",
      door_state: "Closed",
      cavity_temperature_celsius: 100,
      door_open: false,
      power_on: true
    )
    device.sync_status_from_oven(refresh: false)
    device.pause_resume_button_cluster.on = false

    control.resume_calls.should eq(1)
    control.pause_calls.should eq(1)
  end

  it "resets visual control endpoints when operation transitions inactive" do
    control = FakeOvenControl.new
    device = build_device(control, "/tmp/spec_operation_reset_storage.json")

    device.microwave_level_cluster.level = 200_u8
    device.preheat_level_cluster.level = 200_u8
    device.microwave_on_off_cluster.on = true
    device.preheat_on_off_cluster.on = true

    control.snapshot = HomeconnectOven::Controller::Snapshot.new(
      operation_state: "Run",
      door_state: "Closed",
      cavity_temperature_celsius: 100,
      door_open: false,
      power_on: true
    )
    device.sync_status_from_oven(refresh: false)

    control.snapshot = HomeconnectOven::Controller::Snapshot.new(
      operation_state: "Inactive",
      door_state: "Closed",
      cavity_temperature_celsius: 80,
      door_open: false,
      power_on: false
    )
    device.sync_status_from_oven(refresh: false)

    device.operation_contact_cluster.state_value?.should be_true
    device.microwave_on_off_cluster.on?.should be_false
    device.preheat_on_off_cluster.on?.should be_false
    device.microwave_level_cluster.current_level.should eq(1_u8)
    device.preheat_level_cluster.current_level.should eq(1_u8)
  end

  it "does not execute microwave or preheat commands at 0% slider level" do
    control = FakeOvenControl.new
    device = build_device(control, "/tmp/spec_zero_level_storage.json")

    device.preheat_level_cluster.level = 1_u8
    device.preheat_on_off_cluster.on = true
    device.microwave_level_cluster.level = 1_u8
    device.microwave_on_off_cluster.on = true

    control.preheat_calls.should be_empty
    control.microwave_calls.should be_empty
    device.microwave_on_off_cluster.on?.should be_false
  end
end
