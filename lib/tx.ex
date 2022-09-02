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
  @type t(a) :: fn_t(a) | Ecto.Multi.t()
  @type t :: t(any)

  @spec new(fn_t(a)) :: t(a)
  def new(f) when is_function(f, 1), do: f

  @spec pure(a) :: t(a)
  def pure(a), do: new(fn _ -> {:ok, a} end)

  @spec map(t(a), (a -> b)) :: t(b)
  def map(t, f) do
    new(fn repo ->
      case run(repo, t) do
        {:ok, a} -> {:ok, f.(a)}
        {:error, e} -> {:error, e}
      end
    end)
  end

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

  @spec execute(t(a), Ecto.Repo.t(), keyword()) :: {:ok, a} | {:error, any()}
  def execute(tx, repo, opts \\ []) do
    opts = Keyword.merge(@default_opts, opts)

    tx =
      tx
      |> rollback_on_error(Keyword.get(opts, :rollback_on_error))
      |> rollback_on_exception(Keyword.get(opts, :rollback_on_exception))

    case repo.transaction(tx, opts) do
      {:ok, {:ok, a}} -> {:ok, a}
      {:ok, {:error, e}} -> {:error, e}
      {:error, _, e, _} -> {:error, e}
      {:error, e} -> {:error, e}
    end
  end

  @spec rollback(Ecto.Repo.t(), any()) :: no_return()
  def rollback(repo, error) do
    repo.rollback(error)
  end

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

  @spec to_multi(t(a), any()) :: Ecto.Multi.t()
  def to_multi(tx, name) do
    Ecto.Multi.run(Ecto.Multi.new(), name, fn repo, _changes ->
      execute(tx, repo)
    end)
  end

  @spec concat(t(a), t(b)) :: t({a, b})
  def concat(a, b) do
    new(fn repo ->
      with {:ok, a_value} <- run(repo, a),
           {:ok, b_value} <- run(repo, b) do
        {:ok, {a_value, b_value}}
      end
    end)
  end

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

  @spec run(t(a), Ecto.Repo.t()) :: {:ok, a} | {:error, any()}
  def run(repo, %Ecto.Multi{} = tx), do: execute(tx, repo)

  def run(_repo, tx) when is_function(tx, 0),
    do: tx.()

  def run(repo, tx) when is_function(tx, 1),
    do: tx.(repo)

  @spec run!(t(a), Ecto.Repo.t()) :: a
  def run!(repo, tx) do
    case run(repo, tx) do
      {:ok, a} -> a
      {:error, e} -> raise e
    end
  end
end
