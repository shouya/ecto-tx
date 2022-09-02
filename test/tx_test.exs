defmodule TxTest do
  use ExUnit.Case
  doctest Tx

  test "greets the world" do
    assert Tx.hello() == :world
  end
end
