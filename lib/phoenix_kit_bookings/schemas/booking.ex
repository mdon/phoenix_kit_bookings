defmodule PhoenixKitBookings.Schemas.Booking do
  @moduledoc """
  A reservation of one seat of a service.

  Exactly one time shape per row (DB CHECK `bookings_time_shape`, mirrors
  the `phoenix_kit_calendar` V141 convention):

  - **Timed** (`minutes` services): `starts_at`/`ends_at` UTC pair,
    exclusive end.
  - **Dated** (`day`/`night` services): `starts_on`/`ends_on` DATE pair,
    exclusive end — a Fri→Sun hotel stay is `starts_on: Fri, ends_on: Sun`
    (2 nights). Check-in/out clock times are service attributes, never
    range data.

  The time fields, `service_uuid`, `user_uuid`, `status` and `source` are
  never cast from attrs — `PhoenixKitBookings.Bookings` computes and
  `put_change`s them after the engine validates the request. The changeset
  casts only what a customer types.

  Lifecycle: `pending` (approval-required services) → `confirmed` →
  `cancelled`. Cancelled rows keep their time fields but stop counting
  toward capacity.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  import Ecto.Changeset

  alias PhoenixKitBookings.Engine

  @statuses ~w(pending confirmed cancelled)
  @sources ~w(public admin)

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  schema "phoenix_kit_bookings_bookings" do
    field(:service_uuid, UUIDv7)
    field(:status, :string, default: "confirmed")

    field(:starts_at, :utc_datetime)
    field(:ends_at, :utc_datetime)
    # The site's zone value when a timed booking was made (an IANA id or a
    # legacy offset, as core keeps it), so the wall clock the customer picked
    # can be re-resolved on its own. Nil on day/night bookings (dates carry
    # no zone) and on rows written before the column existed.
    field(:time_zone, :string)
    field(:starts_on, :date)
    field(:ends_on, :date)

    field(:customer_name, :string)
    field(:customer_email, :string)
    field(:customer_phone, :string)
    field(:notes, :string)

    field(:user_uuid, UUIDv7)
    field(:unit_uuid, UUIDv7)
    field(:total_price, :decimal)
    field(:currency, :string)
    field(:source, :string, default: "public")
    field(:cancelled_at, :utc_datetime)
    field(:cancel_reason, :string)
    field(:metadata, :map, default: %{})

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  def statuses, do: @statuses
  def sources, do: @sources

  @doc "Casts only customer-supplied fields."
  def customer_changeset(booking, attrs) do
    booking
    |> cast(attrs, [:customer_name, :customer_email, :customer_phone, :notes])
    |> validate_required([:customer_name, :customer_email])
    |> validate_length(:customer_name, max: 255)
    |> validate_length(:customer_email, max: 255)
    |> validate_length(:customer_phone, max: 50)
    |> validate_length(:notes, max: 2000)
    |> validate_format(:customer_email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
      message: "must be a valid email address"
    )
  end

  @doc """
  Stamps the validated time range, ownership and lifecycle onto a customer
  changeset. `range` is `{starts_at, ends_at}` (DateTime) or
  `{:dates, starts_on, ends_on}` (Date).
  """
  def stamp_changeset(changeset, service_uuid, range, opts) do
    changeset
    |> put_change(:service_uuid, service_uuid)
    |> put_range(range)
    |> put_change(:status, Keyword.fetch!(opts, :status))
    |> put_change(:source, Keyword.fetch!(opts, :source))
    |> maybe_put_user(Keyword.get(opts, :user_uuid))
    |> check_constraint(:starts_at, name: :bookings_time_shape)
    |> check_constraint(:starts_at, name: :bookings_timed_order)
    |> check_constraint(:starts_on, name: :bookings_dated_order)
    |> check_constraint(:status, name: :bookings_status)
  end

  defp put_range(changeset, {%DateTime{} = starts_at, %DateTime{} = ends_at}) do
    changeset
    |> put_change(:starts_at, DateTime.truncate(starts_at, :second))
    |> put_change(:ends_at, DateTime.truncate(ends_at, :second))
    |> put_change(:time_zone, Engine.site_tz())
    |> validate_length(:time_zone, max: 64)
  end

  defp put_range(changeset, {:dates, %Date{} = starts_on, %Date{} = ends_on}) do
    changeset
    |> put_change(:starts_on, starts_on)
    |> put_change(:ends_on, ends_on)
  end

  defp maybe_put_user(changeset, nil), do: changeset
  defp maybe_put_user(changeset, user_uuid), do: put_change(changeset, :user_uuid, user_uuid)

  @doc "Controlled status transition — never cast from attrs."
  def status_changeset(booking, status, opts \\ []) when status in @statuses do
    booking
    |> change(status: status)
    |> maybe_stamp_cancellation(status, opts)
  end

  defp maybe_stamp_cancellation(changeset, "cancelled", opts) do
    changeset
    |> put_change(:cancelled_at, DateTime.truncate(DateTime.utc_now(), :second))
    |> put_change(:cancel_reason, Keyword.get(opts, :reason))
  end

  defp maybe_stamp_cancellation(changeset, _status, _opts), do: changeset

  @doc "True when the booking still occupies capacity."
  def active?(%__MODULE__{status: status}), do: status in ["pending", "confirmed"]
end
