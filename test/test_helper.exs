defmodule DummyRepo do
  @moduledoc """
  A dummy repo that only fails
  """

  def transaction(f, _opts) do
    {:ok, f.(__MODULE__)}
  catch
    {:rollback, value} -> {:error, value}
  end

  def rollback(value) do
    throw({:rollback, value})
  end
end

ExUnit.start()
