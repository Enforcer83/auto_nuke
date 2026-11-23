defmodule AutoNuke.Operator.BoronLevel do
  use GenServer
  use AutoNuke.Operator
  require Logger

  defmodule State do
    @enforce_keys [:dosing_rate, :filter_rate]
    defstruct(
      dosing_rate: nil,
      filter_rate: nil,
      filter_ready: false,
      # Concentration (ppm) to work toward, or nil to follow rod position:
      target: nil,
      next_ready_check: 0,
      next_pump_check: nil
    )
  end

  alias AutoNuke.API

  @log_prefix "[#{inspect(__MODULE__)}] " |> String.replace("AutoNuke.Operator.", "")

  # I'm told boron beyond 3500 has no effect.
  # Practically speaking, it's hard to maintain at 3500 anyway.
  @dosing_max_ppm 3500

  # Peform ready check once every 10 in-game seconds:
  tps = AutoNuke.Ticker.ticks_per_second()
  @ready_check_interval 10 * tps
  # If filter pump does not turn on within 10 seconds, begin issuing warnings:
  @pump_check_interval 10 * tps

  # When working toward a set concentration, slow the dosing pump as we
  # close in (same easing as the startup task), and stop within this many ppm:
  @target_easing 3
  @target_tolerance 1.0
  @dosing_max_rate 50

  # The target concentration is kept in the settings file, so it survives
  # restarts and the startup handover (nil/absent = follow the rods).
  @target_setting "boron_target"
  def target_setting, do: @target_setting

  @dosing_pump API.Pumps.boron_dosing()
  @filter_pump API.Pumps.boron_filter()

  def start_link(opts \\ []) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, nil, opts)
  end

  def get_dosing_rate, do: GenServer.call(__MODULE__, :get_dosing_rate)
  def get_filter_rate, do: GenServer.call(__MODULE__, :get_filter_rate)

  @doc """
  Work toward a boron concentration of `ppm` (0-#{@dosing_max_ppm}), instead of
  following rod position.  Doses boron to raise it, or runs the ion exchange
  to lower it, and keeps correcting until cleared.

  Returns `{:ok, ppm}`, or `{:error, message}` when the target is out of
  range or the pump needed to reach it isn't installed.
  """
  def set_concentration(ppm, pid \\ __MODULE__) when is_number(ppm),
    do: GenServer.call(pid, {:set_concentration, ppm / 1})

  @doc "Go back to following rod position."
  def clear_concentration(pid \\ __MODULE__), do: GenServer.call(pid, :clear_concentration)

  @doc "The concentration being worked toward, or `nil` when following the rods."
  def get_concentration_target(pid \\ __MODULE__),
    do: GenServer.call(pid, :get_concentration_target)

  @impl true
  def init(nil) do
    using_chemicals?()
    |> maybe_init()
  end

  defp maybe_init(false) do
    Logger.info(@log_prefix <> "Chemicals not enabled (or no pumps installed).  Going to sleep.")
    {:ok, nil, :hibernate}
  end

  defp maybe_init(true) do
    boron = get_boron_ppm()
    filter_rate = @filter_pump |> API.Pumps.get_ordered_speed()
    dose_rate = @dosing_pump |> API.Pumps.get_ordered_speed()
    target = AutoNuke.Settings.get(@target_setting, nil)
    state = %State{dosing_rate: dose_rate, filter_rate: filter_rate, target: target}

    PubSub.subscribe(self(), :ticker)

    Logger.info([
      @log_prefix,
      "Started with boron at #{boron} ppm,",
      " dosing at #{dose_rate} g/min,",
      " and filtration at #{filter_rate}%.",
      if(target, do: " Working toward #{target} ppm.", else: "")
    ])

    {:ok, state}
  end

  # Chemicals aren't enabled, so there is nothing to control.
  @impl true
  def handle_call({:set_concentration, _}, _from, nil) do
    {:reply, {:error, "Boron chemicals are not enabled."}, nil}
  end

  @impl true
  def handle_call({:set_concentration, ppm}, _from, %State{} = state) do
    # Always a float, whoever calls (the public function converts too).
    ppm = ppm / 1
    current = get_boron_ppm()

    cond do
      ppm < 0 or ppm > @dosing_max_ppm ->
        {:reply, {:error, "#{ppm} ppm is outside the allowed range of 0-#{@dosing_max_ppm} ppm."},
         state}

      ppm > current and not API.Pumps.installed?(@dosing_pump) ->
        {:reply, {:error, "No boron dosing pump installed, can't raise boron."}, state}

      ppm < current and not API.Pumps.installed?(@filter_pump) ->
        {:reply, {:error, "No ion exchange pump installed, can't lower boron."}, state}

      true ->
        Logger.info(@log_prefix <> "Working toward #{ppm} ppm (now #{current} ppm).")
        AutoNuke.Settings.put(@target_setting, ppm)
        {:reply, {:ok, ppm}, %State{state | target: ppm}}
    end
  end

  @impl true
  def handle_call(:clear_concentration, _from, %State{} = state) do
    if state.target, do: Logger.info(@log_prefix <> "Following control rod position again.")
    AutoNuke.Settings.put(@target_setting, nil)
    {:reply, :ok, %State{state | target: nil}}
  end

  @impl true
  def handle_call(:get_concentration_target, _from, %State{target: target} = state) do
    {:reply, target, state}
  end

  @impl true
  def handle_call(:get_dosing_rate, _from, %State{dosing_rate: rate} = state) do
    {:reply, rate, state}
  end

  @impl true
  def handle_call(:get_filter_rate, _from, %State{filter_rate: rate} = state) do
    {:reply, rate, state}
  end

  @impl true
  def handle_info({:tick, t}, state) when not is_my_tick(t), do: {:noreply, state}

  @impl true
  def handle_info({:tick, t}, %State{} = state) do
    {dosing, filtering} = desired_rates(state.target)

    {:noreply,
     state
     |> tick_dosing(dosing)
     |> tick_filter(filtering, t)}
  end

  # Following the rods:
  defp desired_rates(nil) do
    rods = API.get_float("RODS_POS_ACTUAL")
    {calculate_dosing_rate(rods), calculate_filter_rate(rods)}
  end

  # Working toward a set concentration:
  defp desired_rates(target) do
    ppm = get_boron_ppm()
    {target_dosing_rate(ppm, target), target_filter_rate(ppm, target)}
  end

  @doc false
  def target_dosing_rate(ppm, target) when target - ppm < @target_tolerance, do: 0

  def target_dosing_rate(ppm, target) do
    ((target - ppm) / @target_easing)
    |> ceil()
    |> min(@dosing_max_rate)
  end

  @doc false
  def target_filter_rate(ppm, target) when ppm - target < @target_tolerance, do: 0

  def target_filter_rate(ppm, target) do
    (ppm - target)
    |> ceil()
    |> min(100)
  end

  defp tick_dosing(%State{dosing_rate: old} = state, new) do
    if new != old do
      Logger.info(@log_prefix <> "Changing dosing rate from #{old} to #{new} g/min.")
      @dosing_pump |> API.Pumps.set_speed(new)
      %State{state | dosing_rate: new}
    else
      state
    end
  end

  defp tick_filter(%State{filter_rate: old} = state, new, t) do
    state = ready_check(state, t)

    if new != old do
      if state.filter_ready || new == 0 do
        Logger.info(@log_prefix <> "Changing filter speed from #{old}% to #{new}%.")
        @filter_pump |> API.Pumps.set_speed(new)
      else
        Logger.error(@log_prefix <> "Filtration not ready!  Cannot change speed to #{new}%.")
        @filter_pump |> API.Pumps.set_speed(0)
      end

      %State{state | filter_rate: new}
    else
      state
    end
    |> pump_check(t, new)
  end

  defp using_chemicals? do
    [@dosing_pump, @filter_pump] |> Enum.any?(&API.Pumps.installed?/1)
  end

  def get_boron_ppm, do: API.get_float("CHEM_BORON_PPM")

  defp calculate_dosing_rate(rods) when rods <= 66, do: 0

  defp calculate_dosing_rate(rods) do
    # Cube curve from 0 g/min at 66% rods to 50 g/min at 100% rods:
    (50 * ((rods - 66) / 34) ** 3)
    |> ceil()
    # Limit our rate to whatever rate will get us to 3500 ppm.
    |> min(@dosing_max_ppm - get_boron_ppm())
    |> max(0)
  end

  defp calculate_filter_rate(rods) when rods >= 33, do: 0

  defp calculate_filter_rate(rods) do
    # Square curve from 0% at 33% rods up to 100% at 0% rods:
    (100 * ((33 - rods) / 33) ** 2)
    |> ceil()
    # Below 100 ppm, start throttling back.
    |> min(get_boron_ppm() |> floor())
    |> max(0)
    |> min(100)
  end

  defp ready_check(%State{next_ready_check: next} = state, curr) when curr < next, do: state

  @filter_valves [
    API.Valves.ion_inlet(),
    API.Valves.ion_outlet()
  ]
  defp ready_check(%State{} = state, t) do
    not_ready = fn vs, is_are ->
      Logger.warning("Ion filtration not ready: #{vs} valve #{is_are} closed.")
      false
    end

    case @filter_valves |> Enum.reject(&API.Valves.get_opened?/1) do
      [] ->
        true

      [v] ->
        not_ready.(v.short_name, "is")

      valves ->
        valves
        |> Enum.map(& &1.short_name)
        |> Enum.join(" and ")
        |> then(&not_ready.(&1, "are"))
    end
    |> then(fn r when is_boolean(r) ->
      %State{state | filter_ready: r, next_ready_check: t + @ready_check_interval}
    end)
  end

  # No filtration requested, disable checks if enabled:
  defp pump_check(%State{next_pump_check: t} = state, _, 0) do
    case t do
      nil -> state
      _ -> %State{state | next_pump_check: nil}
    end
  end

  # We just started asking for filtration, schedule the first check:
  defp pump_check(%State{next_pump_check: nil} = state, t, f) when f > 0 do
    %State{state | next_pump_check: t + @pump_check_interval}
  end

  # Not time for another check yet:
  defp pump_check(%State{next_pump_check: next} = state, curr, _)
       when is_integer(next) and curr < next,
       do: state

  # Filtration is requested, and it's time for a check:
  defp pump_check(%State{} = state, t, f) when f > 0 do
    if @filter_pump |> API.Pumps.get_actual_speed() < 1.0 do
      Logger.error("Filtration pump not activating.  Check ion exchange switch.")
    end

    %State{state | next_pump_check: t + @pump_check_interval}
  end
end
