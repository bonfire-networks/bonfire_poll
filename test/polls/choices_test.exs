defmodule Bonfire.Poll.ChoicesTest do
  use Bonfire.Poll.DataCase, async: true
  use Bonfire.Common.Repo
  import Bonfire.Me.Fake
  import Bonfire.Poll.Fake

  describe "choice creation, linking, and querying" do
    test "creates choices and links to question" do
      choices = [%{name: "Option 1"}, %{name: "Option 2"}]
      {:ok, question} = fake_question_with_choices(%{}, choices)
      assert Enum.all?(question.choices, & &1.id)
      assert Enum.map(question.choices, & &1.post_content.name) == ["Option 1", "Option 2"]
    end

    test "adds choices to an existing question" do
      user = Bonfire.Me.Fake.fake_user!()
      {:ok, question} = fake_question(%{post_content: %{name: "Q"}}, current_user: user)
      {:ok, choice_id1} = fake_choice(question, %{name: "Extra 1"})
      {:ok, choice_id2} = fake_choice(question, %{name: "Extra 2"})
      # Reload question to get updated choices
      {:ok, reloaded} = Bonfire.Poll.Questions.read(question.id, current_user: user)
      names = Enum.map(reloaded.choices, & &1.post_content.name)
      assert "Extra 1" in names
      # FIXME
      assert "Extra 2" in names
    end

    test "lists choices for a question" do
      choices = [%{name: "A"}, %{name: "B"}]
      {:ok, question} = fake_question_with_choices(%{}, choices)
      assert length(question.choices) == 2
    end

    test "removes a choice from a question" do
      user = Bonfire.Me.Fake.fake_user!()
      choices = [%{name: "ToRemove"}, %{name: "ToKeep"}]
      {:ok, question} = fake_question_with_choices(%{}, choices, current_user: user)
      choice_to_remove = Enum.find(question.choices, &(&1.post_content.name == "ToRemove"))
      Bonfire.Poll.Choices.remove_choice(choice_to_remove.id, question.id)
      {:ok, reloaded} = Bonfire.Poll.Questions.read(question.id, current_user: user)
      names = Enum.map(reloaded.choices, & &1.post_content.name)
      refute "ToRemove" in names
      assert "ToKeep" in names
    end
  end

  describe "Bonfire.Poll.Choices.simple_create_and_put/4" do
    test "creates and associates choices with a question" do
      user = Bonfire.Me.Fake.fake_user!()

      question =
        Bonfire.Poll.Questions.create(
          current_user: user,
          question_attrs: %{post_content: %{html_body: "Test question"}}
        )
        |> elem(1)

      choices_attrs = [
        %{name: "Option 1"},
        %{name: "Option 2"},
        %{name: "Option 3"}
      ]

      assert {:ok, result} =
               Bonfire.Poll.Choices.simple_create_and_put(nil, choices_attrs, question,
                 current_user: user
               )

      assert is_list(result)
      assert length(result) == 3
      # Check that each choice is associated with the question
      for {:ok, choice_id} <- result do
        assoc =
          Bonfire.Data.Assort.Ranked |> repo().get_by(item_id: choice_id, scope_id: question.id)

        assert assoc
      end
    end
  end

  describe "Bonfire.Poll.Choices.simple_create_and_put/4 input shapes" do
    # Phoenix submits `choices[N][...]` as a string-keyed indexed map,
    # which Bonfire's `Enums.input_to_atoms/2` opportunistically converts
    # to atoms whenever `:"N"` already exists in the BEAM atom table,
    # producing mixed-key maps. These tests lock in that
    # `simple_create_and_put` handles every shape it might be called with.

    setup do
      user = Bonfire.Me.Fake.fake_user!()

      {:ok, question} =
        Bonfire.Poll.Questions.create(
          current_user: user,
          question_attrs: %{post_content: %{html_body: "shape test"}}
        )

      {:ok, user: user, question: question}
    end

    test "list of attrs", %{user: user, question: question} do
      assert {:ok, choices} =
               Bonfire.Poll.Choices.simple_create_and_put(
                 nil,
                 [%{name: "list-1"}, %{name: "list-2"}],
                 question,
                 current_user: user
               )

      assert length(choices) == 2
    end

    test "string-keyed indexed map", %{user: user, question: question} do
      assert {:ok, choices} =
               Bonfire.Poll.Choices.simple_create_and_put(
                 nil,
                 %{"0" => %{name: "str-0"}, "1" => %{name: "str-1"}},
                 question,
                 current_user: user
               )

      assert length(choices) == 2
    end

    test "atom-keyed indexed map", %{user: user, question: question} do
      assert {:ok, choices} =
               Bonfire.Poll.Choices.simple_create_and_put(
                 nil,
                 %{:"0" => %{name: "atom-0"}, :"1" => %{name: "atom-1"}},
                 question,
                 current_user: user
               )

      assert length(choices) == 2
    end

    test "mixed-key indexed map (the regression that bit us)",
         %{user: user, question: question} do
      # This shape is what `Enums.input_to_atoms/2` produces when only some
      # of the numeric atoms happen to be in the BEAM atom table. Before
      # the `indexed_map?/1` dispatch in `normalise_choices_input/1`, this
      # silently fell through to the single-choice path and saved zero.
      assert {:ok, choices} =
               Bonfire.Poll.Choices.simple_create_and_put(
                 nil,
                 %{"0" => %{name: "mixed-0"}, :"1" => %{name: "mixed-1"}},
                 question,
                 current_user: user
               )

      assert length(choices) == 2
    end

    test "empty-named entries are dropped from a list",
         %{user: user, question: question} do
      assert {:ok, choices} =
               Bonfire.Poll.Choices.simple_create_and_put(
                 nil,
                 [%{name: "kept"}, %{name: ""}, %{name: "   "}, %{name: nil}],
                 question,
                 current_user: user
               )

      assert length(choices) == 1
    end

    test "empty-named entries are dropped from an indexed map",
         %{user: user, question: question} do
      assert {:ok, choices} =
               Bonfire.Poll.Choices.simple_create_and_put(
                 nil,
                 %{"0" => %{name: ""}, "1" => %{name: "kept"}, "2" => %{name: nil}},
                 question,
                 current_user: user
               )

      assert length(choices) == 1
    end

    test "indices preserve order regardless of map iteration",
         %{user: user, question: question} do
      # Pass keys out of order; the function should sort by numeric index
      # so the persisted Ranked rows reflect the form's order.
      assert {:ok, choices} =
               Bonfire.Poll.Choices.simple_create_and_put(
                 nil,
                 %{"2" => %{name: "third"}, "0" => %{name: "first"}, "1" => %{name: "second"}},
                 question,
                 current_user: user
               )

      assert length(choices) == 3

      # Each Ranked row's rank_set captures the index passed in. ULIDs
      # encode insertion time, so sorting by id mirrors the call order;
      # mapping back through PostContent should yield the form's order.
      import Ecto.Query

      ranked_ids =
        Bonfire.Common.Repo.all(
          from r in Bonfire.Data.Assort.Ranked,
            where: r.scope_id == ^question.id,
            order_by: r.id,
            select: r.item_id
        )

      names =
        Bonfire.Common.Repo.all(
          from pc in Bonfire.Data.Social.PostContent,
            where: pc.id in ^ranked_ids,
            select: {pc.id, pc.name}
        )
        |> Map.new()

      assert Enum.map(ranked_ids, &Map.get(names, &1)) == ["first", "second", "third"]
    end
  end

  describe "Bonfire.Poll.Choices.add_proposal/3" do
    setup do
      user = Bonfire.Me.Fake.fake_user!()
      proposer = Bonfire.Me.Fake.fake_user!()

      # A question with the proposal window currently open.
      {:ok, question} =
        Bonfire.Poll.Questions.create(
          current_user: user,
          boundary: "public",
          question_attrs: %{
            post_content: %{name: "Decision"},
            voting_format: "weighted_multiple",
            proposal_dates: [
              DateTime.utc_now() |> DateTime.add(-3600, :second),
              DateTime.utc_now() |> DateTime.add(3600, :second)
            ],
            voting_dates: [
              DateTime.utc_now() |> DateTime.add(3600, :second),
              DateTime.utc_now() |> DateTime.add(7200, :second)
            ]
          }
        )

      {:ok, user: user, proposer: proposer, question: question}
    end

    test "creates the choice and attaches the proposer as creator", %{
      proposer: proposer,
      question: question
    } do
      assert {:ok, choice} =
               Bonfire.Poll.Choices.add_proposal(
                 question.id,
                 %{name: "Suggested by proposer"},
                 current_user: proposer
               )

      assert choice.id

      reloaded =
        Bonfire.Common.Repo.maybe_preload(
          choice,
          [post_content: [], created: [creator: [:character]]],
          current_user: proposer
        )

      assert reloaded.post_content.name == "Suggested by proposer"
      assert reloaded.created.creator.id == proposer.id

      # The choice is linked into the question's ranked list.
      assert Bonfire.Data.Assort.Ranked
             |> Bonfire.Common.Repo.get_by(item_id: choice.id, scope_id: question.id)
    end

    test "refuses when proposal phase isn't open", %{proposer: proposer, user: user} do
      {:ok, closed} =
        Bonfire.Poll.Questions.create(
          current_user: user,
          boundary: "public",
          question_attrs: %{
            post_content: %{name: "Already voting"},
            voting_format: "weighted_multiple",
            # Proposal phase entirely in the past.
            proposal_dates: [
              DateTime.utc_now() |> DateTime.add(-7200, :second),
              DateTime.utc_now() |> DateTime.add(-3600, :second)
            ],
            voting_dates: [
              DateTime.utc_now() |> DateTime.add(-3600, :second),
              DateTime.utc_now() |> DateTime.add(3600, :second)
            ]
          }
        )

      assert {:error, :proposal_phase_closed} =
               Bonfire.Poll.Choices.add_proposal(
                 closed.id,
                 %{name: "too late"},
                 current_user: proposer
               )
    end

    test "rejects an empty name", %{proposer: proposer, question: question} do
      assert {:error, :name_required} =
               Bonfire.Poll.Choices.add_proposal(
                 question.id,
                 %{name: "   "},
                 current_user: proposer
               )
    end
  end

  describe "Bonfire.Poll.Choices.put_choice/3" do
    test "associates an existing choice with a question and sets position" do
      user = Bonfire.Me.Fake.fake_user!()

      question =
        Bonfire.Poll.Questions.create(
          current_user: user,
          question_attrs: %{post_content: %{html_body: "Test question"}}
        )
        |> elem(1)

      choice_attrs = %{post_content: %{name: "Standalone Option"}}

      cs =
        Bonfire.Social.PostContents.cast(%Bonfire.Poll.Choice{}, choice_attrs, user, "public", [])

      {:ok, choice} = repo().insert(cs)
      {:ok, assoc} = Bonfire.Poll.Choices.put_choice(choice.id, question.id, 5)
      assert assoc.rank_set == 5
      assert assoc.scope_id == question.id
      assert assoc.item_id == choice.id
    end
  end
end
