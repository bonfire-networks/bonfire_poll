# SPDX-License-Identifier: AGPL-3.0-only
if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Poll.API.GraphQLMasto.Adapter do
    @moduledoc "Translates Mastodon poll requests into the shared GraphQL API."

    alias Bonfire.API.GraphQL.{RestAdapter, Schema}
    alias Bonfire.API.MastoCompat.{Fragments, Mappers}
    import Bonfire.API.MastoCompat.Helpers, only: [get_field: 2]

    @poll_fields """
    id
    __typename
    voting_format: votingFormat
    voting_close_at: votingCloseAt
    votes_count: votesCount
    voters_count: votersCount
    voted
    own_votes: ownVotes { id }
    choices { id post_content: postContent { name html_body: htmlBody summary } votes_result_total: votesResultTotal }
    """
    @poll_query "query($id: ID!) { poll(filter: {id: $id}) { #{@poll_fields} } }"
    @create_query """
    mutation($content: PostContentInput!, $choices: [PostContentInput], $format: String, $seconds: Int,
      $boundary: String, $circles: [ID], $boundaries: [String], $context: ID, $reply: ID) {
      createPoll(postContent: $content, choices: $choices, votingFormat: $format, durationSeconds: $seconds,
        boundary: $boundary, toCircles: $circles, toBoundaries: $boundaries,
        contextId: $context, replyTo: $reply) {
        #{@poll_fields}
        post_content: postContent { name html_body: htmlBody summary }
        activity { id subject { #{Fragments.actor_fields()} } #{Fragments.thread_fields()} }
      }
    }
    """
    @vote_query """
    mutation($id: String!, $votes: [VoteInput]) {
      vote(pollId: $id, votes: $votes, allowRevoting: false) { id }
    }
    """

    # Mastodon's documented poll limits (also advertised by the instance endpoint).
    @max_options 100
    @max_characters_per_option 50_000
    @min_expiration 60
    @max_expiration 31_536_000

    @poll_types %{
      options: {:array, :string},
      expires_in: :integer,
      multiple: :boolean,
      hide_totals: :boolean
    }

    @doc "Creates a poll through GraphQL, preserving the status adapter's resolved audience."
    def create_poll(params, opts) when is_map(params) do
      attrs = Keyword.fetch!(opts, :post_attrs)

      with [] <- Map.get(attrs, :uploaded_media, []),
           {:ok, poll} <- validate_poll(params) do
        variables = %{
          "content" => %{
            "htmlBody" => attrs.post_content.html_body,
            "summary" => attrs.post_content.summary
          },
          "choices" => Enum.map(poll.options, &%{"name" => &1}),
          "format" => if(poll.multiple, do: "multiple", else: "single"),
          "seconds" => poll.expires_in,
          "boundary" => opts[:boundary],
          "circles" => opts[:to_circles],
          "boundaries" => opts[:to_boundaries],
          "context" => opts[:context_id],
          "reply" => attrs.reply_to_id
        }

        run(@create_query, variables, "createPoll", opts[:current_user])
      else
        {:error, _} = error -> error
        _ -> {:error, {:unprocessable_entity, "Polls cannot include media attachments"}}
      end
    end

    def create_poll(_params, _opts),
      do: {:error, {:unprocessable_entity, "Invalid poll parameters"}}

    @doc "Loads the shared GraphQL poll representation for both status and poll responses."
    def read_poll(id, current_user) do
      run(@poll_query, %{"id" => id}, "poll", current_user)
    end

    @doc "GET /api/v1/polls/:id."
    def show_poll(%{"id" => id}, conn) do
      case read_poll(id, conn.assigns[:current_user]) do
        {:ok, poll} -> RestAdapter.json(conn, Mappers.Poll.from_question(poll))
        {:error, reason} -> RestAdapter.error_fn({:error, reason}, conn)
      end
    end

    @doc "POST /api/v1/polls/:id/votes; translates option indices into GraphQL choice IDs."
    def vote_on_poll(%{"id" => id} = params, conn) do
      RestAdapter.with_current_user(conn, fn current_user ->
        with {:ok, poll} <- read_poll(id, current_user),
             {:ok, votes} <- resolve_choice_indices(poll, params),
             variables = %{
               "id" => id,
               "votes" => Enum.map(votes, &%{"choiceId" => &1.choice_id, "weight" => "1"})
             },
             {:ok, _} <- run(@vote_query, variables, "vote", current_user),
             {:ok, updated} <- read_poll(id, current_user) do
          RestAdapter.json(conn, Mappers.Poll.from_question(updated))
        else
          {:error, reason} when reason in [:no_choices, :invalid_choices] ->
            RestAdapter.error_fn(
              {:error, {:unprocessable_entity, "Invalid choice indices"}},
              conn
            )

          {:error, reason} ->
            RestAdapter.error_fn({:error, reason}, conn)
        end
      end)
    end

    defp run(query, variables, field, current_user) do
      case Absinthe.run(query, Schema,
             variables: variables,
             context: Schema.context(%{current_user: current_user})
           ) do
        {:ok, %{errors: errors}} -> {:error, errors}
        {:ok, %{data: %{^field => %{} = result}}} -> {:ok, result}
        {:ok, %{data: _}} -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end

    defp validate_poll(params) do
      changeset =
        {%{multiple: false, hide_totals: false}, @poll_types}
        |> Ecto.Changeset.cast(params, Map.keys(@poll_types))
        |> Ecto.Changeset.validate_required([:options, :expires_in])
        |> Ecto.Changeset.validate_length(:options, min: 2, max: @max_options)
        |> Ecto.Changeset.validate_number(:expires_in,
          greater_than_or_equal_to: @min_expiration,
          less_than_or_equal_to: @max_expiration
        )
        |> Ecto.Changeset.validate_change(:options, fn :options, options ->
          if Enum.all?(options, &valid_option?/1),
            do: [],
            else: [options: "must contain nonempty options within the character limit"]
        end)

      cond do
        Ecto.Changeset.get_field(changeset, :hide_totals) == true ->
          {:error, {:unprocessable_entity, "Per-poll hidden totals are not supported"}}

        changeset.valid? ->
          {:ok, Ecto.Changeset.apply_changes(changeset)}

        true ->
          {:error, {:unprocessable_entity, "Invalid poll options or expiration"}}
      end
    end

    defp valid_option?(option) do
      is_binary(option) and String.trim(option) != "" and
        String.length(option) <= @max_characters_per_option
    end

    # Resolve Mastodon's 0-based choice indices to Bonfire choice IDs
    # The ordering must match what the Poll mapper uses (sorted by ID)
    defp resolve_choice_indices(question, params) do
      indices = extract_choice_indices(params)

      choices =
        (get_field(question, :choices) || [])
        |> List.wrap()
        |> Enum.sort_by(&get_field(&1, :id))

      cond do
        indices == [] ->
          {:error, :no_choices}

        not Enum.all?(indices, &(is_integer(&1) and &1 >= 0 and &1 < length(choices))) ->
          {:error, :invalid_choices}

        get_field(question, :voting_format) == "single" and length(Enum.uniq(indices)) > 1 ->
          {:error, :invalid_choices}

        true ->
          inputs =
            indices
            |> Enum.uniq()
            |> Enum.map(fn index ->
              %{choice_id: choices |> Enum.at(index) |> get_field(:id), weight: 1}
            end)

          {:ok, inputs}
      end
    end

    # Extract and parse choice indices from params
    # Handles both "choices" and "choices[]" parameter formats
    defp extract_choice_indices(params) do
      raw_choices = params["choices"] || params["choices[]"] || []

      raw_choices
      |> List.wrap()
      |> Enum.map(&parse_index/1)
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
