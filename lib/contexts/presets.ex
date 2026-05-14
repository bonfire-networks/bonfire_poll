defmodule Bonfire.Poll.Presets do
  @moduledoc """
  Named poll-style presets for the composer's Layer 1. Each preset is a
  complete configuration: picking one and posting produces a valid poll
  without touching Layer 2 or Layer 3. See `.claude/DESIGN.md` for the
  three-layer progressive-disclosure rules this module encodes.
  """

  use Bonfire.Common.Localise

  @type key :: :quick | :group_decision | :consensus | :custom
  @type t :: %{
          key: key(),
          name: String.t(),
          description: String.t(),
          icon: String.t(),
          voting_format: String.t(),
          weighting: integer(),
          duration_hours: integer(),
          tuning_defaults: %{
            proposal_phase: boolean(),
            hide_results: boolean(),
            allow_vetoes: boolean()
          }
        }

  @doc "All presets in display order; the first is the composer's default."
  @spec all() :: [t()]
  def all do
    [
      %{
        key: :quick,
        name: l("Quick poll"),
        description: l("Get a fast read on a question."),
        icon: "ph:lightning-duotone",
        voting_format: "single",
        weighting: 1,
        duration_hours: 24,
        tuning_defaults: %{
          proposal_phase: false,
          hide_results: false,
          allow_vetoes: false
        }
      },
      %{
        key: :group_decision,
        name: l("Group decision"),
        description: l("Open proposals, then a scored vote."),
        icon: "ph:users-three-duotone",
        voting_format: "weighted_multiple",
        weighting: 3,
        duration_hours: 72,
        tuning_defaults: %{
          proposal_phase: true,
          hide_results: true,
          allow_vetoes: false
        }
      },
      %{
        key: :consensus,
        name: l("Consensus check"),
        description: l("See where the group agrees and disagrees."),
        icon: "ph:handshake-duotone",
        voting_format: "weighted_multiple",
        weighting: 3,
        duration_hours: 48,
        tuning_defaults: %{
          proposal_phase: false,
          hide_results: false,
          allow_vetoes: true
        }
      }
    ]
  end

  @doc "Lookup a preset by key. Returns the `:quick` preset as a safe fallback."
  @spec get(key() | String.t() | atom() | nil) :: t()
  def get(key) when is_binary(key), do: get(safe_key(key))
  def get(key) when is_atom(key), do: Enum.find(all(), &(&1.key == key)) || default()
  def get(_), do: default()

  @doc "The preset selected by default when the composer first opens."
  @spec default() :: t()
  def default, do: List.first(all())

  @doc "The default tuning toggle map for a given preset key."
  @spec tuning_defaults(key()) :: map()
  def tuning_defaults(:custom), do: Map.new(tuning_keys(), &{&1, false})
  def tuning_defaults(preset_key), do: get(preset_key).tuning_defaults

  @doc """
  Translate preset + tuning state into backend `Question` attrs.

  `tuning` keys: `:proposal_phase`, `:hide_results`, `:allow_vetoes`.
  `opts` keys: `:duration_hours`, `:proposal_duration_hours`,
  `:multiple_choice` (Quick-only).
  """
  @spec to_question_attrs(key(), map(), keyword() | map()) :: map()
  def to_question_attrs(preset_key, tuning \\ %{}, opts \\ []) do
    preset = get(preset_key)
    voting_hours = opts[:duration_hours] || preset.duration_hours
    proposal_hours = opts[:proposal_duration_hours] || default_proposal_hours()
    now = DateTime.utc_now()

    voting_format =
      cond do
        tuning[:allow_vetoes] -> "weighted_multiple"
        shows_multiple_choice?(preset_key) and opts[:multiple_choice] -> "multiple"
        true -> preset.voting_format
      end

    weighting = if tuning[:allow_vetoes], do: 0, else: preset.weighting

    %{
      voting_format: voting_format,
      weighting: weighting
    }
    |> with_phase_dates(now, proposal_hours, voting_hours, tuning[:proposal_phase])
  end

  @doc "Default proposal-phase length when not specified (24h)."
  @spec default_proposal_hours() :: integer()
  def default_proposal_hours, do: 24

  defp with_phase_dates(attrs, now, proposal_hours, voting_hours, true) do
    proposal_end = DateTime.add(now, proposal_hours * 3600, :second)
    voting_end = DateTime.add(proposal_end, voting_hours * 3600, :second)

    Map.merge(attrs, %{
      proposal_dates: [now, proposal_end],
      voting_dates: [proposal_end, voting_end]
    })
  end

  defp with_phase_dates(attrs, now, _proposal_hours, voting_hours, _no_proposal_phase) do
    voting_end = DateTime.add(now, voting_hours * 3600, :second)
    Map.put(attrs, :voting_dates, [now, voting_end])
  end

  @doc """
  Resolve a preset key from arbitrary input. Unknowns fall back to `:quick`.
  Includes `:custom` even though `get/1` has no row for it.
  """
  @spec safe_key(key() | String.t() | atom() | nil) :: key()
  def safe_key(key) when is_atom(key) and not is_nil(key), do: safe_key(Atom.to_string(key))

  def safe_key(key) when is_binary(key) do
    Enum.find_value(known_keys(), :quick, fn k -> Atom.to_string(k) == key && k end)
  end

  def safe_key(_), do: :quick

  defp known_keys, do: [:custom | Enum.map(all(), & &1.key)]

  @doc "Canonical L2 tuning keys in display order."
  @spec tuning_keys() :: [atom()]
  def tuning_keys, do: [:proposal_phase, :hide_results, :allow_vetoes]

  @doc "L2 toggles surfaced inline per style; anything else lives in Advanced."
  @spec visible_toggles(key()) :: [atom()]
  def visible_toggles(:quick), do: []
  def visible_toggles(:group_decision), do: [:proposal_phase, :hide_results]
  def visible_toggles(:consensus), do: [:hide_results, :allow_vetoes]
  def visible_toggles(:custom), do: tuning_keys()
  def visible_toggles(_), do: []

  @doc "Whether the inline Single/Multiple-choice control applies to this style."
  @spec shows_multiple_choice?(key()) :: boolean()
  def shows_multiple_choice?(:quick), do: true
  def shows_multiple_choice?(_), do: false
end
