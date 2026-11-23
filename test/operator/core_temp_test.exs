defmodule AutoNuke.Operator.CoreTempTest do
  use ExUnit.Case, async: false

  alias AutoNuke.Operator.CoreTemp
  alias AutoNuke.Operator.CoreTemp.Drift
  alias AutoNuke.Test.MockAPI

  # Callbacks are driven directly in the test process so MockAPI's
  # per-process mocks apply without alias gymnastics.

  @tick AutoNuke.Operator.assigned_tick(CoreTemp)

  setup do
    start_supervised!(PubSub)
    MockAPI.mock_get("TIME_STAMP", 1000, times: :any)
    :ok
  end

  # No loops, so there are no steam generators to read.  The core sits at
  # `core_temp` for the whole test.
  defp init(core_temp) do
    MockAPI.mock_get("CORE_TEMP", core_temp, times: :any)
    {:ok, state} = CoreTemp.init([])
    state
  end

  # (Not a module attribute: pids and refs can't be injected into functions.)
  defp from, do: {self(), make_ref()}

  defp hold(state, temp, expiry \\ :never) do
    CoreTemp.handle_call({:hold, temp, expiry}, from(), state)
  end

  defp tick(state) do
    {:noreply, state} = CoreTemp.handle_info({:tick, @tick}, state)
    state
  end

  defp ticks(state, n), do: Enum.reduce(1..n, state, fn _, s -> tick(s) end)

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

  describe "hold/3" do
    test "records the hold without moving the target at once" do
      state = init(340.0)

      assert {:reply, {:ok, 330.0}, state} = hold(state, 330.0)
      assert state.hold == {330.0, :never}
      assert state.override == nil
    end

    test "accepts both ends of the allowed range" do
      state = init(340.0)

      assert {:reply, {:ok, 300.0}, _} = hold(state, 300.0)
      assert {:reply, {:ok, 400.0}, _} = hold(state, 400.0)
    end

    test "rejects temperatures outside the allowed range, changing nothing" do
      state = init(340.0)

      for temp <- [299.9, 400.1, 0.0, 500.0] do
        assert {:reply, {:error, msg}, unchanged} = hold(state, temp)
        assert msg =~ "300-400"
        assert unchanged == state
      end
    end

    test "keeps an expiry when one is given" do
      state = init(340.0)

      assert {:reply, {:ok, 330.0}, state} = hold(state, 330.0, 2000)
      assert state.hold == {330.0, 2000}
    end

    test "cancels a drift in progress, which would otherwise overwrite the hold" do
      state = init(340.0)
      drift = Drift.new(end_temp: 380, duration: 60)
      {:reply, :ok, state} = CoreTemp.handle_call({:drift, drift}, from(), state)
      assert {^drift, false} = state.drift

      assert {:reply, {:ok, 338.0}, state} = hold(state, 338.0)
      assert state.drift == nil

      # And the hold survives a tick instead of being drifted away from.
      state = tick(state)
      assert state.override == {339.0, :never}
    end

    test "resolves :current to the measured temperature, to the nearest 0.1°C" do
      MockAPI.mock_get("CORE_TEMP", 341.26)
      server = stub_server({:ok, 341.3})

      assert {:ok, 341.3} = CoreTemp.hold(:current, :never, server)
      assert_received {:stub_call, {:hold, 341.3, :never}}
    end

    test "passes an integer temperature and a parsed expiry to the operator as a float" do
      server = stub_server({:ok, 330.0})

      assert {:ok, 330.0} = CoreTemp.hold(330, 1500, server)
      assert_received {:stub_call, {:hold, 330.0, 1500}}
    end

    test "doesn't take a non-numeric temperature" do
      assert_raise FunctionClauseError, fn -> CoreTemp.hold("hot", :never, self()) end
    end
  end

  describe "while holding" do
    test "closes on a setpoint below the core 1°C a tick, then stays put" do
      state = init(340.0)
      {:reply, {:ok, 338.0}, state} = hold(state, 338.0)

      state = tick(state)
      assert state.override == {339.0, :never}
      state = tick(state)
      assert state.override == {338.0, :never}
      state = tick(state)
      assert state.override == {338.0, :never}
    end

    test "closes on a setpoint above the core 1°C a tick, then stays put" do
      state = init(340.0)
      {:reply, {:ok, 343.0}, state} = hold(state, 343.0)

      assert state |> tick() |> Map.fetch!(:override) == {341.0, :never}
      assert state |> ticks(2) |> Map.fetch!(:override) == {342.0, :never}
      assert state |> ticks(3) |> Map.fetch!(:override) == {343.0, :never}
      assert state |> ticks(9) |> Map.fetch!(:override) == {343.0, :never}
    end

    test "never gets more than 10°C ahead of the core, however far the setpoint" do
      state = init(340.0)
      {:reply, {:ok, 400.0}, state} = hold(state, 400.0)

      assert state |> ticks(20) |> Map.fetch!(:override) == {350.0, :never}
    end

    test "never gets more than 5°C behind the core" do
      state = init(340.0)
      {:reply, {:ok, 300.0}, state} = hold(state, 300.0)

      assert state |> ticks(20) |> Map.fetch!(:override) == {335.0, :never}
    end

    test "carries on from an existing override instead of jumping" do
      state = init(340.0)
      {:reply, :ok, state} = CoreTemp.handle_call({:override, 336.0, :never}, from(), state)
      {:reply, {:ok, 338.0}, state} = hold(state, 338.0)

      assert state |> tick() |> Map.fetch!(:override) == {337.0, :never}
    end

    test "publishes the target every tick" do
      state = init(340.0)
      PubSub.subscribe(self(), :core_temp)
      {:reply, {:ok, 338.0}, state} = hold(state, 338.0)

      state = tick(state)
      assert_receive {:core_temp, 339.0}
      state = tick(state)
      assert_receive {:core_temp, 338.0}
      tick(state)
      assert_receive {:core_temp, 338.0}
    end

    test "an expired hold hands control back to the pressure-following target" do
      state = init(340.0)
      {:reply, {:ok, 338.0}, state} = hold(state, 338.0, 500)

      # The clock says 1000, so an expiry of 500 has passed.
      state = tick(state)
      assert state.hold == nil
      assert state.override == nil
    end

    test "clearing the override ends the hold" do
      state = init(340.0)
      {:reply, {:ok, 338.0}, state} = hold(state, 338.0)
      state = tick(state)

      assert {:reply, :ok, state} = CoreTemp.handle_call(:clear_override, from(), state)
      assert state.override == nil
      assert state.hold == nil

      assert CoreTemp.handle_call(:get_override, from(), state) == {:reply, nil, state}
    end

    test "setting an override ends the hold" do
      state = init(340.0)
      {:reply, {:ok, 338.0}, state} = hold(state, 338.0)

      assert {:reply, :ok, state} =
               CoreTemp.handle_call({:override, 335.0, :never}, from(), state)

      assert state.hold == nil
      assert state |> ticks(3) |> Map.fetch!(:override) == {335.0, :never}
    end

    test "starting a drift ends the hold" do
      state = init(340.0)
      {:reply, {:ok, 338.0}, state} = hold(state, 338.0)
      drift = Drift.new(end_temp: 380, duration: 60)

      assert {:reply, :ok, state} = CoreTemp.handle_call({:drift, drift}, from(), state)
      assert state.hold == nil
    end
  end
end
