defmodule Tx.Macro do
  @moduledoc """
  Export macros to allow create complex transactions without boilerplate.
  """

  @doc """
  Create a transaction with a binding to `repo`.

  The `repo` binding can be used within the body for raw db operations
  (e.g. `Repo.insert`, `Repo.update`, ...).

  Example:

  The following code:

      import Tx.Macro

      tx repo do
        {:ok, value} <- repo.insert(foo)
        {:ok, a} <- create_a_tx(value)
        {:ok, b} <- create_b_tx(a)
        {:ok, {a, b}}
      end

  will expands into:

      Tx.new(fn repo ->
        with {:ok, value} <- Tx.run(repo, repo.insert(foo)),
             {:ok, a} <- Tx.run(repo, create_a_tx(value)),
             {:ok, b} <- Tx.run(repo, create_b_tx(a)) do
          {:ok, {a, b}}
        end
      end)
  """
  defmacro tx(repo, do: {:__block__, _, body}), do: rewrite(repo, body, nil)
  defmacro tx(repo, do: {:__block__, _, body}, else: e), do: rewrite(repo, body, e)

  @doc """
  Create a transaction.

      import Tx.Macro

      tx do
        {:ok, a} <- create_a_tx(value)
        {:ok, b} <- create_b_tx(a)
        {:ok, {a, b}}
      end

  will expands into:

      Tx.new(fn repo ->
        with {:ok, a} <- Tx.run(repo, create_a_tx(value)),
             {:ok, b} <- Tx.run(repo, create_b_tx(a)) do
          {:ok, {a, b}}
        end
      end)

  You can use `tx/2` if you need to access to a binding to `repo` from
  the transaction.
  """
  defmacro tx(do: {:__block__, _, body}), do: rewrite(nil, body, nil)
  defmacro tx(do: {:__block__, _, body}, else: e), do: rewrite(nil, body, e)

  defp rewrite(repo, body, else_) do
    repo = repo || Macro.var(:repo, __MODULE__)

    quote location: :keep do
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
    expr = rewrite_single_clause_if_and_unless(expr)

    run_expr =
      quote location: :keep do
        Tx.run(unquote(repo), unquote(expr))
      end

    {:<-, env, [pat, run_expr]}
  end

  defp rewrite_bind_clause(_repo, other), do: other

  defp rewrite_single_clause_if_and_unless([op, env, [cond_, do: then]])
       when op in [:if, :unless] do
    [op, env, [cond_, do: then, else: Macro.escape({:ok, nil})]]
  end

  defp rewrite_single_clause_if_and_unless(expr), do: expr
end
