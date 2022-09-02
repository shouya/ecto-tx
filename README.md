# Tx

Composable transaction as an alternative to Ecto.Multi.

- Hex.pm: https://hex.pm/packages/tx
- API references: https://hexdocs.pm/tx

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

  @spec actually_create_post() :: map() | no_return()
  def actually_create_post do
    comments = [
      %{content: "first comment"},
      %{content: "second comment"},
      %{content: "third comment"}
    ]

    # Tx.execute/2 is equivalent to the Repo.transaction/1 callback.
    case Tx.execute(create_dummy_post_tx(comments), Repo) do
      {:ok, post} -> post
      {:error, changeset} -> raise RuntimeError
    end
  end
end
```

## Implementation detail

Internally, a `Tx.t(a)` is defined as a closure with type `Ecto.Repo -> {:ok, a} | {:error, any}`.

Composing two transactions is then equivalent to the Monad "bind" operation (See `Tx.and_then/2`):

``` elixir
@spec and_then(Tx.t(a), (a -> Tx.t(b))) :: Tx.t(b)
def and_then(ta, tb) do
  fn repo ->
    ta_result <- ta.(repo)
    tb.(ta_result).(repo)
  end
end
```

The `tx` macro is used to strip out most of the boilerplate. For
example,

``` elixir
tx do
  {:ok, a} <- foo()
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

On top of that, `Tx` implements adaptation to use Ecto.Multi as a
`Tx.t(%{name => result})` by executing the `Ecto.Multi` via a
nested transaction.

## Installation

The package can be installed by adding `tx` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:tx, "~> 0.1.1"}
  ]
end
```
