defmodule Tx.MacroTest do
  use ExUnit.Case, async: true

  import Tx.Macro

  describe "tx/1 macro" do
    test "only do block" do
      expected =
        quote do
          Tx.new(fn repo ->
            with {:ok, a} <- Tx.run(repo, tx_a(foo)),
                 {:ok, b} <- Tx.run(repo, tx_b(a, foo)) do
              {:ok, {a, b}}
            end
          end)
        end
        |> normalize_ast()

      actual =
        quote do
          tx do
            {:ok, a} <- tx_a(foo)
            {:ok, b} <- tx_b(a, foo)
            {:ok, {a, b}}
          end
        end
        |> Macro.expand_once(__ENV__)
        |> normalize_ast()

      assert expected == actual
    end

    test "do-else block" do
      expected =
        quote do
          Tx.new(fn repo ->
            with {:ok, a} <- Tx.run(repo, tx_a(foo)),
                 {:ok, b} <- Tx.run(repo, tx_b(a, foo)) do
              {:ok, {a, b}}
            else
              {:error, e1} -> {:error, e1}
              {:error, e2} when e2 > 0 -> {:error, e2}
              e3 -> e3
            end
          end)
        end
        |> normalize_ast()

      actual =
        quote do
          tx do
            {:ok, a} <- tx_a(foo)
            {:ok, b} <- tx_b(a, foo)
            {:ok, {a, b}}
          else
            {:error, e1} -> {:error, e1}
            {:error, e2} when e2 > 0 -> {:error, e2}
            e3 -> e3
          end
        end
        |> Macro.expand_once(__ENV__)
        |> normalize_ast()

      assert expected == actual
    end
  end

  describe "tx/2 macro" do
    test "do-block only" do
      expected =
        quote do
          Tx.new(fn repo1 ->
            with foo = bar(repo1),
                 {:ok, a} <- Tx.run(repo1, tx_a(foo)),
                 {:ok, b} <- Tx.run(repo1, tx_b(a, foo, repo1)) do
              {:ok, {a, b, foo}}
            end
          end)
        end
        |> normalize_ast()

      actual =
        quote do
          tx repo1 do
            foo = bar(repo1)
            {:ok, a} <- tx_a(foo)
            {:ok, b} <- tx_b(a, foo, repo1)
            {:ok, {a, b, foo}}
          end
        end
        |> Macro.expand_once(__ENV__)
        |> normalize_ast()

      assert expected == actual
    end
  end

  defp normalize_ast(ast) do
    Macro.postwalk(ast, fn
      {a, [{:counter, _} | x], Tx.Macro} -> {a, x, __MODULE__}
      {a, [{:counter, _} | x], c} -> {a, x, c}
      x -> x
    end)
  end
end
