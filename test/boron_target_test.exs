defmodule AutoNuke.BoronTargetTest do
  use ExUnit.Case, async: false

  alias AutoNuke.BoronTarget
  alias AutoNuke.Operator, as: Op

  describe "plan/3" do
    test "raising boron to a higher level needs doing" do
      assert BoronTarget.plan(:up, 2000.0, 3000) == :go
    end

    test "lowering boron to a lower level needs doing" do
      assert BoronTarget.plan(:down, 3000.0, 2000) == :go
    end

    test "raising boron to a level it is already at or above is a no-op" do
      assert BoronTarget.plan(:up, 3000.0, 3000) == :already
      assert BoronTarget.plan(:up, 3500.0, 3000) == :already
    end

    test "lowering boron to a level it is already at or below is a no-op" do
      assert BoronTarget.plan(:down, 2000.0, 2000) == :already
      assert BoronTarget.plan(:down, 1000.0, 2000) == :already
    end

    test "within 1 ppm counts as already there (the operator stops there too)" do
      assert BoronTarget.plan(:up, 2999.5, 3000) == :already
      assert BoronTarget.plan(:down, 2000.5, 2000) == :already
      assert BoronTarget.plan(:up, 2998.5, 3000) == :go
      assert BoronTarget.plan(:down, 2001.5, 2000) == :go
    end
  end

  describe "operator_running?/0" do
    test "false when BoronLevel isn't running" do
      refute BoronTarget.operator_running?()
    end

    test "true when a process is registered under its name" do
      {:ok, agent} = Agent.start(fn -> nil end, name: Op.BoronLevel)

      try do
        assert BoronTarget.operator_running?()
      after
        Agent.stop(agent)
      end
    end
  end
end
