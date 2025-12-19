# SPDX-License-Identifier: AGPL-3.0-only
if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Poll.Web.MastoPollController do
    @moduledoc """
    Mastodon-compatible Polls API controller.

    Endpoints:
    - GET /api/v1/polls/:id - View a poll
    - POST /api/v1/polls/:id/votes - Vote on a poll
    """
    use Bonfire.UI.Common.Web, :controller

    alias Bonfire.Poll.API.GraphQLMasto.Adapter

    def show(conn, params), do: Adapter.show_poll(params, conn)
    def vote(conn, params), do: Adapter.vote_on_poll(params, conn)
  end
end
