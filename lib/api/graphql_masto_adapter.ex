# SPDX-License-Identifier: AGPL-3.0-only
if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Poll.API.GraphQLMasto.Adapter do
    @moduledoc """
    Mastodon-compatible Poll API endpoints.

    Handles viewing polls and voting on them. Uses direct domain calls
    to the well-established context functions in `Bonfire.Poll`.
    """

    use Bonfire.Common.Utils
    use Bonfire.Common.Repo

    alias Bonfire.API.GraphQL.RestAdapter
    alias Bonfire.API.MastoCompat.Mappers
    alias Bonfire.Poll.Questions
    alias Bonfire.Poll.Votes

    @doc """
    GET /api/v1/polls/:id

    Returns a poll by ID. Public if parent status is public,
    requires authentication for private polls.
    """
    def show_poll(%{"id" => id}, conn) do
      current_user = conn.assigns[:current_user]

      case Questions.read(id, current_user: current_user) do
        {:ok, question} ->
          poll = Mappers.Poll.from_question(question, current_user: current_user)
          RestAdapter.json(conn, poll)

        _ ->
          RestAdapter.error_fn({:error, :not_found}, conn)
      end
    end

    @doc """
    POST /api/v1/polls/:id/votes

    Vote on a poll. Requires authentication. The `choices[]` parameter
    contains 0-based indices of the choices to vote for.

    Returns 422 if:
    - Poll has expired
    - User has already voted
    - Invalid choice indices
    """
    def vote_on_poll(%{"id" => id} = params, conn) do
      RestAdapter.with_current_user(conn, fn current_user ->
        # First fetch the poll to resolve choice indices to IDs
        with {:ok, question} <- Questions.read(id, current_user: current_user),
             {:ok, choice_inputs} <- resolve_choice_indices(question, params),
             {:ok, _vote_activity} <- Votes.vote(current_user, question, choice_inputs, []) do
          # Refetch poll to get updated state with vote counts
          case Questions.read(id, current_user: current_user) do
            {:ok, updated_question} ->
              poll = Mappers.Poll.from_question(updated_question, current_user: current_user)
              RestAdapter.json(conn, poll)

            _ ->
              RestAdapter.error_fn({:error, :not_found}, conn)
          end
        else
          {:error, "Voting is not open for this poll"} ->
            RestAdapter.error_fn({:error, :poll_expired}, conn)

          {:error, :invalid_choices} ->
            RestAdapter.error_fn({:error, "Invalid choice indices"}, conn)

          {:error, :no_choices} ->
            RestAdapter.error_fn({:error, "choices[] parameter is required"}, conn)

          {:error, reason} ->
            RestAdapter.error_fn({:error, reason}, conn)

          _ ->
            RestAdapter.error_fn({:error, :not_found}, conn)
        end
      end)
    end

    # Resolve Mastodon's 0-based choice indices to Bonfire choice IDs
    # The ordering must match what the Poll mapper uses (sorted by ID)
    defp resolve_choice_indices(question, params) do
      indices = extract_choice_indices(params)

      if Enum.empty?(indices) do
        {:error, :no_choices}
      else
        # Get choices in same order as mapper (sorted by ID)
        choices =
          e(question, :choices, [])
          |> List.wrap()
          |> Enum.sort_by(&e(&1, :id, ""))

        choice_inputs =
          indices
          |> Enum.map(fn idx ->
            choice = Enum.at(choices, idx)
            if choice, do: %{choice_id: e(choice, :id, nil), weight: 1}, else: nil
          end)
          |> Enum.reject(&is_nil/1)

        if Enum.empty?(choice_inputs) do
          {:error, :invalid_choices}
        else
          {:ok, choice_inputs}
        end
      end
    end

    # Extract and parse choice indices from params
    # Handles both "choices" and "choices[]" parameter formats
    defp extract_choice_indices(params) do
      raw_choices = params["choices"] || params["choices[]"] || []

      raw_choices
      |> List.wrap()
      |> Enum.map(&parse_index/1)
      |> Enum.reject(&is_nil/1)
    end

    defp parse_index(idx) when is_integer(idx), do: idx

    defp parse_index(idx) when is_binary(idx) do
      case Integer.parse(idx) do
        {int, ""} -> int
        _ -> nil
      end
    end

    defp parse_index(_), do: nil
  end
end
