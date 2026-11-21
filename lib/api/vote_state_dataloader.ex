if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Poll.API.VoteStateDataloader do
    @moduledoc "Dataloader.KV source for the poll fields, batched per GraphQL request: each poll's vote state for the viewer (`Votes.preview_vote_state_for_questions/2`) and its choices."

    alias Bonfire.Poll.{Question, Votes}

    def data, do: Dataloader.KV.new(&fetch/2)

    # keys are `%{question_id: id, user_id: id | nil}`; one request has one viewer, grouped anyway
    def fetch(:vote_state, keys) do
      keys
      |> Enum.group_by(& &1.user_id)
      |> Enum.flat_map(fn {user_id, keys} ->
        states =
          Votes.preview_vote_state_for_questions(Enum.map(keys, & &1.question_id), user_id)

        Enum.map(keys, &{&1, Map.get(states, &1.question_id, Votes.empty_preview_vote_state())})
      end)
      |> Map.new()
    end

    # keys are question ids; a plain preload, as the per-poll `maybe_preload` did, not the boundarised Needle source
    def fetch(:choices, question_ids) do
      question_ids
      |> Enum.map(&%Question{id: &1})
      |> Bonfire.Common.Repo.preload(choices: [:post_content])
      |> Map.new(&{&1.id, &1.choices})
    end

    def fetch(_batch, keys), do: Map.new(keys, &{&1, nil})
  end
end
