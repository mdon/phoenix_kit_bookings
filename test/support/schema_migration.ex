defmodule PhoenixKitBookings.Test.SchemaMigration do
  @moduledoc """
  Thin `Ecto.Migration` wrapper that runs
  `PhoenixKitBookings.Migrations.Schema` against the test repo.

  `Schema.up/1` uses `Ecto.Migration`'s `execute/1`, which only works
  inside an active `Ecto.Migration.Runner`. In production,
  `mix phoenix_kit.update` generates exactly this kind of wrapper as a
  real migration file under the host app's `priv/repo/migrations/`;
  `test_helper.exs` runs this one in-memory via `Ecto.Migrator.run/4`.
  """

  use Ecto.Migration

  alias PhoenixKitBookings.Migrations.Schema

  def up, do: Schema.up(prefix: "public")
  def down, do: Schema.down(prefix: "public")
end

defmodule PhoenixKitBookings.Test.SchemaMigrationV2 do
  @moduledoc """
  The V2 wrapper — what `mix phoenix_kit.update` would generate for a host
  whose database already carries V1: `Schema.up/1` is idempotent, so
  replaying it adds only what V2 adds and restamps the marker; `down/0` goes
  back to V1 without dropping the tables.
  """
  use Ecto.Migration

  alias PhoenixKitBookings.Migrations.Schema

  def up, do: Schema.up(prefix: "public")
  def down, do: Schema.down(prefix: "public", version: 1)
end
