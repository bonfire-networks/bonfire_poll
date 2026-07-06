defmodule Bonfire.Poll.Web.PollInFeedTest do
  @moduledoc """
  UI test that complements the create-side integration test in
  `polls/questions_test.exs`. Exercises the **render side**:
    - a Question with choices saved in the DB
    - feed-level preload registry (`Bonfire.Social.Feeds.LiveHandler.object_preloads/0`)
      hydrates `:choices` (and their post_content) for objects of type
      `Bonfire.Poll.Question`
    - `Bonfire.Poll.Web.Preview.QuestionLive` renders each choice as a
      `data-id="activity_choice"` row.

  If the preload chain or preview gate (`{#if not is_nil(e(@object, :choices, nil))}`
  in `question_live.sface:86`) regresses, this test catches it.
  """

  use Bonfire.Poll.ConnCase, async: System.get_env("TEST_UI_ASYNC") != "no"
  import PhoenixTest

  alias Bonfire.Me.Fake

  test "a poll with choices appears in the feed with its options rendered" do
    account = Fake.fake_account!()
    user = Fake.fake_user!(account)
    conn = conn(user: user, account: account)

    question_text = "Should we ship the poll feature?"
    options = ["yes", "no"]

    {:ok, _question} =
      fake_question_with_choices(
        %{post_content: %{html_body: question_text}},
        Enum.map(options, &%{name: &1}),
        current_user: user,
        boundary: "public"
      )

    conn
    |> visit("/feed")
    |> wait_async()
    |> assert_has_or_open_browser("[data-id=feed]", text: question_text)
    |> assert_has_or_open_browser("[data-id=activity_choice]", text: "yes")
    |> assert_has_or_open_browser("[data-id=activity_choice]", text: "no")
    |> PhoenixTest.open_browser()
  end

  test "the same poll renders its options at its permalink (discussion view)" do
    account = Fake.fake_account!()
    user = Fake.fake_user!(account)
    conn = conn(user: user, account: account)

    {:ok, question} =
      fake_question_with_choices(
        %{post_content: %{html_body: "Pick one"}},
        [%{name: "first"}, %{name: "second"}],
        current_user: user,
        boundary: "public"
      )

    conn
    |> visit("/discussion/#{question.id}")
    |> wait_async()
    |> assert_has_or_open_browser("[data-id=activity_choice]", text: "first")
    |> assert_has_or_open_browser("[data-id=activity_choice]", text: "second")
  end

  test "another user's vote does not show as the viewer's own 'your vote'" do
    # Regression for the unscoped `object_voted` leak: after Alice voted, Bob
    # (who hasn't voted) saw a "Your vote" / "Voted" indicator on Alice's
    # choice. Bob must instead still see the Vote action bar.
    alice_account = Fake.fake_account!()
    alice = Fake.fake_user!(alice_account)

    bob_account = Fake.fake_account!()
    bob = Fake.fake_user!(bob_account)

    {:ok, question} =
      fake_question_with_choices(
        %{
          post_content: %{html_body: "Scoped vote visibility"},
          voting_format: "single",
          voting_dates: [DateTime.utc_now()]
        },
        [%{name: "alpha"}, %{name: "beta"}],
        current_user: alice,
        boundary: "public"
      )

    choice = hd(question.choices)

    assert {:ok, _} =
             Bonfire.Poll.Votes.vote(alice, question, [%{choice_id: choice.id, weight: 1}])

    conn(user: bob, account: bob_account)
    |> visit("/discussion/#{question.id}")
    |> wait_async()
    |> refute_has("[data-role=your-vote]")
    |> refute_has("[data-role=voted-indicator]")
    |> assert_has_or_open_browser("[data-role=submit-vote]")
  end

  test "a signed-in viewer sees the Vote action bar on an unvoted poll" do
    account = Fake.fake_account!()
    user = Fake.fake_user!(account)
    conn = conn(user: user, account: account)

    {:ok, _question} =
      fake_question_with_choices(
        %{post_content: %{html_body: "Vote bar test"}},
        [%{name: "alpha"}, %{name: "beta"}],
        current_user: user,
        boundary: "public"
      )

    conn
    |> visit("/feed")
    |> wait_async()
    |> assert_has_or_open_browser("[data-role=submit-vote]")
    |> assert_has_or_open_browser("[data-role=vote-count]", text: "0 votes")
  end

  test "after the deadline a poll renders the closed-summary header" do
    account = Fake.fake_account!()
    user = Fake.fake_user!(account)
    conn = conn(user: user, account: account)

    past = DateTime.utc_now() |> DateTime.add(-7200, :second)
    just_passed = DateTime.utc_now() |> DateTime.add(-60, :second)

    {:ok, question} =
      fake_question_with_choices(
        %{
          post_content: %{html_body: "Closed poll"},
          voting_format: "single",
          voting_dates: [past, just_passed]
        },
        [%{name: "won"}, %{name: "lost"}],
        current_user: user,
        boundary: "public"
      )

    conn
    |> visit("/discussion/#{question.id}")
    |> wait_async()
    |> assert_has_or_open_browser("[data-role=poll-state-label]", text: "Closed")
    |> refute_has("[data-role=submit-vote]")
  end

  test "a proposal-phase poll renders the inline Suggest form for signed-in viewers" do
    account = Fake.fake_account!()
    user = Fake.fake_user!(account)
    conn = conn(user: user, account: account)

    now = DateTime.utc_now()
    proposal_end = DateTime.add(now, 3600, :second)
    voting_end = DateTime.add(proposal_end, 3600, :second)

    {:ok, question} =
      fake_question_with_choices(
        %{
          post_content: %{html_body: "Proposal phase poll"},
          voting_format: "weighted_multiple",
          proposal_dates: [now, proposal_end],
          voting_dates: [proposal_end, voting_end]
        },
        [%{name: "seed-1"}, %{name: "seed-2"}],
        current_user: user,
        boundary: "public"
      )

    conn
    |> visit("/discussion/#{question.id}")
    |> wait_async()
    |> assert_has_or_open_browser("[data-role=propose-form]")
    |> assert_has_or_open_browser("[data-role=propose-submit]", text: "Suggest")
    |> refute_has("[data-role=submit-vote]")
  end

  test "weighted poll renders radio groups keyed by loop index, not choice id" do
    # The radio `name` attribute is the radio-group key. If two choices ever
    # share a name, the browser groups them and only one can be selected at
    # a time across the whole poll. We key by `votes[INDEX][weight]` and
    # carry `choice_id` via a hidden field, so this is structurally
    # impossible regardless of how `id(@choice)` resolves.
    account = Fake.fake_account!()
    user = Fake.fake_user!(account)
    conn = conn(user: user, account: account)

    {:ok, question} =
      fake_question_with_choices(
        %{
          post_content: %{html_body: "Weighted radio names"},
          voting_format: "weighted_multiple",
          weighting: 3
        },
        [%{name: "first"}, %{name: "second"}],
        current_user: user,
        boundary: "public"
      )

    conn
    |> visit("/discussion/#{question.id}")
    |> wait_async()
    # Each choice carries its weight via a hidden input that Alpine writes
    # to on button click, plus a hidden choice_id field. No HTML radios —
    # using buttons + Alpine state because LV's form lifecycle clobbered
    # the user's selection when the weight was carried by native radios.
    |> assert_has_or_open_browser(~s|input[type=hidden][name='votes[0][weight]']|)
    |> assert_has_or_open_browser(~s|input[type=hidden][name='votes[1][weight]']|)
    |> assert_has_or_open_browser(~s|input[type=hidden][name='votes[0][choice_id]']|)
    |> assert_has_or_open_browser(~s|input[type=hidden][name='votes[1][choice_id]']|)
    # Each face is a button with the role + data-score.
    |> assert_has_or_open_browser(~s|button[role=radio][data-score='-1']|)
    |> assert_has_or_open_browser(~s|button[role=radio][data-score='2']|)
  end

  test "vote control DOM ids are scoped per choice (no collisions across polls)" do
    # Regression: vote-input / vote-btn / vote-weight ids used to be keyed
    # by the per-poll choice index. Two polls in the feed would then both
    # emit `vote-input-0`, `vote-input-1`, … and the browser console
    # would spew "Multiple IDs detected". Scoping by render context and choice
    # ULID fixes it, including when the same poll appears in two widgets.
    account = Fake.fake_account!()
    user = Fake.fake_user!(account)
    conn = conn(user: user, account: account)

    {:ok, q1} =
      fake_question_with_choices(
        %{
          post_content: %{html_body: "First poll"},
          voting_format: "weighted_multiple"
        },
        [%{name: "a"}, %{name: "b"}],
        current_user: user,
        boundary: "public"
      )

    {:ok, q2} =
      fake_question_with_choices(
        %{
          post_content: %{html_body: "Second poll"},
          voting_format: "weighted_multiple"
        },
        [%{name: "c"}, %{name: "d"}],
        current_user: user,
        boundary: "public"
      )

    # Each choice has its own ULID; ids must include those, plus the rendering
    # scope, not just the index or naked choice id.
    [c1a, c1b] = q1.choices |> Enum.sort_by(& &1.id)
    [c2a, c2b] = q2.choices |> Enum.sort_by(& &1.id)

    conn
    |> visit("/feed")
    |> wait_async()
    |> assert_has_or_open_browser(~s|[id^='vote-input-'][id$='-#{c1a.id}']|)
    |> assert_has_or_open_browser(~s|[id^='vote-input-'][id$='-#{c1b.id}']|)
    |> assert_has_or_open_browser(~s|[id^='vote-input-'][id$='-#{c2a.id}']|)
    |> assert_has_or_open_browser(~s|[id^='vote-input-'][id$='-#{c2b.id}']|)
    # And the legacy `vote-input-0` collision is gone.
    |> refute_has("#vote-input-0")
    |> refute_has("#vote-input-1")
    |> refute_has("#vote-input-#{c1a.id}")
    |> refute_has("#vote-input-#{c2a.id}")
  end

  test "once the proposal phase ends, the voting UI takes over" do
    # Regression: the render branch used to gate on `proposal_dates != []`
    # which is true forever once set, so polls past their proposal-phase
    # deadline stayed stuck in the propose-only UI and voting was impossible.
    # We now gate on `Questions.proposal_open?/1` so the voting branch
    # activates as soon as the proposal phase ends.
    account = Fake.fake_account!()
    user = Fake.fake_user!(account)
    conn = conn(user: user, account: account)

    now = DateTime.utc_now()
    proposal_start = DateTime.add(now, -7200, :second)
    proposal_end = DateTime.add(now, -3600, :second)
    voting_end = DateTime.add(now, 3600, :second)

    {:ok, question} =
      fake_question_with_choices(
        %{
          post_content: %{html_body: "Voting now open"},
          voting_format: "weighted_multiple",
          proposal_dates: [proposal_start, proposal_end],
          voting_dates: [proposal_end, voting_end]
        },
        [%{name: "alpha"}, %{name: "beta"}],
        current_user: user,
        boundary: "public"
      )

    conn
    |> visit("/discussion/#{question.id}")
    |> wait_async()
    # Voting controls + Submit are present.
    |> assert_has_or_open_browser("[data-role=submit-vote]", text: "Submit votes")
    |> assert_has_or_open_browser(~s|button[role=radio][data-score='2']|)
    # Proposal-phase artifacts are gone (suggest form, proposal-vote-slot preview).
    |> refute_has("[data-role=propose-form]")
    |> refute_has("[data-role=proposal-vote-slot]")
  end

  test "a poll with choices appears in the polls preset feed (/feed/polls)" do
    account = Fake.fake_account!()
    user = Fake.fake_user!(account)
    conn = conn(user: user, account: account)

    question_text = "Polls preset feed question"

    {:ok, _question} =
      fake_question_with_choices(
        %{post_content: %{html_body: question_text}},
        [%{name: "option one"}, %{name: "option two"}],
        current_user: user,
        boundary: "public"
      )

    conn
    |> visit("/feed/polls")
    |> wait_async()
    |> assert_has_or_open_browser("[data-id=feed]", text: question_text)
    |> assert_has_or_open_browser("[data-id=activity_choice]", text: "option one")
    |> assert_has_or_open_browser("[data-id=activity_choice]", text: "option two")
  end

  test "submitting a suggestion adds it to the proposal-phase listing" do
    account = Fake.fake_account!()
    author = Fake.fake_user!(account)
    conn = conn(user: author, account: account)

    now = DateTime.utc_now()
    proposal_end = DateTime.add(now, 3600, :second)
    voting_end = DateTime.add(proposal_end, 3600, :second)

    {:ok, question} =
      fake_question_with_choices(
        %{
          post_content: %{html_body: "Open proposals"},
          voting_format: "weighted_multiple",
          proposal_dates: [now, proposal_end],
          voting_dates: [proposal_end, voting_end]
        },
        [%{name: "existing"}],
        current_user: author,
        boundary: "public"
      )

    conn
    |> visit("/discussion/#{question.id}")
    |> wait_async()
    |> fill_in("Your suggestion", with: "my new idea")
    |> click_button("[data-role=propose-submit]", "Suggest")
    |> wait_async()
    |> assert_has_or_open_browser("[data-id=activity_choice]", text: "my new idea")
  end
end
