defmodule AutoNuke.Operator.ControlRodsTest do
  use ExUnit.Case, async: false

  alias AutoNuke.Operator.ControlRods
  alias AutoNuke.Smoother
  alias AutoNuke.Test.MockAPI

  # Callbacks are driven directly in the test process so MockAPI's
  # per-process mocks apply without alias gymnastics.

  @tick AutoNuke.Operator.assigned_tick(ControlRods)

  setup do
    start_supervised!(PubSub)

    # Isolated persistent settings per test:
    File.mkdir_p!("tmp")
    File.rm(Application.get_env(:auto_nuke, :settings_file))

    # Three installed banks at 40%, six empty slots.
    for bank <- 0..2, do: MockAPI.mock_get("ROD_BANK_POS_#{bank}_ACTUAL", 40.0, times: :any)
    for bank <- 3..8, do: MockAPI.mock_get("ROD_BANK_POS_#{bank}_ACTUAL", "null", times: :any)

    # Boron present -> the high-gain PID profile (worst case for hunting).
    MockAPI.mock_get("CHEM_BORON_PPM", 3000.0, times: :any)

    :ok
  end

  defp init(core_temp, target) do
    set_temp(core_temp, 2)
    {:ok, state} = ControlRods.init({target, :direct})
    state
  end

  defp tick(state) do
    {:noreply, state} = ControlRods.handle_info({:tick, @tick}, state)
    state
  end

  # The verified-read loop consumes exactly ONE reading when the value
  # matches the previous tick's, and TWO when it changed; `times: :any`
  # would shadow later changes, so counts must be exact.
  defp set_temp(temp, reads) do
    MockAPI.mock_get("CORE_TEMP", temp, times: reads)
  end

  defp refute_rod_commands do
    for bank <- 0..2 do
      assert_raise RuntimeError, ~r/not received/, fn ->
        MockAPI.mock_put_value("ROD_BANK_POS_#{bank}_ORDERED")
      end
    end
  end

  test "on-target ticks issue no rod commands" do
    state = init(340.0, 340.0)
    set_temp(340.0, 1)
    state = tick(state)
    set_temp(340.0, 1)
    tick(state)

    refute_rod_commands()
  end

  test "small jitter inside the calm zone is held, not commanded" do
    state = init(340.0, 340.0)
    set_temp(340.0, 1)
    state = tick(state)

    # ±0.1°C of measurement noise — under the old behaviour this issued a
    # fractional rod move every tick.
    set_temp(339.9, 2)
    state = tick(state)
    set_temp(340.1, 2)
    tick(state)

    refute_rod_commands()
  end

  test "a real deviation still commands the rods immediately" do
    state = init(340.0, 340.0)
    set_temp(340.0, 1)
    state = tick(state)

    # 3°C low — far outside the calm zone.
    set_temp(337.0, 2)
    tick(state)

    # A withdrawal order was issued (fewer % than the 40% start):
    assert MockAPI.mock_put_value("ROD_BANK_POS_0_ORDERED") < 40.0
  end

  test "with anti-hunting off, calm-zone jitter commands the rods again" do
    AutoNuke.Settings.put(ControlRods.anti_hunting_setting(), false)

    state = init(340.0, 340.0)
    assert state.anti_hunting == false

    set_temp(340.0, 1)
    state = tick(state)

    set_temp(339.9, 2)
    tick(state)

    # The same jitter the gated tests hold back now issues a command:
    assert is_number(MockAPI.mock_put_value("ROD_BANK_POS_0_ORDERED"))
  end

  test "toggling anti-hunting persists across a restart" do
    state = init(340.0, 340.0)
    assert state.anti_hunting == true

    {:reply, :ok, state} = ControlRods.handle_call({:set_anti_hunting, false}, nil, state)
    assert state.anti_hunting == false

    # A fresh init (as after a VM restart) reads the persisted value:
    state = init(340.0, 340.0)
    assert state.anti_hunting == false
  end

  test "sub-degree target changes are ignored; real ones accepted" do
    state = init(340.0, 340.0)

    {:noreply, state} = ControlRods.handle_info({:core_temp, 340.05}, state)
    assert state.target == 340.0

    {:noreply, state} = ControlRods.handle_info({:core_temp, 340.9}, state)
    assert state.target == 340.0

    {:noreply, state} = ControlRods.handle_info({:core_temp, 341.2}, state)
    assert state.target == 341.2
  end

  describe "select_measurement/4" do
    # Ten readings climbing 1°C a tick, ending at 339.
    defp rising_history do
      Enum.reduce(330..339, Smoother.new(10), &Smoother.add(&2, &1 * 1.0))
    end

    test "direct always uses the plain reading" do
      assert ControlRods.select_measurement(:direct, 345.0, 339.0, rising_history()) == 339.0
    end

    test "predictive always uses the look-ahead" do
      predicted = Smoother.extrapolate(rising_history(), 5)

      assert ControlRods.select_measurement(:predictive, 340.0, 339.0, rising_history()) ==
               predicted

      assert predicted > 339.0
    end

    test "hybrid predicts while far from target" do
      predicted = Smoother.extrapolate(rising_history(), 5)

      assert ControlRods.select_measurement(:hybrid, 345.0, 339.0, rising_history()) == predicted
      assert ControlRods.select_measurement(:hybrid, 330.0, 339.0, rising_history()) == predicted
    end

    test "hybrid reads directly once within 3°C of target, boundary included" do
      assert ControlRods.select_measurement(:hybrid, 340.0, 339.0, rising_history()) == 339.0
      assert ControlRods.select_measurement(:hybrid, 342.0, 339.0, rising_history()) == 339.0
      assert ControlRods.select_measurement(:hybrid, 336.0, 339.0, rising_history()) == 339.0
    end
  end

  test "hybrid is an accepted mode" do
    set_temp(340.0, 2)
    assert {:ok, %{mode: :hybrid}} = ControlRods.init({340.0, :hybrid})

    state = init(340.0, 340.0)

    assert {:reply, :ok, %{mode: :hybrid}} =
             ControlRods.handle_call({:set_mode, :hybrid}, {self(), make_ref()}, state)
  end
end
