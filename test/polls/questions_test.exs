defmodule Bonfire.Poll.QuestionsTest do
  use Bonfire.Poll.DataCase, async: false
  import Bonfire.Me.Fake
  import Bonfire.Poll.Fake

  describe "question creation and querying" do
    test "creates a question with defaults" do
      {:ok, question} = fake_question()
      assert question.id
      assert question.post_content[:name]
    end

    test "creates a question with choices" do
      choices = [%{name: "Yes"}, %{name: "No"}]
      {:ok, question} = fake_question_with_choices(%{}, choices)
      assert length(question.choices) == 2
    end

    test "fetches a question by id" do
      user = Bonfire.Me.Fake.fake_user!()
      {:ok, question} = fake_question(%{}, current_user: user)
      {:ok, fetched} = Bonfire.Poll.Questions.read(question.id, current_user: user)
      assert fetched.id == question.id
    end

    test "lists questions paginated" do
      user = Bonfire.Me.Fake.fake_user!()
      {:ok, _} = fake_question(%{post_content: %{name: "Q1"}}, current_user: user)
      {:ok, _} = fake_question(%{post_content: %{name: "Q2"}}, current_user: user)
      results = Bonfire.Poll.Questions.list_paginated([], current_user: user)
      assert Enum.count(results) >= 2
    end
  end

  test "voting_open?/1 and voting_ended?/1" do
    now = DateTime.utc_now()
    past = DateTime.add(now, -3600, :second)
    future = DateTime.add(now, 3600, :second)
    {:ok, question} = fake_question(%{voting_dates: [past, future]})
    assert Bonfire.Poll.Questions.voting_open?(question)
    refute Bonfire.Poll.Questions.voting_ended?(question)

    {:ok, ended_question} = fake_question(%{voting_dates: [past, past]})
    refute Bonfire.Poll.Questions.voting_open?(ended_question)
    assert Bonfire.Poll.Questions.voting_ended?(ended_question)
  end

  test "proposal_open?/1 and proposal_ended?/1" do
    now = DateTime.utc_now()
    past = DateTime.add(now, -3600, :second)
    future = DateTime.add(now, 3600, :second)
    {:ok, question} = fake_question(%{proposal_dates: [past, future]})
    assert Bonfire.Poll.Questions.proposal_open?(question)
    refute Bonfire.Poll.Questions.proposal_ended?(question)

    {:ok, ended_question} = fake_question(%{proposal_dates: [past, past]})
    refute Bonfire.Poll.Questions.proposal_open?(ended_question)
    assert Bonfire.Poll.Questions.proposal_ended?(ended_question)
  end

  test "list_closing_soon/2 returns open polls ordered by closing time, excluding closed and proposal-phase polls" do
    user = fake_user!()
    now = DateTime.utc_now()

    # 1 hour ahead (closes soonest)
    {:ok, _soon} =
      fake_question(
        %{
          post_content: %{name: "Soon"},
          voting_dates: [DateTime.add(now, -60, :second), DateTime.add(now, 3600, :second)]
        },
        current_user: user,
        boundary: "public"
      )

    # 1 day ahead
    {:ok, _later} =
      fake_question(
        %{
          post_content: %{name: "Later"},
          voting_dates: [DateTime.add(now, -60, :second), DateTime.add(now, 86_400, :second)]
        },
        current_user: user,
        boundary: "public"
      )

    # Already closed — must be excluded.
    {:ok, _closed} =
      fake_question(
        %{
          post_content: %{name: "Closed"},
          voting_dates: [DateTime.add(now, -7200, :second), DateTime.add(now, -60, :second)]
        },
        current_user: user,
        boundary: "public"
      )

    # Voting starts tomorrow (still in proposal phase) — must be excluded.
    {:ok, _proposal_only} =
      fake_question(
        %{
          post_content: %{name: "Proposal"},
          proposal_dates: [now, DateTime.add(now, 3600, :second)],
          voting_dates: [DateTime.add(now, 3600, :second), DateTime.add(now, 7200, :second)]
        },
        current_user: user,
        boundary: "public"
      )

    polls = Bonfire.Poll.Questions.list_closing_soon([current_user: user], 5)
    names = Enum.map(polls, &(&1.post_content && &1.post_content.name))

    assert "Soon" in names
    assert "Later" in names
    refute "Closed" in names
    refute "Proposal" in names
    # Soonest first.
    assert Enum.find_index(names, &(&1 == "Soon")) < Enum.find_index(names, &(&1 == "Later"))
  end

  test "list_closing_soon/2 caps results at the given limit" do
    user = fake_user!()
    now = DateTime.utc_now()

    for hours <- 1..5 do
      {:ok, _} =
        fake_question(
          %{
            post_content: %{name: "P#{hours}"},
            voting_dates: [
              DateTime.add(now, -60, :second),
              DateTime.add(now, hours * 3600, :second)
            ]
          },
          current_user: user,
          boundary: "public"
        )
    end

    assert length(Bonfire.Poll.Questions.list_closing_soon([current_user: user], 3)) == 3
  end

  test "vote_counts_for_questions/1 returns a map of question_id → total vote count" do
    voter = fake_user!()
    author = fake_user!()
    now = DateTime.utc_now()

    {:ok, q1} =
      fake_question_with_choices(
        %{
          post_content: %{name: "Q1"},
          voting_format: "single",
          voting_dates: [DateTime.add(now, -60, :second), DateTime.add(now, 3600, :second)]
        },
        [%{name: "a"}, %{name: "b"}],
        current_user: author,
        boundary: "public"
      )

    {:ok, q2} =
      fake_question_with_choices(
        %{
          post_content: %{name: "Q2"},
          voting_format: "single",
          voting_dates: [DateTime.add(now, -60, :second), DateTime.add(now, 3600, :second)]
        },
        [%{name: "c"}],
        current_user: author,
        boundary: "public"
      )

    # Cast one vote against the first choice of q1.
    [c1, _] = q1.choices
    {:ok, _} = Bonfire.Poll.Votes.vote(voter, q1, [%{choice_id: c1.id, weight: 1}])

    counts = Bonfire.Poll.Questions.vote_counts_for_questions([q1.id, q2.id])
    assert counts[q1.id] == 1
    # Questions with no votes are absent from the map (no zero key).
    refute Map.has_key?(counts, q2.id)
  end

  test "vote_counts_for_questions/1 handles an empty list without hitting the DB" do
    assert Bonfire.Poll.Questions.vote_counts_for_questions([]) == %{}
  end

  describe "full form-flow Questions.create" do
    # End-to-end test for the path the composer's LiveHandler runs through:
    #   form params  →  input_to_atoms  →  preset_params + question_attrs
    #   →  Questions.create  →  epic (PresetAttrs, Question.Create, …, Choices.Create)
    #
    # Locks in three regressions:
    #   1. `Question.changeset` uses `Needle.Changesets.cast/3` so the
    #      Pointable's :id is set before `put_assoc(:activity, …)` runs.
    #      Otherwise the activity row is never inserted.
    #   2. `Bonfire.Poll.Acts.PresetAttrs` merges preset-derived
    #      voting_format/weighting/voting_dates into :question_attrs.
    #   3. `Choices.simple_create_and_put` handles mixed-key indexed maps
    #      (the shape `input_to_atoms` produces when some `:"N"` atoms
    #      are pre-registered in the BEAM atom table).

    import Ecto.Query

    test "submitting a Quick poll persists Question + Activity + 2 choices" do
      user = Bonfire.Me.Fake.fake_user!()

      # Simulate the form's submitted params after the LiveHandler's first
      # clause has unwrapped `"post"`.
      form_params = %{
        "choices" => %{"0" => %{"name" => "Yes"}, "1" => %{"name" => "No"}},
        "post_content" => %{"html_body" => "Should we ship it?"},
        "poll_preset" => "quick",
        "poll_duration_hours" => "24",
        "poll_tuning_proposal_phase" => "false",
        "poll_tuning_hide_results" => "false",
        "poll_tuning_allow_vetoes" => "false",
        "to_boundaries" => ["public"]
      }

      attrs =
        form_params
        |> Map.drop([
          "poll_preset",
          "poll_duration_hours",
          "poll_tuning_proposal_phase",
          "poll_tuning_hide_results",
          "poll_tuning_allow_vetoes"
        ])
        |> Bonfire.Common.Enums.input_to_atoms(also_discard_unknown_nested_keys: false)

      preset_params = %{
        preset: "quick",
        tuning: %{proposal_phase: false, hide_results: false, allow_vetoes: false},
        duration_hours: 24
      }

      opts = [
        current_user: user,
        question_attrs: attrs,
        preset_params: preset_params,
        boundary: "public"
      ]

      assert {:ok, question} = Bonfire.Poll.Questions.create(opts)
      assert question.id

      # Activity exists and belongs to the user
      activity =
        Bonfire.Common.Repo.one(
          from a in Bonfire.Data.Social.Activity, where: a.object_id == ^question.id
        )

      assert activity
      assert activity.subject_id == user.id

      # Quick preset's weighting (1) ends up on the persisted Question.
      # Regression for the silent-override bug: the composer used to ship
      # `weighting=3` from the Advanced WeightSelector's hardcoded default,
      # which then beat preset.weighting via `PresetAttrs`'s form-wins merge.
      # When form_attrs doesn't include weighting (the unmodified-Advanced
      # case), the preset's value must win.
      reloaded = Bonfire.Common.Repo.get(Bonfire.Poll.Question, question.id)
      assert reloaded.weighting == 1
      assert reloaded.voting_format == "single"

      # Both choices are saved and linked via Ranked
      choice_count =
        Bonfire.Common.Repo.aggregate(
          from(r in Bonfire.Data.Assort.Ranked, where: r.scope_id == ^question.id),
          :count
        )

      assert choice_count == 2

      # And readable back by the creator (boundary applied)
      assert {:ok, _} = Bonfire.Poll.Questions.read(question.id, current_user: user)
    end

    test "Group decision preset enables proposal phase and weighted voting" do
      user = Bonfire.Me.Fake.fake_user!()

      attrs = %{
        choices: %{"0" => %{name: "A"}, "1" => %{name: "B"}},
        post_content: %{html_body: "Group decision?"}
      }

      preset_params = %{
        preset: "group_decision",
        tuning: %{proposal_phase: true, hide_results: true, allow_vetoes: false},
        duration_hours: 72
      }

      assert {:ok, question} =
               Bonfire.Poll.Questions.create(
                 current_user: user,
                 question_attrs: attrs,
                 preset_params: preset_params,
                 boundary: "public"
               )

      reloaded = Bonfire.Common.Repo.get(Bonfire.Poll.Question, question.id)
      assert reloaded.voting_format == "weighted_multiple"
      assert reloaded.weighting == 3
      assert [_, _] = reloaded.proposal_dates
      assert [_, _] = reloaded.voting_dates
    end

    test "form attributes override preset (Layer 3 wins over Layer 1)" do
      user = Bonfire.Me.Fake.fake_user!()

      # Quick preset gives voting_format="single", weighting=1.
      # Form supplies weighting=5 (as if from the Advanced section's WeightSelector).
      attrs = %{
        choices: [%{name: "A"}, %{name: "B"}],
        post_content: %{html_body: "Override test"},
        weighting: 5
      }

      preset_params = %{preset: "quick", tuning: %{}, duration_hours: 24}

      assert {:ok, question} =
               Bonfire.Poll.Questions.create(
                 current_user: user,
                 question_attrs: attrs,
                 preset_params: preset_params,
                 boundary: "public"
               )

      reloaded = Bonfire.Common.Repo.get(Bonfire.Poll.Question, question.id)
      # The form's weighting beats the preset's.
      assert reloaded.weighting == 5
    end
  end

  describe "create_poll LiveHandler — boundary default (regression)" do
    # Drives the real handler (where the bug lived). The composer's boundary
    # selector always supplies `to_boundaries`; when it's absent the handler must
    # pass nil through so the boundary system applies the configured
    # `:default_boundary_preset` (public). It used to force "mentions", which hid
    # polls from public/local feeds. See poll_live_handler.ex.
    import Ecto.Query

    defp create_poll_socket(user) do
      %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          __context__: %{current_user: user, current_user_id: user.id},
          current_user: user,
          current_user_id: user.id,
          flash: %{}
        }
      }
    end

    defp poll_form_params(extra) do
      Map.merge(
        %{
          "choices" => %{"0" => %{"name" => "Yes"}, "1" => %{"name" => "No"}},
          "post_content" => %{"html_body" => "Ship it?"},
          "poll_preset" => "quick",
          "poll_duration_hours" => "24",
          "poll_tuning_proposal_phase" => "false",
          "poll_tuning_hide_results" => "false",
          "poll_tuning_allow_vetoes" => "false"
        },
        extra
      )
    end

    defp latest_question_for(user) do
      Bonfire.Common.Repo.one(
        from(q in Bonfire.Poll.Question,
          join: a in Bonfire.Data.Social.Activity,
          on: a.object_id == q.id,
          where: a.subject_id == ^user.id,
          order_by: [desc: q.id],
          limit: 1
        )
      )
    end

    test "a poll submitted with no `to_boundaries` is readable by a stranger" do
      author = Bonfire.Me.Fake.fake_user!()
      stranger = Bonfire.Me.Fake.fake_user!()

      # NB: params omit `to_boundaries` entirely (the regression trigger).
      assert {:noreply, _socket} =
               Bonfire.Poll.LiveHandler.handle_event(
                 "create_poll",
                 poll_form_params(%{}),
                 create_poll_socket(author)
               )

      question = latest_question_for(author)
      assert question

      assert {:ok, _} = Bonfire.Poll.Questions.read(question.id, current_user: stranger)
    end

    test "an explicit `mentions` audience still hides the poll from a stranger (control)" do
      author = Bonfire.Me.Fake.fake_user!()
      stranger = Bonfire.Me.Fake.fake_user!()

      assert {:noreply, _socket} =
               Bonfire.Poll.LiveHandler.handle_event(
                 "create_poll",
                 poll_form_params(%{"to_boundaries" => ["mentions"]}),
                 create_poll_socket(author)
               )

      question = latest_question_for(author)
      assert question

      refute match?({:ok, _}, Bonfire.Poll.Questions.read(question.id, current_user: stranger))
    end
  end
end
