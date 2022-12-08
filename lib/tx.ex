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

  @typedoc """
  You can put a value of any Tx type on the right of `<-` notation in Tx.Macro.

  A Tx type is any of the following:

  - A Tx function :: any function that takes in a repo and returns a
    `{:ok, a} | {:error, any()}` pair. You can create a Tx function
    via the `tx` macro, or any tx combinators like `Tx.new`,
    `Tx.pure`, `Tx.concat`.

  - An Ecto.Multi.t() :: equivalent a tx function that returns
    `{:ok, %{multi_name => value}}` or `{:error, multi_error}`

  - nil :: the same was as `Tx.pure(nil)`, which always
    returns `{:ok, nil}` when been run.

  - A list of any Tx type :: the same as `Tx.concat(list_of_tx)`, which returns
    `{:ok, list_of_results}` only if all `list_of_tx` succeeds.
  """
  @type t(a) :: fn_t(a) | Ecto.Multi.t() | nil | [t(any())]
  @type t :: t(any)

  @doc """
  Create a transaction.

  This function creates a Tx.t() from a function of type
  `(Ecto.Repo.t() -> {:ok, a} | {:error, any()})`.

  Internally, the `new/1` constructor simply returns the function as
  is.

  Example:

  iex> t = fn _repo -> {:ok, 42} end
  iex> Tx.execute(Tx.new(t), Repo)
  {:ok, 42}
  """
  @spec new(fn_t(a)) :: t(a)
  def new(f) when is_function(f, 1), do: f

  @doc """
  Create a transaction that returns a pure value.

  This is the "pure"/"return" operation if you're familiar with Monad.

  Executing Tx with a pure value always returns the value.

  `pure(a)` is equivalent to `new(fn _ -> {:ok, a} end)`.

  iex> Tx.execute(Tx.pure(42), Repo)
  {:ok, 42}
  """
  @spec pure(a) :: t(a)
  def pure(a), do: new(fn _ -> {:ok, a} end)

  @doc """
  Map over the successful result of a transaction.

  Example:

  iex> Tx.pure(1) |> Tx.map(&(&1 + 1)) |> Tx.execute(Repo)
  {:ok, 2}
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

  iex> Tx.pure(1) |> Tx.and_then(&{:error, &1}) |> Tx.execute(Repo)
  {:error, 1}
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
    |> conditional_then(
      opts[:rollback_on_error],
      &enable_rollback_on_error/1
    )
    |> conditional_then(
      not opts[:rollback_on_exception],
      &disable_rollback_on_exception/1
    )
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

  iex> Tx.new(fn repo ->
  ...>   if 1 == 1 do
  ...>     Tx.rollback(repo, "One cannot be equal to one")
  ...>   else
  ...>    {:ok, :fine}
  ...>   end
  ...> end)
  ...> |> Tx.execute(Repo)
  {:error, "One cannot be equal to one"}
  """
  @spec rollback(Ecto.Repo.t(), any()) :: no_return()
  def rollback(repo, error) do
    repo.rollback(error)
  end

  @doc """
  Make an transaction rollback on error.

  You can use this function to fine-tune the rollback behaviour on
  specific sub-transactions.
  """
  @spec enable_rollback_on_error(t(a)) :: t(a)
  def enable_rollback_on_error(trans) do
    new(fn repo ->
      case run(repo, trans) do
        {:ok, value} -> {:ok, value}
        {:error, e} -> repo.rollback(e)
      end
    end)
  end

  @doc """
  Avoid a transaction to rollback on exception.

  Wrap around `tx` with `rollback_on_exception(tx, false)` if
  you avoid `tx` to rollback on exception. When an exception occurs,
  you will get an `{:error, exception}` instead.
  """
  @spec disable_rollback_on_exception(t(a)) :: t(a)
  def disable_rollback_on_exception(tx) do
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

    EctoRepo.transaction(to_multi(pure(42), :foo)) => {:ok, %{foo: {:ok, 42}}}
  """
  @spec to_multi(t(a), any()) :: Ecto.Multi.t()
  def to_multi(tx, name) do
    Ecto.Multi.run(Ecto.Multi.new(), name, fn repo, _changes ->
      execute(tx, repo)
    end)
  end

  @doc """
  Combine two transactions `Tx.t(a)` and `Tx.t(b)` into a single `Tx.t({a, b})`.

  iex> Tx.concat(Tx.pure(1), Tx.pure(2)) |> Tx.execute(Repo)
  {:ok, {1, 2}}
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

  iex> Tx.concat([Tx.pure(1), Tx.pure(2)]) |> Tx.execute(Repo)
  {:ok, [1, 2]}
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

  This function should be rarely needed if you use the `Tx.Macro.tx`
  macro. You can simply use `a <- t` syntax instead of `a =
  Tx.run(repo, t)` within the `tx` macro.

  This function is meant to be used within a tx block or inside a Tx
  closure. If you want to get a value out of a Tx, you may want to
  call `execute/2` instead.
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

  This function should be rarely needed if you use the `Tx.Macro.tx`
  macro.
  """
  @spec run!(Ecto.Repo.t(), t(a)) :: a
  def run!(repo, tx) do
    case run(repo, tx) do
      {:ok, a} -> a
      {:error, e} -> raise e
    end
  end

  @spec conditional_then(any(), boolean(), (any() -> any())) :: any()
  defp conditional_then(input, condition, function) do
    if condition do
      function.(input)
    else
      input
    end
  end
end
