defmodule Tx.Macro do
  @moduledoc """
  A macro to allow easy composition of transactions.


  Suppose create_a_tx() has type Trans.t(a) and tx_b has type (a ->
  Trans.t(b)), then the following block produces a Trans.t({a, b}).

    import Tx.Macro

    tx repo do
      value = repo.insert(foo)
      {:ok, a} <- create_a_tx(value)
      {:ok, b} <- create_b_tx(a)
      {:ok, {a, b}}
    end

  Specifically, it expands into:

  Tx.new(fn repo ->
    with
      value = repo.insert(foo)
      {:ok, a} <- Tx.run(repo, tx_a(value)),
      {:ok, b} <- Tx.run(repo, tx_b(a)) do
      {:ok, {a, b}}
    end
  end)
  """

  defmacro tx(repo, do: {:__block__, _, body}), do: rewrite(repo, body, nil)
  defmacro tx(repo, do: {:__block__, _, body}, else: e), do: rewrite(repo, body, e)
  defmacro tx(do: {:__block__, _, body}), do: rewrite(nil, body, nil)
  defmacro tx(do: {:__block__, _, body}, else: e), do: rewrite(nil, body, e)

  defp rewrite(repo, body, else_) do
    repo = repo || Macro.var(:repo, __MODULE__)

    quote do
      Tx.new(fn unquote(repo) ->
        unquote(rewrite_inner(repo, body, else_))
      end)
    end
  end

  defp rewrite_inner(repo, body, else_) when length(body) > 1 do
    exprs = Enum.map(Enum.slice(body, 0..-2), &rewrite_bind_clause(repo, &1))
    last_expr = Enum.at(body, -1)

    do_and_else =
      case else_ do
        nil -> [do: last_expr]
        _ -> [do: last_expr, else: else_]
      end

    {:with, [], exprs ++ [do_and_else]}
  end

  defp rewrite_inner(_repo, body, _else), do: body

  # bind operator
  defp rewrite_bind_clause(repo, {:<-, env, [pat, expr]}) do
    run_expr =
      quote do
        Tx.run(unquote(repo), unquote(expr))
      end

    {:<-, env, [pat, run_expr]}
  end

  defp rewrite_bind_clause(_repo, other), do: other
end
