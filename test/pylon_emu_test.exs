defmodule PylonEmuTest do
  use ExUnit.Case
  doctest PylonEmu

  test "greets the world" do
    assert PylonEmu.hello() == :world
  end
end
