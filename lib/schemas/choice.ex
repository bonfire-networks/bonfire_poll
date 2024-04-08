defmodule Bonfire.Poll.Choice do
  use Needle.Virtual,
    otp_app: :bonfire_poll,
    table_id: "7CH01CES0RANSWERSAM0NGMANY",
    source: "bonfire_poll_choice"

  alias Bonfire.Poll.Choice
  alias Needle.Changesets

  virtual_schema do
  end

  def changeset(section \\ %Choice{}, params), do: Changesets.cast(section, params, [])
end

defmodule Bonfire.Poll.Choice.Migration do
  @moduledoc false
  import Needle.Migration
  alias Bonfire.Poll.Choice

  def migrate_choice(), do: migrate_virtual(Choice)
end
