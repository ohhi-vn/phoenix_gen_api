defmodule PhoenixGenApiTest do
  use ExUnit.Case
  doctest PhoenixGenApi

  test "greets the world" do
    assert PhoenixGenApi.hello() == :world
  end
end
