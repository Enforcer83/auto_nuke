defmodule AutoNuke.Operator.BoronLevelTest do
  use ExUnit.Case, async: false

  alias AutoNuke.Operator.BoronLevel
  alias AutoNuke.Operator.BoronLevel.State
  alias AutoNuke.Test.MockAPI

  @tick AutoNuke.Operator.assigned_tick(BoronLevel)
  @dosing_key "CHEM_BORON_DOSAGE_ORDERED_RATE"
  @filter_key "CHEM_BORON_FILTER_ORDERED_SPEED"

  setup do
    File.mkdir_p!("tmp")
    File.rm(Application.get_env(:auto_nuke, :settings_file))
    :ok
  end

  # Callbacks are driven directly in the test process so MockAPI's
  # per-process mocks apply.

  defp from, do: {self(), make_ref()}

  defp panel(pumps) do
    Jason.encode!(%{"pumps" => Map.new(pumps, &{&1, %{}})})
  end

  @both ["BC_0_QUIMICA_DOSIFICADORA", "BC_0_QUIMICA_CIRCULACION_QUIMICA"]

  defp mock_pumps(pumps), do: MockAPI.mock_get("VALVE_PANEL_JSON", panel(pumps), times: :any)

  defp mock_boron(ppm), do: MockAPI.mock_get("CHEM_BORON_PPM", ppm, times: :any)

  # Filtration is reported ready (the next ready check is far away), so only
  # the pump speeds under test move.
  defp state(fields \\ []) do
    struct!(
      %State{dosing_rate: 0, filter_rate: 0, filter_ready: true, next_ready_check: 1_000_000_000},
      fields
    )
  end

  defp set(state, ppm), do: BoronLevel.handle_call({:set_concentration, ppm}, from(), state)

  defp tick(state) do
    {:noreply, state} = BoronLevel.handle_info({:tick, @tick}, state)
    state
  end

  describe "target rates" do
    test "dosing eases off as the target nears, and is capped at 50 g/min" do
      assert BoronLevel.target_dosing_rate(700.0, 1000.0) == 50
      assert BoronLevel.target_dosing_rate(900.0, 1000.0) == 34
      assert BoronLevel.target_dosing_rate(990.0, 1000.0) == 4
    end

    test "no dosing at or above the target, or within 1 ppm of it" do
      assert BoronLevel.target_dosing_rate(1000.0, 1000.0) == 0
      assert BoronLevel.target_dosing_rate(1200.0, 1000.0) == 0
      assert BoronLevel.target_dosing_rate(999.5, 1000.0) == 0
    end

    test "filtering is faster the further above the target, and capped at 100%" do
      assert BoronLevel.target_filter_rate(1010.0, 1000.0) == 10
      assert BoronLevel.target_filter_rate(1500.0, 1000.0) == 100
    end

    test "no filtering at or below the target, or within 1 ppm of it" do
      assert BoronLevel.target_filter_rate(1000.0, 1000.0) == 0
      assert BoronLevel.target_filter_rate(800.0, 1000.0) == 0
      assert BoronLevel.target_filter_rate(1000.5, 1000.0) == 0
    end
  end

  describe "set_concentration/2" do
    test "accepts a higher target when a dosing pump is installed" do
      mock_pumps(@both)
      mock_boron(2000.0)

      assert {:reply, {:ok, 3000.0}, state} = set(state(), 3000)
      assert state.target == 3000.0
    end

    test "accepts a lower target when an ion exchange pump is installed" do
      mock_pumps(@both)
      mock_boron(2000.0)

      assert {:reply, {:ok, 1000.0}, state} = set(state(), 1000)
      assert state.target == 1000.0
    end

    test "accepts both ends of the range" do
      mock_pumps(@both)
      mock_boron(2000.0)

      assert {:reply, {:ok, zero}, _} = set(state(), 0)
      assert zero == 0.0
      assert {:reply, {:ok, 3500.0}, _} = set(state(), 3500)
    end

    test "rejects targets outside the range, changing nothing" do
      mock_pumps(@both)
      mock_boron(2000.0)
      before = state()

      for ppm <- [-1, 3500.1, 9000] do
        assert {:reply, {:error, msg}, ^before} = set(before, ppm)
        assert msg =~ "0-3500"
      end
    end

    test "can't raise boron without a dosing pump" do
      mock_pumps(["BC_0_QUIMICA_CIRCULACION_QUIMICA"])
      mock_boron(2000.0)
      before = state()

      assert {:reply, {:error, msg}, ^before} = set(before, 3000)
      assert msg =~ "dosing pump"
    end

    test "can't lower boron without an ion exchange pump" do
      mock_pumps(["BC_0_QUIMICA_DOSIFICADORA"])
      mock_boron(2000.0)
      before = state()

      assert {:reply, {:error, msg}, ^before} = set(before, 1000)
      assert msg =~ "ion exchange"
    end

    test "a hibernating operator (no chemicals) says so" do
      assert {:reply, {:error, msg}, nil} =
               BoronLevel.handle_call({:set_concentration, 1000.0}, from(), nil)

      assert msg =~ "not enabled"
    end

    test "takes an integer, passing it on as a float" do
      server = stub_server({:ok, 1500.0})

      assert {:ok, 1500.0} = BoronLevel.set_concentration(1500, server)
      assert_received {:stub_call, {:set_concentration, 1500.0}}
    end

    test "doesn't take a non-numeric concentration" do
      assert_raise FunctionClauseError, fn ->
        BoronLevel.set_concentration(Process.get(:no_such_key, "lots"), self())
      end
    end
  end

  describe "with a target" do
    test "doses to raise boron, and doesn't filter" do
      mock_boron(3000.0)

      state = state(target: 3300.0) |> tick()

      assert MockAPI.mock_put_value(@dosing_key) == 50
      assert state.dosing_rate == 50
      assert state.filter_rate == 0
    end

    test "filters to lower boron, and doesn't dose" do
      mock_boron(3300.0)

      state = state(target: 3000.0) |> tick()

      assert MockAPI.mock_put_value(@filter_key) == 100
      assert state.filter_rate == 100
      assert state.dosing_rate == 0
    end

    test "stops both once the target is reached" do
      mock_boron(3300.0)

      state = state(target: 3300.0, dosing_rate: 5, filter_rate: 5) |> tick()

      assert MockAPI.mock_put_value(@dosing_key) == 0
      assert MockAPI.mock_put_value(@filter_key) == 0
      assert state.dosing_rate == 0
      assert state.filter_rate == 0
    end

    test "ignores the control rods" do
      mock_boron(3000.0)
      # Rods fully out would otherwise mean "filter boron out":
      MockAPI.mock_get("RODS_POS_ACTUAL", 0.0, times: :any)

      state = state(target: 3300.0) |> tick()

      assert state.dosing_rate == 50
      assert state.filter_rate == 0
    end

    test "won't run the filter pump when filtration isn't ready" do
      mock_boron(3300.0)

      state = state(target: 3000.0, filter_ready: false) |> tick()

      # Told to stay at 0 rather than to run dry:
      assert MockAPI.mock_put_value(@filter_key) == 0
      assert state.filter_rate == 100
    end
  end

  describe "clear_concentration" do
    test "goes back to following the rods" do
      assert {:reply, :ok, state} =
               BoronLevel.handle_call(:clear_concentration, from(), state(target: 3300.0))

      assert state.target == nil

      # Rods halfway: neither dosing nor filtering.
      MockAPI.mock_get("RODS_POS_ACTUAL", 50.0, times: :any)
      state = %State{state | dosing_rate: 20} |> tick()
      assert MockAPI.mock_put_value(@dosing_key) == 0
      assert state.dosing_rate == 0
    end

    test "is harmless when there was no target" do
      assert {:reply, :ok, %State{target: nil}} =
               BoronLevel.handle_call(:clear_concentration, from(), state())
    end

    test "the target can be read back" do
      assert {:reply, 3300.0, _} =
               BoronLevel.handle_call(:get_concentration_target, from(), state(target: 3300.0))

      assert {:reply, nil, _} = BoronLevel.handle_call(:get_concentration_target, from(), state())
    end
  end

  describe "persistence" do
    setup do
      start_supervised!(PubSub)
      mock_pumps(@both)
      mock_boron(2000.0)
      MockAPI.mock_get("CHEM_BORON_FILTER_ORDERED", 0, times: :any)
      MockAPI.mock_get("CHEM_BORON_DOSAGE_ORDERED", 0, times: :any)
      :ok
    end

    test "a set concentration is saved, and picked up by a freshly started operator" do
      {:reply, {:ok, 3000.0}, _} = set(state(), 3000)

      assert {:ok, %State{target: 3000.0}} = BoronLevel.init(nil)
    end

    test "starts following the rods when nothing was saved" do
      assert {:ok, %State{target: nil}} = BoronLevel.init(nil)
    end

    test "clearing forgets the saved concentration" do
      {:reply, {:ok, 3000.0}, state} = set(state(), 3000)
      {:reply, :ok, _} = BoronLevel.handle_call(:clear_concentration, from(), state)

      assert {:ok, %State{target: nil}} = BoronLevel.init(nil)
    end

    test "a rejected target isn't saved" do
      {:reply, {:error, _}, _} = set(state(), 9000)

      assert {:ok, %State{target: nil}} = BoronLevel.init(nil)
    end

    test "a startup-saved target (via the setting) is honoured" do
      AutoNuke.Settings.put(BoronLevel.target_setting(), 2500.0)

      assert {:ok, %State{target: 2500.0}} = BoronLevel.init(nil)
    end
  end

  # Stands in for the running operator: records what it was asked and
  # replies with `reply`.
  defp stub_server(reply) do
    owner = self()

    spawn_link(fn ->
      receive do
        {:"$gen_call", from, msg} ->
          send(owner, {:stub_call, msg})
          GenServer.reply(from, reply)
      end
    end)
  end
end
