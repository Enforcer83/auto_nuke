defmodule AutoNuke.BoronTarget do
  @moduledoc """
  Lets the boron tasks work *through* the `BoronLevel` operator when it is
  running, instead of driving the pumps themselves.

  The operator rewrites the dosing and filter pump speeds every second, so a
  task setting them directly would be fighting it.  Instead the task sets the
  operator's target concentration, waits for it to arrive, and leaves the
  target in place (so the operator keeps the new level, until it's told to
  follow the control rods again).

  Without the operator running, the tasks drive the pumps as before.
  """

  alias AutoNuke.API
  alias AutoNuke.Operator, as: Op
  alias AutoNuke.TaskUI, as: UI

  # The operator stops dosing/filtering within this many ppm of its target.
  @tolerance 1.0

  @doc "Is the BoronLevel operator running (and so in charge of the pumps)?"
  def operator_running?, do: is_pid(Process.whereis(Op.BoronLevel))

  @doc """
  Does moving from `current` to `target` in `direction` (`:up` or `:down`)
  need doing?  Raising boron to a level it is already above (or lowering it
  to one it's already below) is a no-op.
  """
  def plan(:up, current, target) when current > target - @tolerance, do: :already
  def plan(:down, current, target) when current < target + @tolerance, do: :already
  def plan(direction, _, _) when direction in [:up, :down], do: :go

  @doc """
  Ask the operator to work toward `target`, and wait until it gets there.
  Returns `:ok`, or `{:error, message}` if the operator refused the target.
  """
  def reach(target, direction) when direction in [:up, :down] do
    UI.console("Chemical Treatment")
    current = API.get_float("CHEM_BORON_PPM")

    with :go <- plan(direction, current, target),
         {:ok, _} <- Op.BoronLevel.set_concentration(target) do
      UI.notice("BoronLevel is running, so it is doing the dosing and filtering.")
      wait_for(target, current, direction)
      UI.success("BoronLevel is holding #{target} ppm.")
    else
      :already -> UI.success("Boron PPM is #{current}.")
      {:error, msg} -> UI.warn(msg)
    end

    :ok
  end

  defp wait_for(target, _current, :up) do
    UI.ProgressBar.wait(
      config: UI.ProgressBar.Config.target(0, target, " ppm", 1),
      label: "Boron",
      current_fn: &get_ppm/0,
      done_fn: &(&1 > target - @tolerance)
    )
  end

  defp wait_for(target, current, :down) do
    UI.ProgressBar.wait(
      config: UI.ProgressBar.Config.target(current, target),
      label: "Boron",
      current_fn: &get_ppm/0,
      done_fn: &(&1 < target + @tolerance)
    )
  end

  defp get_ppm, do: API.get_float("CHEM_BORON_PPM")
end
