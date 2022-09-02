# Tx

Composable transaction as an alternative to Ecto.Multi.

## Examples

``` elixir
defmodule Foo do
  import Tx.Macro

  @spec create_post_tx(map()) :: Tx.t(Post.t())
  def create_post_tx(params) do

    # DB operations can be used in a transaction.
    tx repo do
      repo.insert(Post.changeset(params))
    end
  end

  @spec create_post_tx(Post.t(), map()) :: Tx.t(Comment.t())
  def create_comment_tx(post, params) do
    params = Map.put(params, :post_id, post.id)

    # Ecto.Multi operation can be used directly within transaction.
    tx do
      {:ok, %{comment: comment}} <-
        Multi.insert(Multi.new(), :comment, changeset(params))

      {:ok, comment}
    end
  end

  @spec create_dummy_post_tx([map()]) :: Tx.t(map())
  def create_dummy_post_tx(comments) do
    # You can compose multiple transactions freely, without
    # worrying about name collision.

    tx do
      {:ok, post} <- create_post_tx(%{content: "Hello"})
      # Tx.concat turns [Tx.t(a)] into Tx.t([a]).
      {:ok, comments} <- comments
                           |> Enum.map(&create_comment_tx(post, &1))
                           |> Tx.concat()

      response = %{
        id: post.id,
        comment_ids: Enum.map(comments, & &1.d)
      }

      {:ok, response}
    end
  end

  @spec actually_create_post() :: [map()]
  def actually_create_post do
    comments = [
      %{content: "first comment"},
      %{content: "second comment"},
      %{content: "third comment"}
    ]

    # Tx.execute/2 is equivalent to the Repo.transaction/1 callback.
    #
    # You can further customize rollback_on_error/rollback_on_exception
    # via options.
    case Tx.execute(create_dummy_post_tx(comments), Repo) do
      {:ok, post} -> post
      {:error, changeset} -> raise RuntimeError
    end
  end
end
```

## How does Tx works

Internally, a `Tx.t(a)` is defined as a closure of type `Ecto.Repo -> {:ok, a} | {:error, any}`.

Composing two transactions is then equivalent to the "bind" operation:

``` elixir
@spec bind(Tx.t(a), (a -> Tx.t(b))) :: Tx.t(b)
def bind(ta, tb) do
  fn repo ->
    ta_result <- ta.(repo)
    tb.(ta_result)
  end
end
```

This allows us to various composition operatoins. The `tx` macro is used to strip out most of the boilerplate. For example,

``` elixir
tx do
  {:ok, a} <- foo()
  # you can
  b <- bar(a)
  c = d
  {:ok, {a, b, c}}
end
```

is equivalent to:

``` elixir
fn repo ->
  with {:ok, a} <- foo().(repo)
       b <- bar(a).(repo)
       c = d do
    {:ok, {a, b, c}}
  end
end
```

On top of that, `Tx` implements various adaptation to use Ecto.Multi as a `Tx.t(%{name => result})` by executing the Multi in a sub-transaction.

## Installation

The package can be installed by adding `tx` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:tx, "~> 0.1.0"}
  ]
end
```
