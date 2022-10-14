defmodule Tx do
  @moduledoc """
  A simple composable transaction library that serves
  as an experimental alternative solution to Ecto.Multi.

  This library intend to tackle the main problem with Ecto.Multi:

  - Ecto.Multi names are global, which requires the caller of a
    multi-function to know about the names used in the multi.

  - Composing complex Ecto.Multi can run into name collision if not
    being careful enough.
  """

  @typep a :: term()
  @typep b :: term()

  @type fn_t(a) :: (Ecto.Repo.t() -> {:ok, a} | {:error, any()})
  @type t(a) :: fn_t(a) | Ecto.Multi.t() | nil
  @type t :: t(any) | [t(a)]

  @doc """
  Create a transaction.

  This function creates a Tx.t() from a function of type
  `(Ecto.Repo.t() -> {:ok, a} | {:error, any()})`.

  Internally, the `new/1` constructor simply returns the function as
  is.

  Example:

      t = fn repo -> {:ok, 42} end
      Tx.execute(Tx.new(t), Repo) == {:ok, 42}
  """
  @spec new(fn_t(a)) :: t(a)
  def new(f) when is_function(f, 1), do: f

  @doc """
  Create a transaction that returns a pure value.

  This is the "pure"/"return" operation if you're familiar with Monad.

  Property:

      Tx.execute(Tx.pure(x), Repo) == {:ok, x}
  """
  @spec pure(a) :: t(a)
  def pure(a), do: new(fn _ -> {:ok, a} end)

  @doc """
  Map over the successful result of a transaction.

  Example:

      Tx.pure(1) |> Tx.map(&(&1 + 1)) |> Tx.execute(Repo) == {:ok, 2}
  """
  @spec map(t(a), (a -> b)) :: t(b)
  def map(t, f) do
    new(fn repo ->
      case run(repo, t) do
        {:ok, a} -> {:ok, f.(a)}
        {:error, e} -> {:error, e}
      end
    end)
  end

  @doc """
  Compose two transactions. Run the second one only if the first one succeeds.

  This is the "bind" operation if you're familiar with Monad.

  Example:

      Tx.pure(1) |> Tx.and_then(&{:error, &1}) |> Tx.execute(Repo) == {:error, 1}
  """
  @spec and_then(t(a), (a -> t(b))) :: t(b)
  def and_then(t, f) when is_function(f, 1) do
    new(fn repo ->
      case run(repo, t) do
        {:ok, a} -> f.(a)
        {:error, e} -> {:error, e}
      end
    end)
  end

  @default_opts [
    rollback_on_error: true,
    rollback_on_exception: true
  ]

  @doc """
  Execute the transaction `Tx.t(a)`, producing an `{:ok, a}` or `{:error, any}`.

  Options:

  - rollback_on_error (Default: true): rollback transaction if the
    final result is an {:error, any()

  - rollback_on_exception (Default: true): rollback transaction
    if an uncaught exception arises within the transaction.

  - Any options Ecto.Repo.transaction/2 accepts.
  """
  @spec execute(t(a), Ecto.Repo.t(), keyword()) :: {:ok, a} | {:error, any}
  def execute(tx, repo, opts \\ []) do
    opts = Keyword.merge(@default_opts, opts)

    tx
    |> rollback_on_error(Keyword.get(opts, :rollback_on_error))
    |> rollback_on_exception(Keyword.get(opts, :rollback_on_exception))
    |> execute_raw(repo, opts)
  end

  # do not handle rollback on error or on exception
  @spec execute_raw(t(a), Ecto.Repo.t(), keyword()) :: {:ok, a} | {:error, any}
  defp execute_raw(tx, repo, opts) do
    case repo.transaction(tx, opts) do
      {:ok, {:ok, a}} -> {:ok, a}
      {:ok, {:error, e}} -> {:error, e}
      {:error, _, e, _} -> {:error, e}
      {:error, e} -> {:error, e}
    end
  end

  @doc """
  Rollback the current transaction.

  Example:

      Tx.new(fn repo ->
        if 1 == 1 do
          Tx.rollback(repo, "One cannot be equal to one")
        else
          :fine
        end
      end)
      |> Tx.execute(Repo)

  returns `{:error, "One cannot be equal to one"}` immediately, with
  all previous uncommited changes rolled back.
  """
  @spec rollback(Ecto.Repo.t(), any()) :: no_return()
  def rollback(repo, error) do
    repo.rollback(error)
  end

  @doc """
  Make an transaction rollback on error.

  You can use this function to fine-tune the rollback behaviour on
  specific sub-transactions.

  Please note that it does not support disabling rollback_on_error for
  sub-transactions.
  """
  @spec rollback_on_error(t(a), boolean()) :: t(a)
  def rollback_on_error(tx, rollback? \\ true)
  def rollback_on_error(tx, false), do: tx

  def rollback_on_error(trans, true) do
    new(fn repo ->
      case run(repo, trans) do
        {:ok, value} -> {:ok, value}
        {:error, e} -> repo.rollback(e)
      end
    end)
  end

  @doc """
  Make a transaction (not to) rollback on exception.

  Wrap around `tx` with `rollback_on_exception(tx, false)` if
  you avoid `tx` to rollback on exception. When an exception occurs,
  you will get an `{:error, exception}` instead.

  Please note that it does not support enabling rollback_on_exception for
  sub-transactions because that's the default behaviour.
  """
  @spec rollback_on_exception(t(a), boolean()) :: t(a)
  def rollback_on_exception(tx, rollback? \\ true)
  def rollback_on_exception(tx, true), do: tx

  def rollback_on_exception(tx, false) do
    new(fn repo ->
      try do
        run(repo, tx)
      rescue
        e -> {:error, e}
      end
    end)
  end

  @doc """
  Convert a `Tx.t(a)` into a `Multi.t()`.

  You can refer to the transactin's result (`{:ok, a} | {:error,
  any}`) by `name`.

      Ecto.transaction(to_multi(pure(42), :foo)) => {:ok, %{foo: {:ok, 42}}}
  """
  @spec to_multi(t(a), any()) :: Ecto.Multi.t()
  def to_multi(tx, name) do
    Ecto.Multi.run(Ecto.Multi.new(), name, fn repo, _changes ->
      execute(tx, repo)
    end)
  end

  @doc """
  Combine two transactions `Tx.t(a)` and `Tx.t(b)` into a single `Tx.t({a, b})`.

      Tx.concat(Tx.pure(1), Tx.pure(2)) |> Tx.execute(Repo) => {:ok, {1, 2}}
  """
  @spec concat(t(a), t(b)) :: t({a, b})
  def concat(a, b) do
    new(fn repo ->
      with {:ok, a_value} <- run(repo, a),
           {:ok, b_value} <- run(repo, b) do
        {:ok, {a_value, b_value}}
      end
    end)
  end

  @doc """
  Combine a list of transactions `[Tx.t(a)]` into a single `Tx.t([a])`.

      Tx.concat([Tx.pure(1), Tx.pure(2)]) |> Tx.execute(Repo) => {:ok, [1, 2]}
  """
  @spec concat([t(a)]) :: t([a])
  def concat([]), do: pure([])

  def concat([x | xs]) do
    new(fn repo ->
      with {:ok, x_value} <- run(repo, x),
           {:ok, xs_value} <- run(repo, concat(xs)) do
        {:ok, [x_value | xs_value]}
      end
    end)
  end

  @doc """
  Run a transaction to get its result.

  This is a generic adapter for extracting a `{:ok, a} | {:error, any()}` from
  a transaction when given a repo.

  - For normal transaction `tx` as a function (default), it simply call tx.(repo)
  - For Ecto.Multi, it creates a sub-transaction to execute it
  - For a non-transactional value, it simply returns the value

  This function should be rarely needed if you use the `Tx.Macro.tx` macro.
  """
  @spec run(Ecto.Repo.t(), t(a) | any()) :: {:ok, a} | {:error, any()}
  def run(repo, xs) when is_list(xs), do: run(repo, Tx.concat(xs))
  def run(_repo, nil), do: {:ok, nil}

  def run(repo, %Ecto.Multi{} = multi) do
    case repo.transaction(multi) do
      {:ok, map} ->
        {:ok, map}

      {:error, _multi_name, multi_error, _} ->
        {:error, multi_error}
    end
  end

  def run(_repo, tx) when is_function(tx, 0),
    do: tx.()

  def run(repo, tx) when is_function(tx, 1),
    do: tx.(repo)

  # To support matching pure results in tx macro. For example,
  #
  #     tx repo do
  #       {:ok, foo} <- repo.insert(changeset)
  #       ...
  #     end
  #
  def run(_repo, {:ok, a}), do: {:ok, a}
  def run(_repo, {:error, e}), do: {:error, e}

  # This last clause should cover previous two clauses.  I decided to
  # kept them to be explicit.
  def run(_repo, other), do: other

  @doc """
  The raising version of `run/2`.

  This function should be rarely needed if you use the `Tx.Macro.tx` macro.
  """
  @spec run!(Ecto.Repo.t(), t(a)) :: a
  def run!(repo, tx) do
    case run(repo, tx) do
      {:ok, a} -> a
      {:error, e} -> raise e
    end
  end
end
