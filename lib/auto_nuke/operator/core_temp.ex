defmodule AutoNuke.Operator.CoreTemp do
  use GenServer
  use AutoNuke.Operator
  require Logger

  alias AutoNuke.API
  alias AutoNuke.Operator.CoreTemp.Drift
  alias AutoNuke.Time, as: ANTime

  defmodule State do
    @enforce_keys [:monitored, :axis]
    defstruct(
      monitored: nil,
      axis: nil,
      override: nil,
      drift: nil,
      hold: nil
    )
  end

  defmodule MonitoredVessel do
    @enforce_keys [:loop, :vessel, :history]
    defstruct(@enforce_keys)

    alias __MODULE__, as: MV
    alias AutoNuke.Smoother

    @history_size 10
    @lookahead 5

    def new(loop) do
      vessel = API.Vessels.steam_generator(loop)
      pressure = API.Vessels.get_pressure(vessel)

      %MV{
        loop: loop,
        vessel: vessel,
        history: Smoother.new(@history_size) |> Smoother.add(pressure)
      }
    end

    def tick(%MV{vessel: vessel, history: history} = mv) do
      pressure = API.Vessels.get_pressure(vessel)
      %MV{mv | history: history |> Smoother.add(pressure)}
    end

    def guess_future_pressure(%MV{history: h}), do: h |> Smoother.extrapolate(@lookahead)
  end

  alias AutoNuke.ControlAxis

  @log_prefix "[#{inspect(__MODULE__)}] " |> String.replace("AutoNuke.Operator.", "")
  @loops 1..3

  # Target 60 bar of pressure, plus or minus half a bar.
  @target_pressure 60
  @deadzone 0.5

  # Temperature range: 300°C to 400°C.
  @temp_range 300..400
  # We could probably go lower, but I don't want to risk turbine stalls.
  def temp_range, do: @temp_range

  # Clamp values to within +10°C or -5°C of current temperature.
  @clamp_upwards 10
  @clamp_downwards 5
  # If we get within 10°C of the edge of @temp_range, clamp to
  # half the difference between current temperature and that boundary.
  @clamp_near_boundary 10

  # A hold closes on its setpoint at this many °C per CoreTemp tick (one a
  # second), the same 1°C/s the startup task ramps at.  Handing the rods a
  # target hundreds of degrees away just winds them up and overshoots.
  @hold_ramp 1.0

  def start_link(opts \\ []) do
    {loops, opts} = Keyword.pop(opts, :loops, :detect)
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, loops, opts)
  end

  def add_loop(loop, pid \\ __MODULE__) when loop in @loops do
    GenServer.call(pid, {:add_loop, loop})
  end

  def remove_loop(loop, pid \\ __MODULE__) when loop in @loops do
    GenServer.call(pid, {:remove_loop, loop})
  end

  def get_loops(pid \\ __MODULE__) do
    GenServer.call(pid, :get_loops)
  end

  def set_override(temp, expiry \\ :next_hour, pid \\ __MODULE__) do
    GenServer.call(pid, {:override, temp + 0.0, ANTime.parse_expiry(expiry)})
  end

  def get_override(pid \\ __MODULE__) do
    GenServer.call(pid, :get_override)
  end

  def clear_override(pid \\ __MODULE__) do
    GenServer.call(pid, :clear_override)
  end

  @doc """
  Hold the core at a fixed temperature, instead of letting the target move
  to chase #{@target_pressure} bar.

  `temp` is either a number of °C, or `:current` to hold wherever the core
  is right now (rounded to the 0.1°C the game resolves).  It must lie within
  `temp_range/0`; anything else is rejected with `{:error, message}` and
  leaves the current behaviour untouched.  On success returns `{:ok, temp}`.

  The target does not jump to `temp`.  It closes on it at 1°C a second, and
  never gets further from the core than the usual clamps allow (10°C above,
  5°C below), so a cold core is brought up gently instead of the rods being
  asked to chase a target hundreds of degrees away.  Once it arrives the
  target stays put.

  A hold is an override as far as everything downstream (`ControlRods`,
  `PrimaryPumps`) is concerned, and `get_override/1` shows the target as it
  currently stands.  Unlike `set_override/3` it never expires by default
  (`expiry` can be anything `AutoNuke.Time.parse_expiry/1` accepts), and it
  cancels any drift in progress, since a drift would otherwise overwrite the
  hold.  Starting a drift, `set_override/3` or `clear_override/1` ends the hold.

  While held, pressure is no longer being steered by temperature: it is up to
  `SteamFlow` (valves and bypass) to keep the steam generators in check.
  Releasing the hold with `clear_override/1` resumes the pressure-following
  target from wherever the hold had got to, with no step.
  """
  def hold(temp \\ :current, expiry \\ :never, pid \\ __MODULE__)
      when temp == :current or is_number(temp) do
    GenServer.call(pid, {:hold, resolve_hold_temp(temp), ANTime.parse_expiry(expiry)})
  end

  def drift(opts, pid \\ __MODULE__) do
    opts
    |> Keyword.put_new(:start_time, :now)
    |> Drift.new()
    |> then(&GenServer.call(pid, {:drift, &1}))
  end

  def stop_drift(pid \\ __MODULE__) do
    GenServer.call(pid, :stop_drift)
  end

  @impl true
  def init(:detect) do
    AutoNuke.Operator.SteamFlow.get_closed_breakers()
    |> init()
  end

  @impl true
  def init(loops) when is_list(loops) do
    temp = get_core_temp()
    monitored = loops |> Enum.map(&MonitoredVessel.new/1)

    axis =
      ControlAxis.new(
        kp: 0.02,
        ki: 0.001,
        deadzone: @deadzone,
        to_value_fn: &axis_to_temp/1,
        offset: temp |> temp_to_axis(),
        initial_value: temp
      )

    state = %State{monitored: monitored, axis: axis}

    PubSub.subscribe(self(), :ticker)

    Logger.info([
      @log_prefix,
      "Started with loops #{inspect(loops)}",
      " and temperature #{inspect(temp)}°C."
    ])

    {:ok, state}
  end

  @impl true
  def handle_call({:add_loop, loop}, _from, %State{monitored: old_monitored} = state) do
    case old_monitored |> Enum.any?(&(&1.loop == loop)) do
      true ->
        {:reply, {:error, :already_active}, state}

      false ->
        new_monitored =
          [MonitoredVessel.new(loop) | old_monitored]
          |> Enum.sort_by(& &1.loop)

        {:reply, :ok, %State{state | monitored: new_monitored}}
    end
  end

  @impl true
  def handle_call({:remove_loop, loop}, _from, %State{monitored: old_monitored} = state) do
    {found, rest} = old_monitored |> Enum.split_with(&(&1.loop == loop))

    case found do
      [] ->
        {:reply, {:error, :not_active}, state}

      [%MonitoredVessel{loop: ^loop}] ->
        {:reply, :ok, %State{state | monitored: rest}}
    end
  end

  @impl true
  def handle_call(:get_loops, _from, %State{monitored: monitored} = state) do
    monitored
    |> Enum.map(& &1.loop)
    |> then(fn loops ->
      {:reply, loops, state}
    end)
  end

  @impl true
  def handle_call({:override, temp, expiry}, _from, %State{} = state) when is_float(temp) do
    Logger.info(@log_prefix <> "Override set to #{temp}°C, #{describe_expiry(expiry)}.")
    {:reply, :ok, %State{state | override: {temp, expiry}, hold: nil}}
  end

  @impl true
  def handle_call({:hold, temp, expiry}, _from, %State{} = state) when is_float(temp) do
    # Not `temp in @temp_range`: range membership is false for any float.
    if temp >= @temp_range.first and temp <= @temp_range.last do
      if state.drift != nil, do: Logger.info(@log_prefix <> "Cancelling drift in favour of hold.")
      Logger.info(@log_prefix <> "Holding core at #{temp}°C, #{describe_expiry(expiry)}.")
      {:reply, {:ok, temp}, %State{state | hold: {temp, expiry}, drift: nil}}
    else
      {:reply,
       {:error,
        "#{temp}°C is outside the allowed range of " <>
          "#{@temp_range.first}-#{@temp_range.last}°C."}, state}
    end
  end

  @impl true
  def handle_call(:get_override, _from, %State{} = state) do
    {:reply, state.override, state}
  end

  @impl true
  def handle_call(:clear_override, _from, %State{} = state) do
    Logger.info(@log_prefix <> "Clearing override.")
    {:reply, :ok, %State{state | override: nil, hold: nil}}
  end

  @impl true
  def handle_call({:drift, %Drift{} = drift}, _from, %State{} = state) do
    Logger.info(@log_prefix <> "Now planning to drift #{Drift.describe(drift)}.")
    {:reply, :ok, %State{state | drift: {drift, false}, hold: nil}}
  end

  @impl true
  def handle_call(:stop_drift, _from, %State{} = state) do
    Logger.info(@log_prefix <> "Cancelling drift.")
    {:reply, :ok, %State{state | drift: nil}}
  end

  @impl true
  def handle_info({:tick, t}, state) when not is_my_tick(t), do: {:noreply, state}

  @impl true
  def handle_info({:tick, _}, %State{} = state) do
    state =
      state
      |> apply_drift()
      |> apply_hold()
      |> maybe_expire_override()

    monitored = state.monitored |> Enum.map(&MonitoredVessel.tick/1)

    %State{state | monitored: monitored}
    |> do_tick()
  end

  defp do_tick(%State{override: nil} = state) do
    future_pressure = get_future_pressure(state.monitored)

    case ControlAxis.step(state.axis, @target_pressure, future_pressure) do
      {:changed, axis, new, old} ->
        {new, axis} = maybe_clamp_movement(axis, old, new)
        publish_core_temp(new)
        axis

      {:unchanged, axis, old} ->
        publish_core_temp(old)
        axis
    end
    |> then(fn axis ->
      {:noreply, %State{state | axis: axis}}
    end)
  end

  defp do_tick(%State{override: {temp, _expires}} = state) do
    publish_core_temp(temp)
    axis = ControlAxis.clamp(state.axis, temp_to_axis(temp), temp)
    {:noreply, %State{state | axis: axis}}
  end

  defp apply_drift(%State{drift: nil} = state), do: state

  defp apply_drift(%State{drift: {%Drift{} = drift, started}} = state) do
    case Drift.current_value(drift) do
      :not_started ->
        state

      {:drifting, :current} ->
        temp = state.axis.last_value
        drift = %Drift{drift | start_temp: temp}
        Logger.info(@log_prefix <> "Starting drift #{Drift.describe(drift)} ...")
        %State{state | override: {temp, :never}, drift: {drift, true}}

      {:drifting, temp} ->
        case started do
          false ->
            Logger.info(@log_prefix <> "Starting drift #{Drift.describe(drift)} ...")
            %State{state | override: {temp, :never}, drift: {drift, true}}

          true ->
            %State{state | override: {temp, :never}}
        end

      {:complete, temp} ->
        %State{state | override: {temp, :never}, drift: nil}
    end
  end

  defp apply_hold(%State{hold: nil} = state), do: state

  defp apply_hold(%State{hold: {setpoint, expiry}} = state) do
    if hold_expired?(expiry) do
      Logger.notice(@log_prefix <> "Hold has expired.")
      %State{state | hold: nil, override: nil}
    else
      # Carry on from wherever the target already is.
      from =
        case state.override do
          {temp, _} -> temp
          nil -> state.axis.last_value
        end

      core = get_core_temp()

      target =
        from
        |> step_toward(setpoint, @hold_ramp)
        |> max(min_relative(core))
        |> min(max_relative(core))
        |> Float.round(2)

      if target == setpoint and from != setpoint do
        Logger.info(@log_prefix <> "Hold has reached #{setpoint}°C.")
      end

      %State{state | override: {target, :never}}
    end
  end

  defp hold_expired?(:never), do: false
  defp hold_expired?(ts) when is_integer(ts), do: ANTime.get_current_time() >= ts

  defp step_toward(from, to, step) when abs(to - from) <= step, do: to
  defp step_toward(from, to, step) when to > from, do: from + step
  defp step_toward(from, _to, step), do: from - step

  defp maybe_expire_override(%State{override: nil} = state), do: state
  defp maybe_expire_override(%State{override: {_, :never}} = state), do: state

  defp maybe_expire_override(%State{override: {_, ts}} = state) when is_integer(ts) do
    if ANTime.get_current_time() >= ts do
      Logger.notice(@log_prefix <> "Override has expired.")
      %State{state | override: nil}
    else
      state
    end
  end

  defp maybe_clamp_movement(axis, old, new) do
    current = get_core_temp()
    upper = max_relative(current)
    lower = min_relative(current)

    cond do
      new > old && new > upper -> {:clamp, max(old, upper)}
      new < old && new < lower -> {:clamp, min(old, lower)}
      true -> {:ok, new}
    end
    |> then(fn
      {:clamp, temp} ->
        axis = ControlAxis.clamp(axis, temp_to_axis(temp), temp)
        {temp, axis}

      {:ok, temp} ->
        {temp, axis}
    end)
  end

  defp publish_core_temp(temp), do: PubSub.publish(:core_temp, {:core_temp, temp})

  defp describe_expiry(:never), do: "does not expire"
  defp describe_expiry(ts), do: "expires at #{ANTime.timestamp_to_string(ts)}"

  # Resolved on the caller's side, so a failed temperature read is the
  # caller's error and can't take the operator down.  The game only resolves
  # 0.1°C, so there is no point holding a more precise value than that.
  defp resolve_hold_temp(:current), do: Float.round(get_core_temp() / 1, 1)
  defp resolve_hold_temp(temp) when is_number(temp), do: temp / 1

  @relative_low @temp_range.first + @clamp_near_boundary
  @relative_high @temp_range.last - @clamp_near_boundary

  defp min_relative(temp) when temp < @relative_low do
    # Half of the distance to the lower bound:
    temp - (temp - @temp_range.first) / 2
  end

  defp min_relative(temp), do: temp - @clamp_downwards

  defp max_relative(temp) when temp > @relative_high do
    # Half of the distance to the upper bound:
    temp + (@temp_range.last - temp) / 2
  end

  defp max_relative(temp), do: temp + @clamp_upwards

  defp get_future_pressure([]) do
    # No active loops, reactor idle.  Pretend current pressure is a bit too
    # high, so we slowly slew our target temperature towards the minimum.
    @target_pressure + @deadzone * 1.1
  end

  defp get_future_pressure(monitored) do
    monitored
    |> Enum.map(&MonitoredVessel.guess_future_pressure/1)
    |> Statistex.average()
  end

  defp get_core_temp do
    API.Vessels.core_vessel()
    |> API.Vessels.get_temperature()
  end

  @temp_span (@temp_range.last - @temp_range.first) / 2
  @temp_midpoint @temp_range.first + @temp_span
  defp axis_to_temp(output), do: (@temp_midpoint + output * @temp_span) |> Float.round(2)
  defp temp_to_axis(temp), do: (temp - @temp_midpoint) / @temp_span
end
