# Test helper for PhoenixKitBookings test suite.
#
# Level 1: Unit tests (schemas, changesets, pure engine functions) always run.
# Level 2: Integration tests require PostgreSQL — automatically excluded
#          when the database is unavailable (`:integration` tag).
#
# To enable integration tests:
#
#     mix test.setup           # createdb + migrate
#     mix test

support_dir = Path.expand("support", __DIR__)

[
  "test_repo.ex",
  "schema_migration.ex",
  "test_layouts.ex",
  "hooks.ex",
  "test_router.ex",
  "test_endpoint.ex",
  "fixtures.ex",
  "data_case.ex",
  "live_case.ex"
]
|> Enum.each(&Code.require_file(&1, support_dir))

# Check if the test database exists
db_name =
  Application.get_env(:phoenix_kit_bookings, PhoenixKitBookings.Test.Repo)[:database] ||
    "phoenix_kit_bookings_test"

# The preflight ships in core, and this module's core floor (`~> 2.0`)
# predates it — so it is used when the running core has it, and otherwise
# this falls through to exactly the previous behaviour.
db_check =
  if Code.ensure_loaded?(PhoenixKit.TestSupport.PostgresPreflight) do
    # One classified connection attempt, with the repo's OWN credentials and
    # transport, before anything starts the pool.
    #
    # This replaces a `psql -lqt` listing. That check asked the wrong question:
    # it ran as the shell's user over a unix socket, so it reported "the
    # database is there" and said nothing about whether the CONFIGURED role
    # could reach it over TCP. When it could not, the answer arrived minutes
    # later as a pool checkout timeout that reads like a flaky test.
    case PhoenixKit.TestSupport.PostgresPreflight.check(
           Application.get_env(:phoenix_kit_bookings, PhoenixKitBookings.Test.Repo, [])
         ) do
      :ok ->
        :exists

      {:error, _reason, message} ->
        IO.puts(:stderr, "\n" <> message)
        :not_found
    end
  else
    :try_connect
  end

repo_available =
  if db_check == :not_found do
    IO.puts("""
    \n⚠  Cannot reach test database "#{db_name}" — integration tests will be excluded.
       The reason is printed above.
    """)

    false
  else
    try do
      {:ok, _} = PhoenixKitBookings.Test.Repo.start_link()

      # Build core's tables (settings, activities, users, uuid_generate_v7())
      # by running phoenix_kit's own versioned migrations directly.
      PhoenixKit.Migration.ensure_current(PhoenixKitBookings.Test.Repo, log: false)

      # This module's own tables aren't part of core's migration chain (see
      # `migration_module/0` on `PhoenixKitBookings`) — apply them the same
      # way `mix phoenix_kit.update` would in a real host app.
      Ecto.Migrator.run(
        PhoenixKitBookings.Test.Repo,
        [
          {1, PhoenixKitBookings.Test.SchemaMigration},
          {2, PhoenixKitBookings.Test.SchemaMigrationV2}
        ],
        :up,
        all: true,
        log: false
      )

      # Enable the module BEFORE sandbox mode so the row commits for every
      # test — `Scope.can?/2` gates on module enablement, so Policy checks
      # would otherwise fail closed across the whole suite.
      PhoenixKit.Settings.update_boolean_setting_with_module(
        "bookings_enabled",
        true,
        "bookings"
      )

      Ecto.Adapters.SQL.Sandbox.mode(PhoenixKitBookings.Test.Repo, :manual)
      true
    rescue
      e ->
        IO.puts("""
        \n⚠  Could not connect to test database — integration tests will be excluded.
           The reason is printed above.
           Error: #{Exception.message(e)}
        """)

        false
    catch
      :exit, reason ->
        IO.puts("""
        \n⚠  Could not connect to test database — integration tests will be excluded.
           The reason is printed above.
           Error: #{inspect(reason)}
        """)

        false
    end
  end

Application.put_env(:phoenix_kit_bookings, :test_repo_available, repo_available)

# Start minimal PhoenixKit services so the module's runtime dependencies
# (PubSub topics, ModuleRegistry) resolve during tests.
{:ok, _pid} = PhoenixKit.PubSub.Manager.start_link([])
{:ok, _pid} = PhoenixKit.ModuleRegistry.start_link([])

exclude = if repo_available, do: [], else: [:integration]

# Force PhoenixKit's URL prefix cache to "/" for tests so Paths helpers
# produce paths the test router can match.
:persistent_term.put({PhoenixKit.Config, :url_prefix}, "/")

if repo_available do
  {:ok, _} = PhoenixKitBookings.Test.Endpoint.start_link()
end

ExUnit.start(exclude: exclude)
